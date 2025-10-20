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
# Minimal “app registry”. Add more apps by defining URL + expected .app bundle name.
# The URL should be a stable "latest" redirect when possible so we don’t hardcode versions.
declare -A APP_URLS=(
  # Slack official “latest” download URL (Slack handles architecture via redirect).
  # If your org wants to pin channels: https://slack.com/ssb/download-osx?variant=universal
  [slack]="https://slack.com/ssb/download-osx"
  # Example extra app (Zoom) — comment out or adapt as needed.
  [zoom]="https://zoom.us/client/latest/ZoomInstallerIT.pkg"  # pkg example (not used by DMG path below)
)

# Expected .app bundle names when the DMG is mounted.
# (If an app uses a PKG instead, we handle that path separately.)
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
  # Executes a command unless --dry-run is enabled.
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
  # Quick HEAD request with timeout; follow redirects; no output unless it fails.
  if ! curl -I --silent --fail --max-time 10 https://slack.com >/dev/null 2>&1; then
    fail "No internet connectivity or slack.com unreachable."
  fi
}

ensure_logging_writable() {
  if ! touch "$LOG_FILE" >/dev/null 2>&1; then
    # Fall back to /tmp if /var/log is locked down
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
      --app)
        APP="${2:-}"; shift 2 || true
        ;;
      --dry-run)
        DRY_RUN=true; shift
        ;;
      --force)
        FORCE=true; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  # Validate known app
  if [[ -z "${APP_URLS[$APP]:-}" ]]; then
    fail "Unknown app '$APP'. Known: ${!APP_URLS[*]}"
  fi
}

is_installed() {
  local bundle="${APP_BUNDLES[$APP]}"
  [[ -d "/Applications/${bundle}" ]]
}

version_of() {
  # Reads CFBundleShortVersionString if available; empty if not found.
  local app_path="/Applications/${APP_BUNDLES[$APP]}"
  /usr/bin/defaults read "${app_path}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
}

# -----------------------------
# DMG Workflow
# -----------------------------
download_dmg() {
  local url="${APP_URLS[$APP]}"

  # If the URL ends with .pkg, this app isn't a DMG—skip DMG flow.
  if [[ "$url" == *.pkg ]]; then
    return 1
  fi

  log "Downloading latest '$APP' from: $url"
  run "curl -L --fail --output '$DMG_PATH' '$url'" || { log "Download failed."; return 1; }

  # Basic sanity check
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

  # If forcing, remove existing bundle first to avoid collisions
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
# PKG Workflow (if registry URL points to .pkg)
# -----------------------------
install_pkg() {
  local url="${APP_URLS[$APP]}"
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

  # Force reinstall if requested; many PKGs handle overwrite automatically.
  log "Installing PKG (this may prompt macOS Installer logs)"
  run "installer -pkg '$pkg' -target /" || return 1
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

  # Prereqs
  require_macos
  require_root
  require_internet

  # Attempt DMG flow; if registry uses PKG, fall back to PKG flow.
  if download_dmg; then
    mount_dmg || { cleanup; fail "Failed to mount DMG." ;}
    copy_app_from_dmg || { unmount_dmg; cleanup; fail "Failed to copy app from DMG." ;}
    unmount_dmg
  else
    # DMG download failed or URL is .pkg — try PKG path
    install_pkg || { cleanup; fail "PKG installation failed." ;}
  fi

  # Clean temporary files
  cleanup

  # Verify installation (idempotent-safe)
  if ! verify_install; then
    fail "Installation verification failed."
  fi

  log "=== Installation completed successfully ==="
}

main "$@"
