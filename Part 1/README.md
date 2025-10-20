# Part 1: Application Deployment Script

## Objective
Create an automated installation script for deploying Slack on macOS devices.

## Your Solution

### Script Name
install_app.sh

### Language Used
Bash (requires Bash 4 or newer)

---

## How to Run

#### If your macOS uses the legacy Bash (version 3.x):
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash
```

#### Make the script executable (only once)
```bash
chmod +x install_app.sh
```

#### Run with Homebrew Bash if needed
```bash
sudo /opt/homebrew/bin/bash ./install_app.sh
```

#### The script automatically:
- Detects your Mac architecture (Intel or Apple Silicon)
- Fetches the correct Slack build for your system
- Skips download if the latest version is already installed

#### Common usage examples
```bash
# Dry run (no changes made)
sudo ./install_app.sh --dry-run

# Regular install (Slack)
sudo ./install_app.sh

# Force reinstall (overwrite if already installed)
sudo ./install_app.sh --force

# Example for another app (Zoom – optional PKG example)
sudo ./install_app.sh --app zoom
```

---

## Features Implemented

- [x] Checks if running on macOS  
- [x] Verifies administrative privileges  
- [x] Checks internet connectivity (to the actual host)  
- [x] Detects CPU architecture (Intel / Apple Silicon)  
- [x] Determines latest Slack version before download  
- [x] Skips download if already up-to-date  
- [x] Downloads Slack .dmg  
- [x] Mounts disk image  
- [x] Copies application to `/Applications`  
- [x] Cleans up temporary files  
- [x] Verifies installation  
- [x] Error handling with clear logging  
- [x] Automatic cleanup and unmount on exit (trap)  

---

## Bonus Features

- [x] Idempotent – safe to run multiple times  
- [x] Dry-run mode for safe previews  
- [x] Optional “app registry” system for additional apps  
- [x] PKG-based install path (e.g., Zoom)  
- [x] Robust logging (`/var/log/workplace_installer.log` with `/tmp` fallback)  

---

## Testing

- ✅ Tested on macOS Sequoia (ARM and Intel).  
- ✅ Verified dry-run mode produces correct logs without modifying system.  
- ✅ Confirmed Slack installs successfully to `/Applications`.  
- ✅ Confirmed skip behavior when Slack is already latest version.  
- ✅ Verified graceful failure when internet or admin rights are missing.  
- ✅ Confirmed log creation at `/var/log` (fallback `/tmp` when restricted).  
- ✅ Verified trap-based cleanup removes temp dirs and unmounts DMG on failure.  

---

## Assumptions

- Script executed with administrative (sudo) privileges.  
- macOS device has unrestricted internet access.  
- Slack’s latest version remains available via https://slack.com/ssb/download-osx.  
- DMG includes `Slack.app` at root level.  
- `/Applications` is writable by the installer user.  
- Bash ≥ 4 is available (via Homebrew if necessary).  

---

## Known Limitations

- Limited validation on macOS versions older than Monterey.  
- Doesn’t handle proxy-authenticated or air-gapped networks.  
- Doesn’t manage auto-updates after initial installation.  
- PKG-based logic is basic – primarily demonstrative.  
- Version detection depends on vendor naming convention (Slack’s DMG filename). 