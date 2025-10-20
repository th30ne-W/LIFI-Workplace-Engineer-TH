# Part 1: Application Deployment Script

## Objective
Create an automated installation script for deploying Slack on macOS devices.

## Your Solution

### Script Name

install_app.sh

### Language Used

Bash

### How to Run

# If your macOS uses the old Bash version (3.x), install Homebrew and the latest Bash:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash

# Make the script executable (only needed once)
chmod +x install_app.sh

# The script automatically detects your Mac architecture (Intel or Apple Silicon)
# and downloads the correct Slack version.

# Dry run (no changes made)
sudo ./install_app.sh --dry-run

# Regular install (Slack)
sudo ./install_app.sh

# Force reinstall (overwrite if already installed)
sudo ./install_app.sh --force

# Example to install another app (Zoom - optional example in registry)
sudo ./install_app.sh --app zoom

### Features Implemented

- [x] Checks if running on macOS
- [x] Verifies administrative privileges
- [x] Checks internet connectivity
- [x] Downloads Slack .dmg
- [x] Mounts disk image
- [x] Copies application to /Applications
- [x] Cleans up temporary files
- [x] Verifies installation
- [x] Error handling
- [x] Logging

### Bonus Features (if implemented)

- [x] Idempotent (safe to run multiple times)
- [x] Dry-run mode
- [x] Optional “app registry” system to support other apps
- [x] Detects CPU architecture (Intel / Apple Silicon) and installs correct Slack version


### Testing

- Tested on macOS Sequoia with both dry-run and actual installation.
- Confirmed Slack successfully installs to /Applications.
- Verified skip behavior when Slack is already installed (idempotent).
- Verified clean failure if internet or admin rights are missing.
- Verified log creation at /var/log/workplace_installer.log (fallback to /tmp if needed).
- Confirmed cleanup of temp files and DMG unmount.

### Assumptions
- Script is executed with administrative (sudo) privileges.
- macOS device has internet access.
- Slack’s latest version is available from https://slack.com/ssb/download-osx.
- DMG contains Slack.app in its root directory.
- Installation path /Applications is accessible and writable.

### Known Limitations

- Newer Bash version is installed.
- Limited testing on macOS versions older than Monterey.
- Doesn’t support proxy authentication or restricted corporate networks.
- Doesn’t handle auto-updates after installation.
- PKG-based app support (e.g., Zoom) is included as a basic example only.