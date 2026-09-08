#!/usr/bin/env python3
"""
Manifest-driven screenshot harness for iCube.

Two APIs, no vision round-trips:

  navigate   RocketSim CLI over the ACCESSIBILITY tree — controls are addressed
             by label, so no coordinates and no looking at pixels to decide the
             next tap. A renamed control is a one-line fix in shots.json, not a
             code change.
  capture    `xcrun simctl io <udid> screenshot` — the device-native PNG of the
             whole UI. Deliberately NOT the app's own
             /api/debug/screenshot: that route returns the emulated GameCube/Wii
             framebuffer, not the SwiftUI interface we are photographing.

The app must have been launched with `-SCREENSHOT_MODE 1` (see run.sh), which
swaps the library for a fixed set of synthetic demo titles with procedurally
generated cover art. No copyrighted content is involved at any point.

Usage:
    python3 capture.py --udid UDID --device iphone --out DIR [--only NAME ...]
    python3 capture.py --list

Every step is declarative and every shot is independent: a step that cannot
find its control fails that ONE shot with a reason and the run continues, so a
UI change costs you one missing PNG rather than a wedged pass.
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROCKETSIM = os.environ.get("ROCKETSIM_BIN", "/opt/homebrew/bin/rocketsim")


class StepError(RuntimeError):
    """A declarative step could not be carried out — fails one shot, not the run."""


# ---------------------------------------------------------------- rocketsim --

#: Set once in main(). Every rocketsim call is pinned to this simulator with
#: --udid: the CLI otherwise targets whichever device RocketSim.app happens to
#: have selected, which on a machine with several booted sims is rarely ours.
UDID = None


def rs(*args, timeout=45):
    """Runs a rocketsim subcommand and returns the parsed rs/1 `data` payload."""
    cmd = [ROCKETSIM, *args]
    if UDID:
        cmd += ["--udid", UDID]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    out = (proc.stdout or "").strip()
    if not out:
        raise StepError(
            f"rocketsim {' '.join(args)}: no output "
            f"(exit {proc.returncode}) {(proc.stderr or '').strip()[:200]}"
        )
    try:
        env = json.loads(out)
    except json.JSONDecodeError:
        raise StepError(f"rocketsim {' '.join(args)}: non-JSON output {out[:200]}")
    if not env.get("ok"):
        err = env.get("error", {})
        raise StepError(
            f"rocketsim {' '.join(args)}: {err.get('code', '?')} "
            f"{err.get('message', '')}".strip()
        )
    return env.get("data", {})


def snapshot(mode="act"):
    """Compact accessibility snapshot. Returns the list of `id|role|label|...` rows."""
    data = rs("elements", "--agent", "--agent-mode", mode)
    return data.get("rows", []) or []


def labels_on_screen(mode="act"):
    """Every label currently visible, lowercased, for verify/reject matching."""
    seen = []
    for mode_ in (mode, "nav"):
        try:
            seen.extend(snapshot(mode_))
        except StepError:
            pass
    return "\n".join(seen).lower()


def seed_snapshot_store():
    """`--screen latest` needs the store primed; a cold session has no snapshot."""
    try:
        rs("screen")
    except StepError:
        pass


# --------------------------------------------------------------------- steps --

def selector(step):
    """Builds the rocketsim selector flags for a step.

    label/type/value mirror the CLI's own matcher (label and value are
    "contains", type is an exact type name). Several controls have no
    accessibility label at all — the library's search field is a textField whose
    only text is the "Search" placeholder, carried as its *value* — so matching
    on type+value is not an edge case, it is the only way to reach them.
    """
    flags = []
    for key, flag in (("label", "--label"), ("type", "--type"), ("value", "--value")):
        if step.get(key):
            flags += [flag, step[key]]
    if not flags:
        raise StepError("step needs one of: label, type, value")
    return flags


def step_tap(step):
    rs("interact", "tap", *selector(step), "--screen", "latest")


def step_activate(step):
    rs("interact", "activate", *selector(step), "--screen", "latest")


def step_long_press(step):
    rs("interact", "long-press", *selector(step),
       "--duration", str(step.get("duration", 1.2)), "--screen", "latest")


def step_type(step):
    # Raw typing goes to whatever holds focus. The CLI rejects --screen here
    # ("only meaningful with --id"), so no race guard is available or needed.
    rs("interact", "type", step["text"])


def step_focus_type(step):
    rs("interact", "focus", *selector(step), "--screen", "latest")
    time.sleep(0.4)
    rs("interact", "type", step["text"], "--screen", "latest")


def step_swipe(step):
    args = ["interact", "swipe", "--direction", step.get("direction", "up")]
    if step.get("label") or step.get("type") or step.get("value"):
        args += selector(step) + ["--screen", "latest"]
    else:
        args += ["--from", step["from"], "--to", step["to"]]
    rs(*args)


def step_button(step):
    rs("interact", "button", step.get("name", "home"))


def step_wait_element(step):
    rs("wait", "element", *selector(step), "--timeout", str(step.get("timeout", 4)))


def step_settle(step):
    time.sleep(float(step.get("seconds", 1.0)))


STEPS = {
    "tap": step_tap,
    "activate": step_activate,
    "long_press": step_long_press,
    "type": step_type,
    "focus_type": step_focus_type,
    "swipe": step_swipe,
    "button": step_button,
    "wait": step_wait_element,
    "settle": step_settle,
}


def run_step(step):
    do = step.get("do")
    fn = STEPS.get(do)
    if fn is None:
        raise StepError(f"unknown step '{do}'")
    fn(step)
    time.sleep(float(step.get("settle", 0.7)))


# ------------------------------------------------------------------ capture --

def screenshot(udid, path):
    """simctl's own capture — the whole UI, at device-native pixel size."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    proc = subprocess.run(
        ["xcrun", "simctl", "io", udid, "screenshot", "--type=png", path],
        capture_output=True, text=True, timeout=90,
    )
    if proc.returncode != 0 or not os.path.exists(path):
        raise StepError(f"simctl screenshot failed: {(proc.stderr or '').strip()[:200]}")
    return os.path.getsize(path)


