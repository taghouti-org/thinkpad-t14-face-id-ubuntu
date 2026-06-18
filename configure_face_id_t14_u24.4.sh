#!/bin/bash
# ============================================================================
# configure_face_id_t14_u24.4.sh
#
# Installs and configures Howdy face authentication on:
#   - ThinkPad T14 Gen 15 (or similar with IR camera)
#   - Ubuntu 24.04 LTS
#
# Fixes applied:
#   - pam_python.so is broken on Ubuntu 24.04 (Python 3.12 incompatibility)
#   - Uses pam_exec.so instead for reliable PAM integration
#   - IR camera warmup frames for reliable detection
#   - File permissions for non-root PAM execution
#   - gdm user camera access for login screen
#
# Usage: sudo ./configure_face_id_t14_u24.4.sh
# After: sudo howdy add  (to register your face)
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo ./configure_face_id_t14_u24.4.sh)"
    exit 1
fi

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Proceed with caution."
fi

ACTUAL_USER="${SUDO_USER:-$USER}"
if [[ "$ACTUAL_USER" == "root" ]]; then
    err "Run via sudo from a regular user, not as root directly."
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect IR camera
# ---------------------------------------------------------------------------
log "Detecting IR camera..."

IR_DEVICE=""
IR_BY_PATH=""

