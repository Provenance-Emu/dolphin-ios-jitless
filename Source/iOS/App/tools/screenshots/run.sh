#!/bin/bash
# The iCube App Store / website screenshot pipeline.
#
# Boots a simulator per device class, builds and installs the DEBUG app, launches
# it with -SCREENSHOT_MODE 1 (which swaps the library for synthetic demo titles
# with procedurally generated cover art — no copyrighted content is involved),
# pins the status bar to 9:41, then runs capture.py's declarative shot list.
#
#   ./run.sh                       # iphone + ipad + appletv
#   PLATFORM=iphone ./run.sh       # one class: iphone | ipad | appletv
#   SKIP_BUILD=1 ./run.sh          # reuse the app already installed
#   OUT=/tmp/shots ./run.sh        # override the output directory
#   SHOTS="library-light search" ./run.sh   # subset of the shot list
#
# Output: $OUT/<device>/<name>.png plus $OUT/captions.json, which is exactly the
# contract icube-emu.github.io's scripts/import-screenshots.mjs expects:
#   node scripts/import-screenshots.mjs "$OUT"
set -uo pipefail
cd "$(dirname "$0")"

APP_DIR="$(cd ../.. && pwd)"                 # Source/iOS/App
WORKSPACE="$APP_DIR/iCube.xcworkspace"
SCHEME="iCube (NJB)"

# DEBUG must be defined for screenshot mode to exist at all: both the demo
# library and TVGameItem's demo initializer are #ifdef DEBUG. "Debug
# (Non-Jailbroken)" is the NJB scheme's own debug configuration — do NOT pass a
# plain "Debug", which is not a configuration this project defines and which
# leaves the SPM resource bundles built into the wrong products directory.
CONFIG_IOS="Debug (Non-Jailbroken)"
BUNDLE_ID="com.joemattiello.iCube-debug"

PLATFORM=${PLATFORM:-"iphone ipad appletv"}
OUT=${OUT:-"$PWD/captures"}
DD=${DD:-"$PWD/.dd"}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2
         [ $# -gt 1 ] && printf '\033[1mfix:\033[0m %s\n' "$2" >&2
         exit 1; }

ROCKETSIM=${ROCKETSIM_BIN:-/opt/homebrew/bin/rocketsim}

command -v python3 >/dev/null || die "python3 not found" "install the Xcode command line tools"
[ -x "$ROCKETSIM" ] || die "rocketsim CLI not found at $ROCKETSIM" \
    "RocketSim ▸ Settings ▸ CLI & Agent ▸ Install Command Line Tool"
# The CLI talks to the RocketSim app over IPC — without the app running, every
# navigation step fails and you get a pass of identical library screenshots.
if ! pgrep -x RocketSim >/dev/null; then
  note "starting RocketSim.app (the CLI needs it running)"
  open -a RocketSim || die "could not launch RocketSim.app" \
      "install it from https://apps.apple.com/app/apple-store/id1504940162"
  sleep 5
fi
xcode-select -p >/dev/null 2>&1 || die "no active Xcode" "xcode-select --switch /Applications/Xcode.app"
[ -d "$WORKSPACE" ] || die "iCube.xcworkspace not found at $WORKSPACE" \
    "generate it first: cd $APP_DIR && make generate"

# ------------------------------------------------------------------ devices --
# simctl's "available" list still contains devices whose runtime image is gone
# from disk, and names repeat across runtimes — so rank candidates, then try to
# boot each until one actually comes up.
pick_candidates() {  # <class> -> lines of "udid<TAB>name (runtime)"
  xcrun simctl list -j devices available | python3 -c '
import json, re, sys
cls = sys.argv[1]
for runtime, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"(iOS|tvOS)-(\d+)-(\d+)", runtime)
    if not m: continue
    fam, ver = m.group(1), (int(m.group(2)), int(m.group(3)))
    for d in devs:
        if not d.get("isAvailable"): continue
        n = d["name"]
        # A device named iCube-Shots-* is one this pipeline created and owns, so
        # it always wins. On a machine where another session is also driving
        # simulators, sharing a device means one run launches its app over the
        # top of the other, and both sets of screenshots come out wrong.
        # (Keep apostrophes out of this block: it is single-quoted shell.)
        dedicated = n.startswith("iCube-Shots-")
        if cls == "iphone" and fam == "iOS" and (n.startswith("iPhone") or dedicated):
            if dedicated and "iPhone" not in n: continue
            rank = 0 if "Pro Max" in n else (1 if "Plus" in n else 2)
        elif cls == "ipad" and fam == "iOS" and (n.startswith("iPad") or dedicated):
            if dedicated and "iPad" not in n: continue
            rank = 0 if ("Pro 13" in n or dedicated) else (1 if "Pro" in n else 2)
        elif cls == "appletv" and fam == "tvOS":
            rank = 0 if (dedicated or ("4K" in n and "1080p" not in n)) else 1
        else:
            continue
        if dedicated:
            rank = -1
        # Screen class outranks "already booted": App Store sizes are fixed by
        # the device, so a booted 6.3" iPhone must not win over a 6.9" Pro Max.
        booted = 0 if d["state"] == "Booted" else 1
        print("\t".join([str(rank), str(booted), str(-ver[0]), str(-ver[1]),
                         d["udid"], "%s (%s %d.%d)" % (n, fam, ver[0], ver[1])]))
