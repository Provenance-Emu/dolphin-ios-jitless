#!/usr/bin/env bash
#
# release.sh — iCube TestFlight release automation.
#
# A local mirror of .github/workflows/testflight.yml's "Archive and upload" step.
# The workflow is the source of truth for what actually works against App Store
# Connect; every value here (workspace, scheme, configuration, export options,
# both -allowProvisioningUpdates flags) is carried across from it deliberately.
# If you change one, change it in both places.
#
# Usage:
#   ./Scripts/release.sh [options]
#
#   --channel testflight   Archive + upload to App Store Connect (default, only channel)
#   --platform ios|tvos|all  Which platform(s) to ship (default: ios)
#   --build N              Override the build number (default: epoch seconds)
#   --dry-run              Print the commands without executing them
#   -h, --help
#
# Environment (TestFlight):
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ONE of
#   ASC_API_KEY_PATH (a .p8 on disk) or ASC_API_KEY_CONTENT (raw PEM or base64).
#   With neither set, the standard ~/.appstoreconnect/private_keys location is used.
#   See .env.sample; `make` runs this under `op run` when .env holds op:// refs.
#
# Signing uses your login keychain — unlike CI, no temp keychain is created. You
# need an Apple Distribution certificate installed; check with
#   security find-identity -v -p codesigning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
# Anchor on the repo root rather than counting ../.. — BuildiOSXCFramework.py and
# ExportOptions/ live there, while the Xcode project lives in Source/iOS/App.
REPO_ROOT="$(git -C "$APP_DIR" rev-parse --show-toplevel)"

WORKSPACE="$APP_DIR/iCube.xcworkspace"
SCHEME="iCube (AppStore)"
CONFIGURATION="Release (AppStore)"
EXPORT_OPTIONS="$REPO_ROOT/ExportOptions/ExportOptions-AppStore.plist"
ARCHIVES_DIR="$REPO_ROOT/build/archives"
EXPORT_DIR="$REPO_ROOT/build/export"

CHANNEL="testflight"
PLATFORM="ios"
DRY_RUN=false
# Epoch seconds: unique and strictly increasing, so App Store Connect never
# rejects the upload as a redundant binary. Passed on the xcodebuild command
# line — iCube's version lives in Project.swift (Tuist), so unlike Provenance
# and iFly there is no xcconfig to mutate and restore.
BUILD_NUMBER="$(date +%s)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        # %q per argument, not "$*": scheme and configuration names contain
        # spaces and parentheses, so an unquoted echo prints a line that looks
        # right and breaks if anyone pastes it into a shell.
        printf '\033[2m$'; printf ' %q' "$@"; printf '\033[0m\n'
    else
        "$@"
    fi
}

# BSD sed has no \? — use an explicit {0,1} interval so the comment markers are
# actually stripped on macOS rather than printed verbatim.
usage() { sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)  CHANNEL="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --build)    BUILD_NUMBER="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        -h|--help)  usage ;;
        *) err "Unknown option: $1 (try --help)" ;;
    esac
done

case "$CHANNEL" in
    testflight|all) ;;
    *) err "Unknown channel: $CHANNEL (only 'testflight' is implemented)" ;;
esac
case "$PLATFORM" in
    ios|tvos|all) ;;
    *) err "Unknown platform: $PLATFORM (ios|tvos|all)" ;;
esac

should_platform() { [[ "$PLATFORM" == "all" || "$PLATFORM" == "$1" ]]; }

