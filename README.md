# Face ID Setup for ThinkPad T14 Gen 15 — Ubuntu 24.04

Installs and configures [Howdy](https://github.com/boltgolt/howdy) face authentication on Ubuntu 24.04 LTS, fixing all known compatibility issues.

## Requirements

- ThinkPad T14 Gen 15 (or similar with IR camera)
- Ubuntu 24.04 LTS
- Root access (`sudo`)

## Quick Start

```bash
sudo ./configure_face_id_t14_u24.4.sh
sudo howdy add        # register your face
Ctrl+Alt+L            # test login screen
```

## What the Script Does

The script runs 10 automated steps:

1. **Installs howdy** via apt (skips interactive prompts)
2. **Completes post-install** if dlib data files are missing
3. **Fixes Python 3.12 compatibility** — `ConfigParser` → `configparser` in `pam.py`
4. **Fixes file permissions** — makes howdy files readable by non-root (needed for PAM)
5. **Adds IR camera warmup** — 20-frame buffer for reliable detection on ThinkPad IR cameras
6. **Auto-detects IR camera** — sets `device_path` in howdy config
7. **Creates PAM wrapper** — `/usr/local/bin/howdy-pam-wrapper` using `pam_exec.so` instead of broken `pam_python.so`
8. **Configures GDM camera access** — adds `gdm` user to `video` group, creates udev rule
9. **Configures GDM login** — adds `pam_exec.so` to `/etc/pam.d/gdm-password`
10. **Cleans up common-auth** — removes broken `pam_python` entries

## Why `pam_exec.so` Instead of `pam_python.so`?

Howdy's default PAM integration uses `pam_python.so`, which is broken on Ubuntu 24.04 with Python 3.12. The module fails silently during GDM login, causing face auth to never trigger. This script uses `pam_exec.so` with a bash wrapper instead, which is a standard, reliable PAM module.

## Password Fallback

Face auth is configured with `default=ignore` and a short timeout (8 seconds). If face detection fails or the camera is unavailable, you can immediately type your password to log in. You don't need to wait for face auth to timeout.

## Files Modified

| File | Change |
|------|--------|
| `/etc/pam.d/gdm-password` | Added `pam_exec.so` line for howdy |
| `/etc/pam.d/common-auth` | Removed broken `pam_python` line |
| `/usr/local/bin/howdy-pam-wrapper` | **Created** — wrapper script for PAM |
| `/etc/udev/rules.d/99-face-auth-video.rules` | **Created** — camera group permissions |
| `/lib/security/howdy/pam.py` | Fixed Python 3 import |
| `/lib/security/howdy/recorders/video_capture.py` | Added IR camera warmup |
| `/lib/security/howdy/config.ini` | Set IR camera device path |
| `/etc/group` | Added `gdm` and user to `video` group |

## After Installation

```bash
sudo howdy add        # Register your face (look at IR camera)
sudo howdy test       # Test face detection with preview window
sudo howdy list       # List registered face models
```

## Configuration

Edit `/lib/security/howdy/config.ini` to adjust settings:

```ini
[video]
certainty = 3.5    # Lower = stricter matching (1-10, recommended 3-5)
timeout = 4        # Seconds to search for face
device_path = /dev/v4l/by-path/...  # IR camera path (auto-detected)

[core]
disabled = false   # Set true to disable face auth
```

## Uninstall

```bash
# Remove wrapper and PAM config
sudo rm /usr/local/bin/howdy-pam-wrapper
sudo sed -i '/pam_exec.so.*howdy/d' /etc/pam.d/gdm-password

# Restore GDM PAM backup if it exists
sudo cp /etc/pam.d/gdm-password.howdy-backup /etc/pam.d/gdm-password

# Remove howdy entirely
sudo apt remove howdy
```

## Troubleshooting

**Face not detected at login screen:**
- Check the IR camera is working: `v4l2-ctl -d /dev/video2 --all`
- Verify `gdm` is in the `video` group: `id gdm`
- Check howdy test works: `sudo howdy test`

**Face auth works but login still requires password:**
- This is normal — face auth runs in parallel with password auth
- If face matches quickly, you'll be logged in without typing
- If not, type your password and press Enter

**Camera not found:**
- Check `/dev/video*` devices: `ls -la /dev/video*`
- The IR camera usually shows as "Integrated Camera: Integrated I"
- Edit `device_path` in `/lib/security/howdy/config.ini` manually

## Hardware

Tested on:
- **Lenovo ThinkPad T14 Gen 15** with Chicony IR camera (`04f2:b805`)
- Ubuntu 24.04.4 LTS, kernel 6.17.x

---

First published as a [gist](https://gist.github.com/taghouttarek/4b228400c5260af201267d195bd8b26c).
