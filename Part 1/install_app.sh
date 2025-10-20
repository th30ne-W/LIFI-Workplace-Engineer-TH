#!/usr/bin/env bash
#
# install_app.sh — Idempotent macOS app installer (Slack by default)
#
# Features:
# - Verifies macOS, admin rights, internet connectivity
# - Downloads latest app DMG (Slack by default) with redirects
# - Mounts DMG, copies .app to /Applications using 'ditto'
# - Cleans up DMG + unmounts volume
# - Logs every step to file + console
# - Idempotent (skips if already installed; --force to overwrite)
# - Dry-run mode for safe previews
# - Simple registry to add more apps (bonus)
# - Detects CPU architecture (Intel / Apple Silicon) and installs correct Slack version
# - Skips download if latest version already installed (pre-check via resolved URL)
#
# Usage:
#   sudo ./install_app.sh                # install Slack
#   sudo ./install_app.sh --dry-run      # simulate actions
#   sudo ./install_app.sh --force        # overwrite existing install
#   sudo ./install_app.sh --app slack    # explicitly Slack
#   sudo ./install_app.sh --app zoom     # example extra app (see APP_REGISTRY)
#
# Exit codes:
#   0 success | 1 general error | 2 prereq fail | 3 download fail | 4 mount fail | 5 copy fail
#

set -euo pipefail

# -----------------------------
# Configuration / Registry
# -----------------------------
declare -A APP_URLS=(
  [slack]="https://slack.com/ssb/download-osx"
  [zoom]="https://zoom.us/client/latest/ZoomInstallerIT.pkg"
)

declare -A APP_BUNDLES=(
  [slack]="Slack.app"
  [zoom]="Zoom.app"
)

LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/workplace_installer.log"

TMP_DIR="$(mktemp -d /tmp/app-install.XXXXXX)"
DMG_PATH="${TMP_DIR}/download.dmg"
MOUNT_POINT="${TMP_DIR}/mnt"

APP="slack"
DRY_RUN=false
FORCE=false

# -----------------------------
# Helpers
# -----------------------------
log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

run() {
  if $DRY_RUN; then
    log "[dry-run] $*"
  else
    eval "$@"
  fi
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "This script only supports macOS. (Detected: $(uname -s))"
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Please run as root (sudo). Administrative privileges are required."
  fi
}

require_internet() {
  if ! curl -I --silent --fail --max-time 10 https://slack.com >/dev/null 2>&1; then
    fail "No internet connectivity or slack.com unreachable."
  fi
}

ensure_logging_writable() {
  if ! touch "$LOG_FILE" >/dev/null 2>&1; then
    LOG_FILE="/tmp/workplace_installer.log"
    touch "$LOG_FILE" || fail "Cannot write to log file."
  fi
}

usage() {
  cat <<EOF
Usage: sudo $0 [--app <name>] [--dry-run] [--force]

Options:
  --app <name>   Which app to install (default: slack). Known: ${!APP_URLS[*]}
  --dry-run      Print what would happen, do not change the system.
  --force        Reinstall even if the app is already present.

Examples:
  sudo $0
  sudo $0 --dry-run
  sudo $0 --app slack --force
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)   APP="${2:-}"; shift 2 || true ;;
      --dry-run) DRY_RUN=true; shift ;;
      --force)   FORCE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown argument: $1" ;;
    esac
  done
  if [[ -z "${APP_URLS[$APP]:-}" ]]; then
    fail "Unknown app '$APP'. Known: ${!APP_URLS[*]}"
  fi
}

is_installed() {
  local bundle="${APP_BUNDLES[$APP]}"
  [[ -d "/Applications/${bundle}" ]]
}

version_of() {
  local app_path="/Applications/${APP_BUNDLES[$APP]}"
  /usr/bin/defaults read "${app_path}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
}

# -----------------------------
# Arch-aware Slack URL
# -----------------------------
detect_arch() {
  case "$(uname -m)" in
    arm64)  echo "arm64" ;;
    x86_64) echo "intel" ;;
    *)      echo "unknown" ;;
  esac
}

slack_url_for_arch() {
  case "$(detect_arch)" in
    arm64)  echo "https://slack.com/ssb/download-osx?variant=arm64" ;;
    intel)  echo "https://slack.com/ssb/download-osx?variant=intel" ;;
    *)      echo "https://slack.com/ssb/download-osx?variant=universal" ;;
  esac
}

resolve_download_url() {
  # Resolve the *final* redirected URL without downloading the file.
  local base
  if [[ "$APP" == "slack" ]]; then
    base="$(slack_url_for_arch)"
  else
    base="${APP_URLS[$APP]}"
  fi
  # Print the final effective URL (after redirects)
  curl -sSL -o /dev/null -w '%{url_effective}' "$base"
}

remote_version() {
  # Try to parse a version from the final DMG/PKG filename in the resolved URL.
  local final url file ver
  url="$(resolve_download_url)"
  file="$(basename "$url")"

  if [[ "$APP" == "slack" ]]; then
    # Common patterns: Slack-4.39.95-macOS.dmg OR Slack-4.39.95-macOS-arm64.dmg
    ver="$(echo "$file" | sed -E 's/.*Slack-([0-9]+(\.[0-9]+)+).*/\1/' )"
  else
    # Fallback: many vendor URLs may not include version. Return empty.
    ver=""
  fi

  echo "$ver"
}