VERSION="$(sed -n 's/.*"MARKETING_VERSION": "\([^"]*\)".*/\1/p' "$APP_DIR/Project.swift" | head -1)"
VERSION="${VERSION:-unknown}"

# ── Preflight ─────────────────────────────────────────────────────────────────
# Each of these fails fast with a fix, rather than an opaque xcodebuild error an
# hour into a cold archive.

# Under --dry-run these only warn, so the commands can be previewed on a fresh
# clone without first sitting through a 40-minute xcframework build.
missing() { if $DRY_RUN; then warn "$*"; else err "$*"; fi; }

command -v tuist >/dev/null 2>&1 \
    || missing "tuist is not installed. Install it with:  mise use -g tuist@4.200.0"

# The xcframework must exist BEFORE `tuist generate`: the binary target resolves
# eagerly, so generation fails on a fresh clone with nothing useful to say.
ls -d "$REPO_ROOT"/build/xcframework/* >/dev/null 2>&1 \
    || missing "No PVlibDolphin xcframework in build/xcframework — run:  make xcframework"

[[ -d "$WORKSPACE" ]] || missing "Workspace not found: $WORKSPACE — run:  make generate"

[[ -f "$EXPORT_OPTIONS" ]] || missing "Export options not found: $EXPORT_OPTIONS"

DIRTY="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)"
if [[ -n "$DIRTY" ]]; then
    warn "Working tree is dirty — this build will not match any commit."
    echo "$DIRTY" | head -10 | sed 's/^/    /'
    # A prompt with no TTY blocks forever, which is exactly how Provenance's
    # first automated release run hung (fixed there in 10d3c46858).
    if [[ ! -t 0 ]]; then
        warn "Non-interactive shell — continuing despite the dirty tree."
    else
        read -rp "  Continue anyway? [y/N] " yn
        [[ "${yn,,}" == "y" ]] || exit 1
    fi
fi

log "iCube release: $VERSION (build $BUILD_NUMBER) — channel: $CHANNEL, platform: $PLATFORM"

# ── App Store Connect API key ─────────────────────────────────────────────────
# Resolve the key to a file path xcodebuild can read. Without it,
# `xcodebuild -exportArchive` with destination=upload falls back to Xcode's
# signed-in accounts and dies with "Failed to Use Accounts" from the CLI.
_asc_key_path=""
_asc_key_tmpdir=""

cleanup() {
    [[ -n "$_asc_key_tmpdir" && -d "$_asc_key_tmpdir" ]] && rm -rf "$_asc_key_tmpdir"
    return 0
}
trap cleanup EXIT

# Sets the GLOBAL _asc_key_path. Callers read that variable; they must NOT
# capture stdout, because command substitution runs this in a subshell and every
# global it assigns — the memo and the temp-dir bookkeeping the EXIT trap needs —
# would be lost on return.
resolve_asc_key() {
    [[ -n "$_asc_key_path" ]] && return 0
    # A dry run prints commands without contacting Apple, so it must not demand
    # credentials — that would make `make release-dry` useless as a preview.
    if $DRY_RUN && [[ -z "${ASC_API_KEY_ID:-}" ]]; then
        _asc_key_path="<ASC key>"
        ASC_API_KEY_ID="<key id>"
        ASC_API_ISSUER_ID="<issuer id>"
        return 0
    fi
    [[ -n "${ASC_API_KEY_ID:-}" ]]    || err "ASC_API_KEY_ID is not set (App Store Connect API key ID)"
    [[ -n "${ASC_API_ISSUER_ID:-}" ]] || err "ASC_API_ISSUER_ID is not set (App Store Connect issuer ID)"

    if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
        [[ -f "$ASC_API_KEY_PATH" ]] || err "ASC_API_KEY_PATH does not exist: $ASC_API_KEY_PATH"
        _asc_key_path="$ASC_API_KEY_PATH"
    elif [[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8" ]]; then
        # xcodebuild's standard key location — set only ASC_API_KEY_ID + ISSUER.
        _asc_key_path="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
    elif [[ -f "$HOME/private_keys/AuthKey_${ASC_API_KEY_ID}.p8" ]]; then
        _asc_key_path="$HOME/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
    elif [[ -n "${ASC_API_KEY_CONTENT:-}" ]]; then
        # A 0700 temp DIRECTORY, not a temp file: the key inside is unreachable by
        # other users regardless of umask, and umask 077 keeps the file 0600 too.
        _asc_key_tmpdir="$(mktemp -d -t icube-asc)"
        _asc_key_path="$_asc_key_tmpdir/AuthKey_${ASC_API_KEY_ID}.p8"
        # Sniff for PEM BEFORE trying base64, never the other way round: macOS
        # `base64 --decode` silently skips characters it cannot parse and still
        # exits 0, so decoding a raw PEM yields a garbage file with no error and
        # xcodebuild fails much later with
        #   Invalid authentication key credential specified
        #   (DVTFoundation.JWT.Error.keyPathInvalid)
        if printf '%s' "$ASC_API_KEY_CONTENT" | grep -q "BEGIN PRIVATE KEY"; then
            ( umask 077; printf '%s' "$ASC_API_KEY_CONTENT" > "$_asc_key_path" )
        else
            ( umask 077; printf '%s' "$ASC_API_KEY_CONTENT" | base64 --decode > "$_asc_key_path" ) 2>/dev/null \
                || err "ASC_API_KEY_CONTENT is neither a valid .p8 nor base64"
        fi
        # Assert here rather than discovering it after a 90-minute archive.
        grep -q "BEGIN PRIVATE KEY" "$_asc_key_path" \
            || err "Materialised ASC key is not a PEM private key"
    else
        err "No App Store Connect API key: set ASC_API_KEY_PATH or ASC_API_KEY_CONTENT"
    fi
}

# ── Archive + upload ──────────────────────────────────────────────────────────

archive_and_upload() {
    local platform="$1" destination archive export_path

    case "$platform" in
        ios)  destination="generic/platform=iOS" ;;
        tvos) destination="generic/platform=tvOS" ;;
    esac
    archive="$ARCHIVES_DIR/iCube-${platform}.xcarchive"
    export_path="$EXPORT_DIR/${platform}"

    resolve_asc_key
    local auth=(
        -authenticationKeyPath "$_asc_key_path"
        -authenticationKeyID "$ASC_API_KEY_ID"
        -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
    )

    run mkdir -p "$ARCHIVES_DIR" "$export_path"

    log "Archiving ${platform}…"
    run xcodebuild archive \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$destination" \
        -archivePath "$archive" \
        CODE_SIGN_STYLE=Automatic \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        -allowProvisioningUpdates "${auth[@]}"

    # -allowProvisioningUpdates is required on export too, not just archive: the
    # API key authenticates but does not authorise xcodebuild to create or
    # download profiles. Omitting it here is what broke Provenance's export step
    # (fixed there in 27c3aba0a4).
    log "Uploading $platform to App Store Connect…"
    run xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportPath "$export_path" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        -allowProvisioningUpdates "${auth[@]}"
}

# One platform at a time, never in parallel. Concurrent -allowProvisioningUpdates
# requests race on Apple's per-account certificate limit: in CI both legs ran at
# once, tvOS provisioned first, and iOS then failed with "Your account has
# reached the maximum number of certificates".
should_platform ios  && archive_and_upload ios
should_platform tvos && archive_and_upload tvos

if $DRY_RUN; then
    log "Dry run complete — nothing was built or uploaded."
else
    log "Done — $VERSION (build $BUILD_NUMBER) uploaded."
    info "Processing takes a few minutes; watch https://appstoreconnect.apple.com"
fi
