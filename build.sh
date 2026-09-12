#!/usr/bin/env bash
#
# Builds Tilt.app from the SwiftPM package.
#
#   ./build.sh              build and sign
#   ./build.sh --run        build, sign, and relaunch the app
#   ./build.sh --universal  build for Apple Silicon and Intel
#   ./build.sh --dmg        also wrap the app in a Tilt.dmg installer
#   ./build.sh --clean      remove the build directory and exit
#   ./build.sh --help       show this help
#
# Uses ad-hoc signing by default. macOS may require Screen Recording permission
# again after rebuilding. Set SIGN_IDENTITY to use your own signing identity.

set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_NAME="Tilt"
BUILD_DIR="build"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

# --- output ---------------------------------------------------------------

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  BOLD=""; CYAN=""; GREEN=""; YELLOW=""; RED=""; DIM=""; RESET=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$1" "$RESET"; }
ok()    { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
die()   { printf '%s✗%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# --- arguments ------------------------------------------------------------

BUILD_ARGS=(-c release)
RUN_APP=false
MAKE_DMG=false

for argument in "$@"; do
  case "$argument" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    --run) RUN_APP=true ;;
    --dmg) MAKE_DMG=true ;;
    --clean) step "Cleaning"; rm -rf "$BUILD_DIR"; ok "removed $BUILD_DIR"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $argument (see --help)" ;;
  esac
done

# --- prerequisites --------------------------------------------------------

step "Checking prerequisites"

[[ "$(uname)" == "Darwin" ]] || die "Tilt builds on macOS only (this looks like $(uname))."

if ! command -v swift >/dev/null 2>&1; then
  die "swift not found. Install Xcode or the Command Line Tools, then run: xcode-select --install"
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  warn "xcodebuild not found; continuing with the swift toolchain that is present."
fi

SWIFT_VERSION="$(swift --version 2>/dev/null | head -1)"
ok "swift: ${SWIFT_VERSION:-unknown}"

# --- compile ---------------------------------------------------------------

step "Compiling (release)"

BUILD_LOG="$(mktemp -t tilt-build-log)"
trap 'rm -f "$BUILD_LOG"' EXIT

run_swift_build() {
  if ! swift build "${BUILD_ARGS[@]}" --product "$1" >"$BUILD_LOG" 2>&1; then
    die "swift build --product $1 failed. Last lines of the log:"$'\n'"$(tail -30 "$BUILD_LOG")"
  fi
}

run_swift_build Tilt
run_swift_build TiltProbe

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path 2>/dev/null)"
BINARY="$BIN_PATH/Tilt"
PROBE="$BIN_PATH/TiltProbe"
[[ -x "$BINARY" ]] || die "expected binary missing: $BINARY"

ok "built Tilt and TiltProbe"

# --- bundle -----------------------------------------------------------------

step "Assembling $BUNDLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/Tilt"
cp LICENSE NOTICE "$BUNDLE/Contents/Resources/"

# SwiftPM resource bundles (e.g. the bundle holding Shaders.metal, which
# DepthRenderer loads through Bundle.module). They sit next to the built
# binary; the app can't see them unless they're inside the bundle.
shopt -s nullglob
for resource_bundle in "$BIN_PATH"/*.bundle; do
  if [ -d "$resource_bundle" ]; then
    cp -R "$resource_bundle" "$BUNDLE/Contents/Resources/"
    ok "embedded $(basename "$resource_bundle")"
  fi
done
shopt -u nullglob

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Version stamp: never mutate the repo's Info.plist. Copy it aside, stamp
# the build number there, and ship the copy inside the bundle.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(git describe --tags --always --dirty 2>/dev/null || date +%Y%m%d%H%M)"
PLIST_TMP="$(mktemp -t tilt-info-plist)"
cp Resources/Info.plist "$PLIST_TMP"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_TMP" >/dev/null
cp "$PLIST_TMP" "$BUNDLE/Contents/Info.plist"
rm -f "$PLIST_TMP"
ok "version ${VERSION} (${BUILD_NUMBER})"

cp "$PROBE" "$BUILD_DIR/tilt-probe"
ok "copied tilt-probe"

# --- sign -------------------------------------------------------------------

step "Signing"

TIMESTAMP=--timestamp
SIGNING_DESC="Developer ID"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  TIMESTAMP=--timestamp=none
  SIGNING_DESC="ad-hoc"
fi

if ! codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" "$BUNDLE" 2>"$BUILD_LOG"; then
  {
    echo "codesign failed:"
    tail -10 "$BUILD_LOG"
    echo ""
    echo "hint: with ad-hoc signing this usually means the keychain is locked"
    echo "      or a previous signature is stale — try ./build.sh --clean first."
    echo "      For a named identity, check it with: security find-identity -v -p codesigning"
  } >&2
  exit 1
fi

if ! codesign --verify --strict --verbose=1 "$BUNDLE" >"$BUILD_LOG" 2>&1; then
  die "signature verification failed:"$'\n'"$(cat "$BUILD_LOG")"
fi
ok "signed (${SIGNING_DESC})"

# --- dmg ---------------------------------------------------------------------

DMG_PATH=""
if "$MAKE_DMG"; then
  step "Building installer DMG"
  DMG_PATH="$BUILD_DIR/Tilt.dmg"
  DMG_ROOT="$(mktemp -d -t tilt-dmg)"
  trap 'rm -f "$BUILD_LOG"; rm -rf "$DMG_ROOT"' EXIT
  cp -R "$BUNDLE" "$DMG_ROOT/"
  ln -s /Applications "$DMG_ROOT/Applications"
  if ! hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH" >"$BUILD_LOG" 2>&1; then
    die "hdiutil failed:"$'\n'"$(tail -10 "$BUILD_LOG")"
  fi
  rm -rf "$DMG_ROOT"
  trap 'rm -f "$BUILD_LOG"' EXIT
  ok "dmg ready"
fi

# --- summary ------------------------------------------------------------------

APP_SIZE="$(du -sh "$BUNDLE" | cut -f1)"

printf '\n%s%sTilt build complete%s\n' "$BOLD" "$GREEN" "$RESET"
printf '  app:      %s (%s)\n' "$BUNDLE" "$APP_SIZE"
printf '  version:  %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
printf '  signed:   %s\n' "$SIGNING_DESC"
if [[ -n "$DMG_PATH" ]]; then
  printf '  dmg:      %s\n' "$DMG_PATH"
fi
printf '  %sprobe:%s     %s\n' "$DIM" "$RESET" "$BUILD_DIR/tilt-probe"

if "$RUN_APP"; then
  step "Relaunching"
  pkill -x Tilt 2>/dev/null || true
  sleep 0.5
  open "$BUNDLE"
  ok "launched"
fi
