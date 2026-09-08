# iCube screenshot pipeline

Repeatable App Store / website screenshots, driven from a declarative shot list.

```bash
cd Source/iOS/App/tools/screenshots
./run.sh                        # iphone + ipad + appletv
PLATFORM=iphone ./run.sh        # one class
SKIP_BUILD=1 ./run.sh           # reuse the installed app
OUT=/tmp/shots ./run.sh         # somewhere else
python3 capture.py --list       # what the manifest covers
```

`run.sh` writes into this directory by default — DerivedData to `.dd/` (several
GB), captures to `captures/`, and a `.build-<class>.log` per platform. All of it
is gitignored.

`SKIP_BUILD=1` reuses the app **from `$DD`**, which defaults to `./.dd`. If you
built somewhere else (Xcode, or a scratch derived-data path), pass that path too
or the run dies with "iCube.app not found":

```bash
SKIP_BUILD=1 DD=/path/to/derived-data PLATFORM=iphone ./run.sh
```

Output is `$OUT/<device>/<name>.png` plus `$OUT/captions.json`, which is exactly
the contract the website's importer expects:

```bash
# in icube-emu.github.io
node scripts/import-screenshots.mjs /path/to/captures
```

## How a populated library is faked

iCube's library is Dolphin's C++ `GameFileCache` scanning real disc images, so a
screenshot run would otherwise need copyrighted content on disk. It doesn't:

Launching with `-SCREENSHOT_MODE 1` flips `TVLibraryBridge.isScreenshotDemoMode`,
and `TVLibraryBridge.currentGames` then returns a fixed set of 16 **synthetic**
`TVGameItem`s instead of consulting the cache. That one method is the single
funnel every consumer already goes through — `LibraryCoordinator`, the SwiftUI
grid, Spotlight indexing — so nothing else needed changing.

* Titles, publishers, game IDs and sizes are invented (`Starfall Rally`,
  `Emberfall Chronicles`, …). No real game, box art or trademark is referenced.
* Cover art is drawn procedurally in `TVGameItem`'s demo initializer with
  Core Graphics — a hue-seeded gradient, deterministic geometric accents and the
  title. **Nothing is bundled**, so the pipeline adds zero binary assets to the
  repo and needs no Tuist resource changes. Art for a given title is identical on
  every run.
* The set spans all three library filters (6 GameCube discs, 6 Wii discs,
  4 WiiWare) and seeds a deterministic Favourites row via the
  `favorites_by_gameid` default the library already reads.
* Ordering is fixed, so captures are reproducible.

Everything above is `#ifdef DEBUG`. In a Release build `isScreenshotDemoMode`
is a compile-time `NO`, `isDemoItem` is always false, and none of the demo code
is compiled in.

Demo entries deliberately have **no backing `GameFile`** and a path under a
directory that cannot exist. They must never be booted, so `TVLibraryView`
routes a demo item to `ScreenshotDemoUnavailableView` instead of
`EmulationScreen` — a stray tap during a capture pass cannot wedge the run.
Library rescans are also short-circuited in demo mode, since a real scan would
spin the refresh spinner (and hit remote sources) for a list that cannot change.

## Files

| file | role |
| --- | --- |
| `run.sh` | boots sims, builds, installs, sets the status bar, calls `capture.py` |
| `capture.py` | executes the manifest: RocketSim for navigation, simctl for pixels |
| `shots.json` | the shot list — names, steps, captions, per-device |

## Two APIs, no vision loop

* **Navigation** goes through the RocketSim CLI against the *accessibility
  tree*, so controls are addressed by label. A renamed control is a one-line fix
  in `shots.json`, not a code change, and no step needs a screen coordinate.
* **Capture** is `xcrun simctl io <udid> screenshot`. Note this is deliberately
  *not* the app's own `/api/debug/screenshot` route: that returns the emulated
  GameCube/Wii framebuffer, not the SwiftUI interface being photographed.

Each shot relaunches the app first, so shots are independent and order does not
matter — a failed step costs you one PNG with a printed reason, not the run.
`verify`/`reject` entries annotate a capture rather than discarding it, because
a human reviews every PNG before import anyway.

## Build configuration

Build with **`Debug (Non-Jailbroken)`** (bundle id `com.joemattiello.iCube-debug`).
`DEBUG` must be defined or screenshot mode does not exist. Do not pass a plain
`-configuration Debug`: this project defines no such configuration, and
xcodebuild then leaves the SPM resource bundles in a different products
directory, failing the build on missing `*_*.bundle` copies.

The first build also compiles the Dolphin core through CMake (the "Build Dolphin
Core" pre-action runs unconditionally), which is 20–60 minutes cold and needs
several GB free. Subsequent builds are incremental as long as the configuration
doesn't change — switching configuration reconfigures CMake and forces a full
core rebuild.

## Limitations

* **No in-game/gameplay shots.** The simulator has no JIT and no working
  Vulkan/MoltenVK path, and demo entries have no disc image to boot in any case.
  Gameplay and pause-menu screenshots must be captured on a real device.
* **tvOS** ignores `simctl status_bar` and `simctl ui appearance`, so Apple TV
  shots are light-only and have no status-bar override.