' "$1" | sort -n | cut -f5,6
}

boot_one() {  # <class> -> sets UDID, DEVDESC
  UDID=""; DEVDESC=""
  while IFS=$'\t' read -r udid desc; do
    [ -z "$udid" ] && continue
    if xcrun simctl list devices | grep -F "$udid" | grep -q "(Booted)"; then
      UDID=$udid; DEVDESC="$desc"; note "already booted: $desc"; return 0
    fi
    if xcrun simctl boot "$udid" 2>/dev/null; then
      UDID=$udid; DEVDESC="$desc"; note "booted: $desc"; sleep 6; return 0
    fi
    note "cannot boot: $desc (runtime image missing?) — trying next"
  done < <(pick_candidates "$1")
  die "no bootable $1 simulator found" \
      "Xcode ▸ Settings ▸ Components — install a matching simulator runtime"
}

# ------------------------------------------------------ build/install/launch --
build_install() {  # <class>
  local cls=$1 dest sdkdir log
  case $cls in
    appletv) dest="platform=tvOS Simulator,id=$UDID"; sdkdir="appletvsimulator" ;;
    *)       dest="platform=iOS Simulator,id=$UDID";  sdkdir="iphonesimulator" ;;
  esac
  log="$PWD/.build-$cls.log"

  if [ "${SKIP_BUILD:-}" != 1 ]; then
    bold "== building $SCHEME ($CONFIG_IOS, $cls) — log: $log"
    note "first run also builds the Dolphin core via CMake; expect 20-60 min cold"
    if ! xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" \
        -configuration "$CONFIG_IOS" -destination "$dest" \
        -derivedDataPath "$DD" build >"$log" 2>&1; then
      tail -30 "$log" >&2
      die "build failed (full log: $log)" "see the tail above"
    fi
  fi

  local app
  app=$(find "$DD/Build/Products/$CONFIG_IOS-$sdkdir" -maxdepth 1 -name "iCube.app" 2>/dev/null | head -1)
  [ -n "$app" ] || die "iCube.app not found under $DD/Build/Products/$CONFIG_IOS-$sdkdir" \
                      "re-run without SKIP_BUILD=1"

  bold "== installing on $DEVDESC"
  xcrun simctl install "$UDID" "$app" || die "simctl install failed" "check the sim booted: xcrun simctl boot $UDID"
  open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true
}

prepare_ui() {  # <class>
  # tvOS has no status bar and ignores `simctl status_bar` / `ui appearance`.
  if [ "$1" != appletv ]; then
    xcrun simctl status_bar "$UDID" override \
      --time 9:41 --batteryState charged --batteryLevel 100 \
      --cellularBars 4 --wifiBars 3 2>/dev/null \
      || note "status_bar override unavailable on this runtime (continuing)"
  fi
}

capture() {  # <class>
  bold "== capturing $1"
  python3 capture.py --udid "$UDID" --device "$1" --out "$OUT" \
      --bundle-id "$BUNDLE_ID" ${SHOTS:+--only $SHOTS} \
    || note "capture.py reported failures for $1 (see above)"
}

run_class() {  # <class>
  bold ""
  bold "======================================================================"
  bold "  $1"
  bold "======================================================================"
  boot_one "$1"
  build_install "$1"
  prepare_ui "$1"
  capture "$1"
  # Never leave a simulator stuck in dark mode for the next run.
  [ "$1" != appletv ] && xcrun simctl ui "$UDID" appearance light 2>/dev/null || true
}

for p in $PLATFORM; do
  case $p in
    iphone|ipad|appletv) run_class "$p" ;;
    *) die "unknown PLATFORM '$p'" "use: iphone | ipad | appletv" ;;
  esac
done

bold ""
bold "== done"
note "captures: $OUT"
note "import:   node scripts/import-screenshots.mjs \"$OUT\"   (in icube-emu.github.io)"
