# Part 1: Application Deployment Script

## Objective
Create an automated installation script for deploying Slack on macOS devices.

## Your Solution

### Script Name

install_app.sh

### Language Used

Bash (requires Bash 4 or newer)

### How to Run

### If your macOS uses the old Bash version (3.x), install Homebrew and the latest Bash:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash

### Make the script executable (only needed once)
chmod +x install_app.sh

### Run with Homebrew Bash if needed
sudo /opt/homebrew/bin/bash ./install_app.sh


### The script automatically detects your Mac architecture (Intel or Apple Silicon)
### and downloads the correct Slack version.

### Dry run (no changes made)
sudo ./install_app.sh --dry-run

### Regular install (Slack)
sudo ./install_app.sh

### Force reinstall (overwrite if already installed)
sudo ./install_app.sh --force

### Example to install another app (Zoom - optional example in registry)
sudo ./install_app.sh --app zoom

### Features Implemented

- [x] Checks if running on macOS
- [x] Verifies administrative privileges
- [x] Checks internet connectivity
- [x] Detects CPU architecture (Intel / Apple Silicon)
- [x] Determines latest Slack version before download
- [x] Downloads Slack .dmg
- [x] Mounts disk image
- [x] Copies application to /Applications
- [x] Cleans up temporary files
- [x] Verifies installation
- [x] Error handling
- [x] Automatic cleanup and unmount on exit (trap)

### Bonus Features (if implemented)

- [x] Idempotent (safe to run multiple times)
- [x] Dry-run mode
- [x] Optional “app registry” system to support other apps
- [x] PKG-based install path (e.g., Zoom)
- [x] Robust logging ( /var/log/workplace_installer.log with /tmp fallback )

### Testing

- Tested on macOS Sequoia with both dry-run and actual installation.
- Confirmed Slack successfully installs to /Applications.
- Verified skip behavior when Slack is already installed (idempotent).
- Verified clean failure if internet or admin rights are missing.
- Verified log creation at /var/log/workplace_installer.log.
- Verified trap-based cleanup removes temp dirs and unmounts DMG on failure.

### Assumptions
- Script is executed with administrative (sudo) privileges.
- macOS device has unrestricted internet access.
- Slack’s latest version is available from https://slack.com/ssb/download-osx.
- Installation path /Applications is accessible and writable.
- Bash ≥ 4 is available (via Homebrew if necessary).

### Known Limitations
- Limited testing on macOS versions older than Sequoia.
- Doesn’t support proxy authentication or restricted corporate networks.
- Doesn’t handle auto-updates after installation.
- PKG-based app support (e.g., Zoom) is included as a basic example only.