#!/usr/bin/env bash
#
# install_app.sh — Idempotent macOS app installer (Slack by default)
#
# Features:
# - Verifies macOS, admin rights, internet connectivity (to the actual vendor host)
# - Auto-detects CPU arch (Intel / Apple Silicon) and selects correct Slack DMG
# - Resolves remote version (from final redirected URL) to skip download if up to date
# - Downloads app DMG, mounts, copies .app to /Applications using 'ditto'
# - Cleans up DMG + unmounts volume (and also via trap on any error/exit)
# - Logs every step to file + console
# - Idempotent (skips if already installed; --force to overwrite)
# - Dry-run mode for safe previews
# - Simple registry to add more apps (bonus path for PKG-based apps)
#
# Requires Bash 4+ (associative arrays). On macOS, run with Homebrew Bash if needed:
#   sudo /opt/homebrew/bin/bash ./install_app.sh
#
# Usage:
#   sudo ./install_app.sh                # install Slack
#   sudo ./install_app.sh --dry-run      # simulate actions
#   sudo ./install_app.sh --force        # overwrite existing install
#   sudo ./install_app.sh --app slack    # explicitly Slack
#   sudo ./install_app.sh --app zoom     # example extra app (PKG)
#
# Exit codes:
#   0 success | 1 general error | 2 prereq fail | 3 download fail | 4 mount fail | 5 copy fail

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

TMP_DIR="$(/usr/bin/mktemp -d /tmp/app-install.XXXXXX)"
DMG_PATH="${TMP_DIR}/download.dmg"
MOUNT_POINT="${TMP_DIR}/mnt"

APP="slack"
DRY_RUN=false
FORCE=false

# -----------------------------
# Cleanup trap (always runs)
# -----------------------------
cleanup_all() {
  # Best-effort unmount if mounted
  if /sbin/mount | /usr/bin/grep -q "on ${MOUNT_POINT} "; then
    echo "[trap] Unmounting ${MOUNT_POINT}"
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  # Remove temp dir
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    echo "[trap] Removing temp dir ${TMP_DIR}"
    /bin/rm -rf "$TMP_DIR" || true
  fi
}
trap cleanup_all EXIT

# -----------------------------
# Helpers
# -----------------------------
log() {
  local ts
  ts="$(/bin/date '+%Y-%m-%d %H:%M:%S')"
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
  if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    fail "This script only supports macOS. (Detected: $(/usr/bin/uname -s))"
  fi
}

require_root() {
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    fail "Please run as root (sudo). Administrative privileges are required."
  fi
}

detect_arch() {
  case "$(/usr/bin/uname -m)" in
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

ensure_logging_writable() {
  if ! /usr/bin/touch "$LOG_FILE" >/dev/null 2>&1; then
    LOG_FILE="/tmp/workplace_installer.log"
    /usr/bin/touch "$LOG_FILE" || fail "Cannot write to log file."
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
      --app)     APP="${2:-}"; shift 2 || true ;;
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
# Connectivity (actual host)
# -----------------------------
require_internet() {
  local base host
  if [[ "$APP" == "slack" ]]; then
    base="$(slack_url_for_arch)"
  else
    base="${APP_URLS[$APP]}"
  fi
  host="$(echo "$base" | /usr/bin/awk -F/ '{print $3}')"
  if ! /usr/bin/curl -I --silent --fail --max-time 10 "https://${host}" >/dev/null 2>&1; then
    fail "Internet check failed or host unreachable: ${host}"
  fi
}

# -----------------------------
# Version resolution (no download)
# -----------------------------
resolve_download_url() {
  local base
  if [[ "$APP" == "slack" ]]; then
    base="$(slack_url_for_arch)"
  else
    base="${APP_URLS[$APP]}"
  fi
  /usr/bin/curl -sSL -o /dev/null -w '%{url_effective}' "$base"
}

remote_version() {
  local url file ver=""
  url="$(resolve_download_url)"
  file="$(/usr/bin/basename "$url" 2>/dev/null || echo "")"

  if [[ "$APP" == "slack" && -n "$file" ]]; then
    # Examples: Slack-4.39.95-macOS.dmg or Slack-4.39.95-macOS-arm64.dmg
    ver="$(echo "$file" | /usr/bin/sed -E 's/.*Slack-([0-9]+(\.[0-9]+)+).*/\1/')" || true
  fi

  echo "$ver"
}

compare_versions() {
  # Returns 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
  local IFS=.
  local i v1=($1) v2=($2)
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
      0)
        if ! $FORCE; then
          log "Slack is already at the latest version. Nothing to do."
          return 2
        else
          log "Slack is latest but --force specified — proceeding."
          return 0
        fi
        ;;
      1)
        if ! $FORCE; then
          log "Installed version ($installed) is newer than remote ($remote). Skipping."
          return 2
        else
          log "Installed > remote but --force specified — proceeding."
          return 0
        fi
        ;;
      2)
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
  run "/usr/bin/curl -L --fail --silent --show-error --output '$DMG_PATH' '$url'" || { log "Download failed."; return 1; }

  if ! $DRY_RUN && [[ ! -s "$DMG_PATH" ]]; then
    log "Downloaded file is empty."
    return 1
  fi
  return 0
}

