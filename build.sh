#!/usr/bin/env bash
# Builds build/GlanceFocus.app. Run `bash build.sh install` to also copy it to /Applications,
# or to ~/Applications when this account can't write to /Applications (common on work Macs).
# Written for the bash 3.2 that ships with macOS.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GlanceFocus"
APP="build/${APP_NAME}.app"
BIN="build/bin/${APP_NAME}"
LOG="$(mktemp -t glancefocus-build.XXXXXX)"
STEP_PID=""

# Native code for this Mac, even when Terminal runs under Rosetta.
ARCH="$(uname -m)"
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then ARCH="arm64"; fi

# ── Progress display ───────────────────────────────────────────────────────────────────────────
# A spinner with a running timer in Terminal; plain lines in CI or when the output is piped.
if [[ -t 1 ]]; then
  INTERACTIVE=1
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  INTERACTIVE=0
  BOLD=""; DIM=""; GREEN=""; RED=""; CYAN=""; RESET=""
fi
FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

cleanup() {
  if [[ -n "$STEP_PID" ]]; then kill "$STEP_PID" 2>/dev/null || true; fi
  if [[ $INTERACTIVE == 1 ]]; then printf '\033[?25h'; fi # show the cursor again
  rm -f "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  printf '  %s✗ %s failed%s\n\n' "$RED" "$1" "$RESET"
  cat "$LOG"
  printf '\n%sCopy everything above when asking for help.%s\n' "$DIM" "$RESET"
  exit 1
}

# run_step "Label" command [args...]
# Runs the command in the background with its output captured, animating until it finishes.
# Running it as a background job (rather than inside `if`) keeps `set -e` working inside it.
run_step() {
  local label=$1 start=$SECONDS frame=0
  shift
  if [[ $INTERACTIVE == 0 ]]; then echo "- ${label}..."; fi

  "$@" >"$LOG" 2>&1 &
  STEP_PID=$!
  if [[ $INTERACTIVE == 1 ]]; then
    printf '\033[?25l' # hide the cursor while animating
    while kill -0 "$STEP_PID" 2>/dev/null; do
      printf '\r  %s%s%s %s… %s%ds%s ' "$CYAN" "${FRAMES[frame % ${#FRAMES[@]}]}" "$RESET" \
        "$label" "$DIM" $((SECONDS - start)) "$RESET"
      frame=$((frame + 1))
      sleep 0.08
    done
  fi

  if wait "$STEP_PID"; then
    STEP_PID=""
    if [[ $INTERACTIVE == 1 ]]; then
      printf '\r\033[K  %s✓%s %s %s%ds%s\n' "$GREEN" "$RESET" "$label" "$DIM" $((SECONDS - start)) "$RESET"
    else
      echo "  done in $((SECONDS - start))s"
    fi
  else
    STEP_PID=""
    if [[ $INTERACTIVE == 1 ]]; then printf '\r\033[K'; fi
    fail "$label"
  fi
}

# ── Developer tools ────────────────────────────────────────────────────────────────────────────
# Only the Swift compiler is needed, from Apple's command line tools or Xcode. Check that it runs
# before starting, so a missing or damaged install gets instructions instead of a compiler error.
check_tools() {
  if ! xcrun --sdk macosx --find swiftc >/dev/null 2>&1; then
    printf '  %s✗ Apple’s command line tools are not installed%s\n\n' "$RED" "$RESET"
    xcode-select --install >/dev/null 2>&1 || true
    printf '  A window should ask to install them. Click Install and wait until it finishes\n'
    printf '  (about 5–15 minutes), then run %sbash build.sh install%s again.\n' "$CYAN" "$RESET"
    printf '  %sNo window? Run: xcode-select --install%s\n\n' "$DIM" "$RESET"
    exit 1
  fi
  if ! xcrun --sdk macosx swiftc --version >"$LOG" 2>&1; then
    printf '  %s✗ The Swift compiler in %s does not run%s\n\n' "$RED" "$(xcode-select -p 2>/dev/null)" "$RESET"
    cat "$LOG"
    printf '\n  The developer tools look damaged, which can happen after an interrupted update.\n'
    printf '  Reinstall them, then run this again:\n'
    printf '  %ssudo rm -rf /Library/Developer/CommandLineTools%s\n' "$CYAN" "$RESET"
    printf '  %sxcode-select --install%s\n\n' "$CYAN" "$RESET"
    exit 1
  fi
}

# ── Steps ──────────────────────────────────────────────────────────────────────────────────────
# Calls the compiler directly rather than through Swift Package Manager, which crashes on launch
# when the command line tools are half-updated. The flags match `swift build -c release`.
compile() {
  mkdir -p "$(dirname "$BIN")"
  xcrun --sdk macosx swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 \
    -module-name "$APP_NAME" -target "${ARCH}-apple-macos13.0" \
    Sources/GlanceFocus/*.swift -o "$BIN"
}

package() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
}

# Ad-hoc signature: enough to run on your own Mac with camera access under the hardened runtime.
sign() {
  codesign --force --options runtime --entitlements Resources/GlanceFocus.entitlements --sign - "$APP"
}

install_app() {
  mkdir -p "$DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "${DEST:?}/${APP_NAME}.app"
  cp -R "$APP" "$DEST/"
}

# ── Main ───────────────────────────────────────────────────────────────────────────────────────
printf '\n  %sGlanceFocus%s\n\n' "$BOLD" "$RESET"
check_tools
run_step "Compiling" compile
run_step "Packaging the app" package
run_step "Signing" sign

if [[ "${1:-}" == "install" ]]; then
  DEST="/Applications"
  if [[ ! -w "$DEST" ]]; then DEST="$HOME/Applications"; fi
  SHOWN="$DEST"
  if [[ "$DEST" == "$HOME/Applications" ]]; then SHOWN="~/Applications"; fi
  REINSTALL=0
  if [[ -d "$DEST/${APP_NAME}.app" ]]; then REINSTALL=1; fi
  run_step "Installing to $SHOWN" install_app
fi

SIZE="$(du -sh "$APP" | cut -f1 | tr -d ' ')"
printf '\n  %sDone in %ds.%s %s.app is %s.\n' "$BOLD" "$SECONDS" "$RESET" "$APP_NAME" "$SIZE"
if [[ "${1:-}" == "install" ]]; then
  printf '  Open it:  %sopen %s/%s.app%s\n' "$CYAN" "$SHOWN" "$APP_NAME" "$RESET"
  if [[ $REINSTALL == 1 ]]; then
    printf '\n  %smacOS forgets the Accessibility permission when the app is rebuilt. Reset it, then allow it again:%s\n' "$DIM" "$RESET"
    printf '  %stccutil reset Accessibility local.glancefocus%s\n' "$CYAN" "$RESET"
  fi
else
  printf '  Built %s\n' "$APP"
fi
echo