#: Defaults written once before a run. These are first-launch interstitials that
#: land on top of whatever is being captured, so suppressing them up front is
#: more reliable than dismissing them afterwards — and it keeps a run
#: reproducible instead of depending on whether this container has been used.
PREPARE_DEFAULTS = {
    # FirstRunInitializationService enqueues the "unofficial build" boot notice
    # only when launch_times == 0. A non-zero value means "not a first run".
    "launch_times": ("-int", "5"),
    # The "Welcome to iCube" import/remote-source onboarding overlay.
    "onboarding_seen_v1": ("-bool", "YES"),
}
# The TipKit coach marks ("Import Game", ...) have no defaults key; screenshot
# mode skips Tips.configure() entirely instead — see TipsService.swift.


def prepare_defaults(udid, bundle_id):
    for key, (kind, value) in PREPARE_DEFAULTS.items():
        subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "defaults", "write",
             bundle_id, key, kind, value],
            capture_output=True, text=True,
        )


def set_appearance(udid, appearance):
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", appearance],
                   capture_output=True, text=True)


#: Persisted UI state that a shot can change and that would otherwise leak into
#: every later shot in the pass. The library's platform filter is @AppStorage,
#: so after the GameCube-filter shot every later capture still shows the library
#: filtered. Rewriting the default between launches is only a best-effort fix —
#: cfprefsd caches a domain the app has already written, so a shot that needs a
#: specific filter must also select it in its own steps (see shots.json, where
#: the library and search shots tap "All" first).
RESET_DEFAULTS = {
    "library_platform_filter": ("-string", "all"),
    "library_sort_field": ("-string", "name"),
    "library_sort_ascending": ("-bool", "YES"),
}


def reset_to_root(udid, bundle_id):
    """Cheapest reliable way back to the library: relaunch.

    Walking `back` N times is guesswork once a sheet, a context menu and a
    pushed detail can each be on screen; a relaunch is one command and always
    lands on the same screen, which is the property a reproducible pass needs.
    """
    subprocess.run(["xcrun", "simctl", "terminate", udid, bundle_id],
                   capture_output=True, text=True)
    for key, (kind, value) in RESET_DEFAULTS.items():
        subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "defaults", "write",
             bundle_id, key, kind, value],
            capture_output=True, text=True,
        )
    time.sleep(0.8)
    subprocess.run(
        ["xcrun", "simctl", "launch", udid, bundle_id, "-SCREENSHOT_MODE", "1"],
        capture_output=True, text=True,
    )
    time.sleep(4.0)
    seed_snapshot_store()


# --------------------------------------------------------------------- main --