compare_versions() {
  # Returns 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
  # Split by dots and compare numerically.
  local IFS=.
  local i v1=($1) v2=($2)
  # Pad lengths
  local len=$(( ${#v1[@]} > ${#v2[@]} ? ${#v1[@]} : ${#v2[@]} ))
  for ((i=${#v1[@]}; i<len; i++)); do v1[i]=0; done
  for ((i=${#v2[@]}; i<len; i++)); do v2[i]=0; done
  for ((i=0; i<len; i++)); do
    if ((10#${v1[i]} > 10#${v2[i]})); then return 1; fi
    if ((10#${v1[i]} < 10#${v2[i]})); then return 2; fi
  done
  return 0
}

precheck_versions() {
  local installed remote
  installed="$(version_of || true)"
  remote="$(remote_version || true)"

  if [[ -n "$installed" ]]; then
    log "Installed version: $installed"
  else
    log "Installed version: (not installed)"
  fi

  if [[ -n "$remote" ]]; then
    log "Latest available version (from URL): $remote"
  else
    log "Latest available version: (unknown; vendor did not expose version in URL)"
  fi

  # Decide:
  if ! is_installed; then
    log "Not installed — proceed with installation."
    return 0
  fi

  if [[ -z "$remote" ]]; then
    log "Cannot determine remote version — will proceed with installation to ensure latest."
    return 0
  fi

  if [[ -n "$installed" ]]; then
    compare_versions "$installed" "$remote"
    case $? in
      0)  # equal
          if ! $FORCE; then
            log "Slack is already at the latest version. Nothing to do."
            return 2
          else
            log "Slack is latest but --force specified — proceeding."
            return 0
          fi
          ;;
      1)  # installed > remote (rare)
          if ! $FORCE; then
            log "Installed version ($installed) is newer than remote ($remote). Skipping."
            return 2
          else
            log "Installed > remote but --force specified — proceeding."
            return 0
          fi
          ;;
      2)  # installed < remote
          log "An update is available ($installed → $remote). Proceeding."
          return 0
          ;;
    esac
  fi

  return 0
}

# -----------------------------
# DMG Workflow
# -----------------------------
download_dmg() {
  local url
  if [[ "$APP" == "slack" ]]; then
    url="$(slack_url_for_arch)"
    log "Detected arch: $(detect_arch). Using Slack URL: $url"
  else
    url="${APP_URLS[$APP]}"
  fi

  if [[ "$url" == *.pkg ]]; then
    return 1
  fi

  log "Downloading latest '$APP' from: $url"
  run "curl -L --fail --output '$DMG_PATH' '$url'" || { log "Download failed."; return 1; }

  if ! $DRY_RUN && [[ ! -s "$DMG_PATH" ]]; then
    log "Downloaded file is empty."
    return 1
  fi
  return 0
}

mount_dmg() {
  mkdir -p "$MOUNT_POINT"
  log "Mounting DMG at: $MOUNT_POINT"
  run "hdiutil attach '$DMG_PATH' -nobrowse -quiet -mountpoint '$MOUNT_POINT'" || return 1
  return 0
}

copy_app_from_dmg() {
  local bundle="${APP_BUNDLES[$APP]}"
  local src="${MOUNT_POINT}/${bundle}"
  local dst="/Applications/${bundle}"

  if ! $DRY_RUN && [[ ! -d "$src" ]]; then
    log "Expected app bundle not found in DMG: $src"
    return 1
  fi

  if is_installed && ! $FORCE; then
    log "App already installed at /Applications/${bundle} — skipping copy (use --force to overwrite)."
    return 0
  fi

  if is_installed && $FORCE; then
    log "Removing existing installation (force): $dst"
    run "rm -rf '$dst'"
  fi

  log "Copying app to /Applications using 'ditto' (preserves metadata)"
  run "ditto '$src' '$dst'" || return 1
  return 0
}

unmount_dmg() {
  log "Unmounting DMG from: $MOUNT_POINT"
  run "hdiutil detach '$MOUNT_POINT' -quiet" || log "Warning: failed to unmount (might already be detached)."
}

cleanup() {
  log "Cleaning up temp dir: $TMP_DIR"
  $DRY_RUN || rm -rf "$TMP_DIR"
}

# -----------------------------
# PKG Workflow (for apps like Zoom)
# -----------------------------
install_pkg() {
  local url
  if [[ "$APP" == "slack" ]]; then
    url="$(slack_url_for_arch)"
  else
    url="${APP_URLS[$APP]}"
  fi
  local pkg="${TMP_DIR}/installer.pkg"

  if [[ "$url" != *.pkg ]]; then
    return 1
  fi

  log "Downloading PKG for '$APP' from: $url"
  run "curl -L --fail --output '$pkg' '$url'" || { log "Download failed."; return 1; }

  if is_installed && ! $FORCE; then
    log "App already installed — skipping PKG install (use --force to reinstall)."
    return 0
  fi

  log "Installing PKG (this may prompt macOS Installer logs)"
  run "installer -pkg '$pkg' -target /" || return 1
  return 0
}

# -----------------------------
# Verification
# -----------------------------
verify_install() {
  local bundle="${APP_BUNDLES[$APP]}"
  if [[ -d "/Applications/${bundle}" ]];