for dev in /dev/video*; do
    [[ -e "$dev" ]] || continue
    dev_name=$(v4l2-ctl -d "$dev" --all 2>/dev/null | grep "Card type" || true)
    if echo "$dev_name" | grep -qi "Integrated I\|IR\|infrared"; then
        IR_DEVICE="$dev"
        # Find by-path entry
        for bp in /dev/v4l/by-path/*; do
            [[ -L "$bp" ]] || continue
            if readlink -f "$bp" 2>/dev/null | grep -q "$(basename "$dev")"; then
                IR_BY_PATH="$bp"
                break
            fi
        done
        break
    fi
done

# Fallback: if we have 4 video devices on a ThinkPad, video2 is usually IR
if [[ -z "$IR_DEVICE" ]]; then
    video_count=$(ls /dev/video* 2>/dev/null | wc -l)
    if [[ "$video_count" -ge 3 ]] && [[ -e /dev/video2 ]]; then
        # Verify it's actually an IR camera
        check=$(v4l2-ctl -d /dev/video2 --list-formats-ext 2>/dev/null | grep -i "GREY\|IR" || true)
        if [[ -n "$check" ]]; then
            IR_DEVICE="/dev/video2"
            IR_BY_PATH="/dev/v4l/by-path/$(ls /dev/v4l/by-path/ 2>/dev/null | grep "1.2" | head -1)"
            [[ -z "$IR_BY_PATH" || ! -e "$IR_BY_PATH" ]] && IR_BY_PATH=""
        fi
    fi
fi

if [[ -z "$IR_DEVICE" ]]; then
    err "No IR camera detected. Face ID requires an IR camera."
    err "Detected cameras:"
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        v4l2-ctl -d "$dev" --all 2>/dev/null | grep "Card type" | sed "s/^/    $dev: /"
    done
    exit 1
fi

log "IR camera found: $IR_DEVICE"
[[ -n "$IR_BY_PATH" ]] && info "By-path: $IR_BY_PATH"

# Use by-path if available (more stable), otherwise use /dev/videoN
CAMERA_PATH="${IR_BY_PATH:-$IR_DEVICE}"

# ---------------------------------------------------------------------------
# Step 1: Install howdy and dependencies
# ---------------------------------------------------------------------------
log "Step 1: Installing howdy and dependencies..."

# Check if howdy is already installed
if command -v howdy &>/dev/null || [[ -d /lib/security/howdy ]]; then
    info "Howdy already installed, skipping apt install"
else
    # Temporarily allow pip installs for howdy's postinst
    MANAGED_FILE="/usr/lib/python3.12/EXTERNALLY-MANAGED"
    MANAGED_BAK="${MANAGED_FILE}.bak"
    if [[ -f "$MANAGED_FILE" ]] && [[ ! -f "$MANAGED_BAK" ]]; then
        cp "$MANAGED_FILE" "$MANAGED_BAK"
    fi

    HOWDY_NO_PROMPT=1 apt-get install -y howdy 2>&1 || true

    # Restore PEP 668 marker
    if [[ -f "$MANAGED_BAK" ]]; then
        mv "$MANAGED_BAK" "$MANAGED_FILE"
        chmod 644 "$MANAGED_FILE"
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Fix howdy postinst (if it failed during apt install)
# ---------------------------------------------------------------------------
log "Step 2: Ensuring howdy is fully configured..."

if [[ ! -f /lib/security/howdy/compare.py ]]; then
    err "Howdy installation incomplete (compare.py missing). Check apt output."
    exit 1
fi

# Run postinst if it hasn't completed (check for dlib data)
if [[ ! -f /lib/security/howdy/dlib-data/shape_predictor_5_face_landmarks.dat ]]; then
    warn "Running howdy post-install setup..."

    # Temporarily remove PEP 668 for pip
    MANAGED_FILE="/usr/lib/python3.12/EXTERNALLY-MANAGED"
    MANAGED_BAK="${MANAGED_FILE}.bak"
    if [[ -f "$MANAGED_FILE" ]] && [[ ! -f "$MANAGED_BAK" ]]; then
        cp "$MANAGED_FILE" "$MANAGED_BAK"
    fi

    echo "none;3.5" > /tmp/howdy_picked_device
    HOWDY_NO_PROMPT=1 /var/lib/dpkg/info/howdy.postinst configure 2.6.1 || true
    rm -f /tmp/howdy_picked_device

    # Restore PEP 668 marker
    if [[ -f "$MANAGED_BAK" ]]; then
        mv "$MANAGED_BAK" "$MANAGED_FILE"
        chmod 644 "$MANAGED_FILE"
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: Fix pam.py (Python 3.12 compatibility)
# ---------------------------------------------------------------------------
log "Step 3: Fixing pam.py for Python 3.12..."

PAM_PY="/lib/security/howdy/pam.py"
if grep -q "import ConfigParser" "$PAM_PY" 2>/dev/null; then
    sed -i 's/^import ConfigParser$/import configparser/' "$PAM_PY"
    sed -i 's/^config = ConfigParser\.ConfigParser()$/config = configparser.ConfigParser()/' "$PAM_PY"
    log "Fixed ConfigParser -> configparser"
fi

# Remove old Python 2 comment if present
sed -i '/^# pam-python is running python 2/d' "$PAM_PY" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: Fix file permissions (PAM needs non-root read access)
# ---------------------------------------------------------------------------
log "Step 4: Fixing file permissions for PAM execution..."

chmod -R o+rX /lib/security/howdy/
chmod -R o+rX /lib/security/howdy/recorders/ 2>/dev/null || true
mkdir -p /lib/security/howdy/snapshots
chmod 777 /lib/security/howdy/snapshots
mkdir -p /lib/security/howdy/models
chmod 755 /lib/security/howdy/models

# ---------------------------------------------------------------------------
# Step 5: Fix IR camera warmup
# ---------------------------------------------------------------------------
log "Step 5: Adding IR camera warmup frames..."

VIDEO_CAPTURE="/lib/security/howdy/recorders/video_capture.py"
if ! grep -q "_warmup in range" "$VIDEO_CAPTURE" 2>/dev/null; then
    python3 -c "
import re

with open('$VIDEO_CAPTURE', 'r') as f:
    content = f.read()

old = '\t\tself.internal.grab()'
new = '''\t\t# Request frames to wake the IR camera up
\t\tfor _warmup in range(20):
\t\t\tself.internal.grab()'''

content = content.replace(old, new, 1)

with open('$VIDEO_CAPTURE', 'w') as f:
    f.write(content)
"
    log "Added 20-frame camera warmup"
fi

# ---------------------------------------------------------------------------
# Step 6: Configure howdy - set IR camera path
# ---------------------------------------------------------------------------
log "Step 6: Configuring howdy to use IR camera..."

HOWDY_CONFIG="/lib/security/howdy/config.ini"

# Set device_path
if grep -q "^device_path = none" "$HOWDY_CONFIG" 2>/dev/null || \
   grep -q "^device_path = /dev/video" "$HOWDY_CONFIG" 2>/dev/null; then
    sed -i "s|^device_path = .*|device_path = $CAMERA_PATH|" "$HOWDY_CONFIG"
    log "Set device_path = $CAMERA_PATH"
fi

# ---------------------------------------------------------------------------
# Step 7: Create PAM wrapper script
# ---------------------------------------------------------------------------
log "Step 7: Creating PAM wrapper script..."

cat > /usr/local/bin/howdy-pam-wrapper << 'WRAPPER'
#!/bin/bash
# Howdy PAM wrapper - runs face auth via pam_exec.so
# pam_exec sets PAM_USER environment variable

HOWDY_DIR="/lib/security/howdy"
TIMEOUT=8

# Check if howdy is disabled
if grep -q "^disabled = true" "$HOWDY_DIR/config.ini" 2>/dev/null; then
    exit 1
fi

# Get user from PAM_USER (set by pam_exec) or first argument
USER="${PAM_USER:-$1}"
if [ -z "$USER" ]; then
    exit 1
fi

# Check if user has a face model
if [ ! -f "$HOWDY_DIR/models/$USER.dat" ]; then
    exit 1
fi

# Run compare.py with timeout from the howdy directory (needed for imports)
cd "$HOWDY_DIR"
PYTHONPATH="$HOWDY_DIR" timeout $TIMEOUT /usr/bin/python3 "$HOWDY_DIR/compare.py" "$USER" >/dev/null 2>&1
exit $?
WRAPPER

chmod +x /usr/local/bin/howdy-pam-wrapper
log "Installed /usr/local/bin/howdy-pam-wrapper"

# ---------------------------------------------------------------------------
# Step 8: Configure camera access for GDM
# ---------------------------------------------------------------------------
log "Step 8: Configuring camera access for GDM..."

# Add gdm to video group
if id gdm &>/dev/null; then
    usermod -a -G video gdm
    info "Added gdm to video group"
fi

# Add current user to video group
usermod -a -G video "$ACTUAL_USER"
info "Added $ACTUAL_USER to video group"

# Create udev rule for persistent camera permissions
cat > /etc/udev/rules.d/99-face-auth-video.rules << 'UDEV'
KERNEL=="video*", GROUP="video", MODE="0660"
UDEV
udevadm control --reload-rules 2>/dev/null && udevadm trigger 2>/dev/null || true
info "Applied udev rule for /dev/video*"

# ---------------------------------------------------------------------------
# Step 9: Configure PAM for GDM login
# ---------------------------------------------------------------------------
log "Step 9: Configuring PAM for GDM login screen..."

GDM_PAM="/etc/pam.d/gdm-password"

# Backup current config
if [[ ! -f "${GDM_PAM}.howdy-backup" ]]; then
    cp "$GDM_PAM" "${GDM_PAM}.howdy-backup"
    info "Backed up $GDM_PAM -> ${GDM_PAM}.howdy-backup"
fi

# Remove any existing howdy/pam_python entries
sed -i '/pam_python.so.*howdy/d' "$GDM_PAM" 2>/dev/null || true
sed -i '/pam_exec.so.*howdy/d' "$GDM_PAM" 2>/dev/null || true

# Add pam_exec line before @include common-auth
if ! grep -q "pam_exec.so.*howdy" "$GDM_PAM"; then
    sed -i '/@include common-auth/i auth    [success=done default=ignore]    pam_exec.so quiet stdout /usr/local/bin/howdy-pam-wrapper' "$GDM_PAM"
    log "Added howdy to GDM PAM (before common-auth)"
else
    info "Howdy already configured in GDM PAM"
fi

# ---------------------------------------------------------------------------
# Step 10: Restore clean common-auth (remove any pam_python remnants)
# ---------------------------------------------------------------------------
log "Step 10: Cleaning up common-auth..."

COMMON_AUTH="/etc/pam.d/common-auth"

# Remove pam_python lines that break authentication
if grep -q "pam_python" "$COMMON_AUTH" 2>/dev/null; then
    sed -i '/pam_python/d' "$COMMON_AUTH"
    warn "Removed broken pam_python line from common-auth"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Howdy Face ID - Installation Complete"
echo "============================================"
echo ""
log "IR Camera:  $CAMERA_PATH"
log "Config:     $HOWDY_CONFIG"
log "Wrapper:    /usr/local/bin/howdy-pam-wrapper"
log "GDM PAM:    $GDM_PAM"
echo ""
echo "Next steps:"
echo ""
echo "  1. Register your face (look at the IR camera):"
echo "     sudo howdy add"
echo ""
echo "  2. Test face detection:"
echo "     sudo howdy test"
echo ""
echo "  3. Lock screen and test login:"
echo "     Ctrl+Alt+L"
echo ""
echo "Config options (edit $HOWDY_CONFIG):"
echo "  - certainty = 3.5   (lower = stricter matching, range 1-10)"
echo "  - timeout   = 4     (seconds to search for face)"
echo "  - disabled  = false  (set true to disable)"
echo ""
echo "To uninstall:"
echo "  sudo rm /usr/local/bin/howdy-pam-wrapper"
echo "  sudo sed -i '/pam_exec.so.*howdy/d' /etc/pam.d/gdm-password"
echo "  sudo cp ${GDM_PAM}.howdy-backup $GDM_PAM  # if backup exists"
echo ""