def run_shot(shot, udid, device, out_dir, bundle_id):
    """Returns (status, detail). Never raises — one bad shot must not end a run."""
    name = shot["name"]
    reset_to_root(udid, bundle_id)

    if shot.get("appearance"):
        set_appearance(udid, shot["appearance"])
        time.sleep(1.5)

    try:
        for step in shot.get("steps", []):
            run_step(step)
    except (StepError, subprocess.TimeoutExpired) as e:
        return "failed", str(e)

    # verify/reject are advisory: they annotate the result rather than
    # discarding a PNG a human is about to review anyway.
    notes = []
    if shot.get("verify") or shot.get("reject"):
        try:
            visible = labels_on_screen()
            missing = [v for v in shot.get("verify", []) if v.lower() not in visible]
            present = [r for r in shot.get("reject", []) if r.lower() in visible]
            if missing:
                notes.append("missing: " + ", ".join(missing))
            if present:
                notes.append("unwanted: " + ", ".join(present))
        except StepError as e:
            notes.append(f"verify skipped ({e})")

    path = os.path.join(out_dir, device, name)
    try:
        size = screenshot(udid, path)
    except (StepError, subprocess.TimeoutExpired) as e:
        return "failed", str(e)

    detail = f"{size // 1024} KB"
    if notes:
        detail += " — " + "; ".join(notes)
    return ("captured" if not notes else "captured?"), detail


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--udid")
    ap.add_argument("--device", choices=["iphone", "ipad", "appletv"])
    ap.add_argument("--out")
    ap.add_argument("--bundle-id", default=os.environ.get("ICUBE_BUNDLE_ID", ""))
    ap.add_argument("--manifest", default=os.path.join(HERE, "shots.json"))
    ap.add_argument("--only", nargs="*", default=None,
                    help="capture just these shot names")
    ap.add_argument("--list", action="store_true",
                    help="print the manifest's shots per device and exit")
    args = ap.parse_args()

    manifest = json.load(open(args.manifest))

    if args.list:
        for dev, shots in manifest["devices"].items():
            print(f"\n{dev}:")
            for s in shots:
                print(f"  {s['name']:<34} {s.get('desc', '')}")
        return 0

    for required in ("udid", "device", "out", "bundle_id"):
        if not getattr(args, required):
            ap.error(f"--{required.replace('_', '-')} is required")

    shots = manifest["devices"].get(args.device, [])
    if args.only:
        shots = [s for s in shots if s["name"] in args.only
                 or s["name"].rsplit(".", 1)[0] in args.only]
    if not shots:
        print(f"no shots for device '{args.device}'", file=sys.stderr)
        return 1

    global UDID
    UDID = args.udid

    print(f"== {args.device}: {len(shots)} shots -> {args.out}/{args.device}/")
    prepare_defaults(args.udid, args.bundle_id)
    results = []
    for shot in shots:
        status, detail = run_shot(shot, args.udid, args.device, args.out,
                                  args.bundle_id)
        results.append((status, shot["name"], detail))
        mark = {"captured": "ok", "captured?": "ok?", "failed": "FAIL"}[status]
        print(f"  [{mark:>4}] {shot['name']:<34} {detail}")

    # Emit the website's captions.json sidecar for whatever actually landed.
    captions = {}
    for status, name, _ in results:
        if status == "failed":
            continue
        meta = next(s for s in shots if s["name"] == name)
        base = name.rsplit(".", 1)[0]
        # captions.json is keyed by basename alone, so a name used on more than
        # one device (library-light.png, settings-root.png) resolves to ONE
        # entry — the last pass written wins. Keep alt/caption device-neutral in
        # shots.json for those names rather than describing one device.
        # "theme" is the caption's label, not the simulator command: tvOS has a
        # dark UI but ignores `simctl ui appearance`, so it sets theme without
        # an appearance.
        captions[base] = {
            "alt": meta.get("alt", meta.get("desc", base)),
            "caption": meta.get("caption", ""),
            "theme": meta.get("theme", meta.get("appearance", "light")),
            "order": meta.get("order", 999),
        }
    cap_path = os.path.join(args.out, "captions.json")
    existing = {}
    if os.path.exists(cap_path):
        try:
            existing = json.load(open(cap_path))
        except (json.JSONDecodeError, OSError):
            existing = {}
    existing.update(captions)
    os.makedirs(args.out, exist_ok=True)
    with open(cap_path, "w") as f:
        json.dump(existing, f, indent=2, sort_keys=True)
        f.write("\n")

    failed = [n for s, n, _ in results if s == "failed"]
    print(f"== {args.device}: {len(results) - len(failed)}/{len(results)} captured")
    if failed:
        print("   failed: " + ", ".join(failed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