mount_dmg() {
  /bin/mkdir -p "$MOUNT_POINT"
  log "Mounting DMG at: $MOUNT_POINT"
  run "/usr/bin/hdiutil attach '$DMG_PATH' -nobrowse -quiet -mountpoint '$MOUNT_POINT'" || return 1
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
    run "/bin/rm -rf '$dst'"
  fi

  log "Copying app to /Applications using 'ditto' (preserves metadata)"
  run "/usr/bin/ditto '$src' '$dst'" || return 1
  return 0
}

unmount_dmg() {
  log "Unmounting DMG from: $MOUNT_POINT"
  run "/usr/bin/hdiutil detach '$MOUNT_POINT' -quiet" || log "Warning: failed to unmount (might already be detached)."
}

cleanup() {
  log "Cleaning up temp dir: $TMP_DIR"
  $DRY_RUN || /bin/rm -rf "$TMP_DIR"
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
  run "/usr/bin/curl -L --fail --silent --show-error --output '$pkg' '$url'" || { log "Download failed."; return 1; }

  if is_installed && ! $FORCE; then
    log "App already installed — skipping PKG install (use --force to reinstall)."
    return 0
  fi

  log "Installing PKG (this may prompt macOS Installer logs)"
  run "/usr/sbin/installer -pkg '$pkg' -target /" || return 1
  return 0
}

# -----------------------------
# Verification
# -----------------------------
verify_install() {
  local bundle="${APP_BUNDLES[$APP]}"
  if [[ -d "/Applications/${bundle}" ]]; then
    local ver
    ver="$(version_of)"
    if [[ -n "$ver" ]]; then
      log "Verified: ${bundle} installed. Version: $ver"
    else
      log "Verified: ${bundle} installed."
    fi
    return 0
  else
    log "Verification failed: /Applications/${bundle} not found."
    return 1
  fi
}

# -----------------------------
# Main
# -----------------------------
main() {
  parse_args "$@"
  ensure_logging_writable
  log "=== Starting installer (app=$APP, dry_run=$DRY_RUN, force=$FORCE) ==="

  require_macos
  require_root
  require_internet

  # Pre-check installed vs remote version to avoid unnecessary download/mount
  precheck_versions
  pre_status=$?
  if [[ $pre_status -eq 2 ]]; then
    log "Up-to-date detected before download. Exiting."
    exit 0
  fi

  # Attempt DMG flow; if registry uses PKG, fall back to PKG flow.
  if download_dmg; then
    mount_dmg || { cleanup; fail "Failed to mount DMG."; }
    copy_app_from_dmg || { unmount_dmg; cleanup; fail "Failed to copy app from DMG."; }
    unmount_dmg
  else
    install_pkg || { cleanup; fail "PKG installation failed."; }
  fi

  cleanup

  if ! verify_install; then
    fail "Installation verification failed."
  fi

  log "=== Installation completed successfully ==="
}

main "$@"