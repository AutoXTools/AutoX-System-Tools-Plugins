#!/bin/sh
# ==============================================================================
# AutoX SSH Server Service Plugin - Standalone Execution & Management Script
# ==============================================================================
# Version: 0.10
# Target: Mazda Connect CMU FW 74.00.324 ONLY
# Architecture: ARMv7 / i.MX6
# Execution Model: Non-blocking background worker with bounded hook injection & security killswitch
# File Location: USB_DRIVE/autox/plugins/autox_ssh.sh
# Installation: /tmp/mnt/data_persist/autox/plugins/autox_ssh.sh
# Security Notice: SSH provides root shell access over custom port 36000.
#                  Disable when not performing diagnostics to prevent network exposure.
# ==============================================================================

PATH=/bin:/usr/bin:/sbin:/usr/sbin:$PATH
export PATH

PLUGIN_NAME="AutoX SSH Server Service"
PLUGIN_ID="ssh"
PLUGIN_TITLE="SSH Remote Access"
PLUGIN_SUBTITLE="Port 36000 root shell (Easy Toggle)"
PLUGIN_CATEGORY="tweak"
PLUGIN_ORDER=20
SHOW_IN_GUI="true"
VERSION="0.10"
# INSTALL_STATE: "enabled" (auto-start on install) or "disabled" (dormant until user toggles)
INSTALL_STATE="disabled"

# Persistent data directory strictly set to physical NAND mount
AUTOX_DIR="/tmp/mnt/data_persist/autox"

PLUGINS_DIR="$AUTOX_DIR/plugins"
ENABLED_DIR="$PLUGINS_DIR/enabled"
LOG_DIR="$AUTOX_DIR/logs"
DATA_DIR="$AUTOX_DIR/data"

SSH_RUN_LOG="$LOG_DIR/ssh.run.log"
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
PLUGIN_TARGET="$PLUGINS_DIR/autox_ssh.sh"
LOCK_FILE="/tmp/autox_ssh.lock"
SSH_FLAG="$ENABLED_DIR/ssh_enabled"
SSHD_CONFIG="/tmp/autox_sshd_config"
STAGE_1="/jci/scripts/stage_1.sh"
STAGE_WIFI="/jci/scripts/stage_wifi.sh"

# Detect active AutoX USB drive (/tmp/mnt/sda1 or /tmp/mnt/sdb1)
USB_ROOT=""
if [ -d "/tmp/mnt/sda1/_autox" ]; then
    USB_ROOT="/tmp/mnt/sda1"
elif [ -d "/tmp/mnt/sdb1/_autox" ]; then
    USB_ROOT="/tmp/mnt/sdb1"
fi
USB_LOG_DIR="$USB_ROOT/_autox/logs"

# Standard NAND Flush & Remount Helpers
cmu_remount_rw() {
    mount -o remount,rw / 2>/dev/null
}

cmu_remount_ro() {
    sync
    mount -o remount,ro / 2>/dev/null
}

# --------------------------------------------------------------------------
# STEP 1: Process Concurrency Lock Guard & Exit Trap
# --------------------------------------------------------------------------
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        PID=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "[WARN] Another process ($PID) is currently running. Exiting."
            exit 0
        fi
    fi
    echo "$$" > "$LOCK_FILE"
    if [ "$IS_UNINSTALLING" = "1" ] || [ "$AUTOX_UNINSTALLING" = "1" ]; then
        trap 'release_lock' EXIT INT TERM HUP
    else
        trap 'mazda_watchdog_enable; cmu_remount_ro; release_lock' EXIT INT TERM HUP
    fi
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null
}

# --------------------------------------------------------------------------
# STEP 2: Hardware Watchdog Protection Helpers
# --------------------------------------------------------------------------
mazda_watchdog_disable() {
    if [ -f "/sys/class/gpio/Watchdog Disable/value" ]; then
        echo 1 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null
    elif [ -f "/sys/class/gpio/Watchdog\ Disable/value" ]; then
        echo 1 > /sys/class/gpio/Watchdog\ Disable/value 2>/dev/null
    fi
}

mazda_watchdog_enable() {
    if [ -f "/sys/class/gpio/Watchdog Disable/value" ]; then
        echo 0 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null
    elif [ -f "/sys/class/gpio/Watchdog\ Disable/value" ]; then
        echo 0 > /sys/class/gpio/Watchdog\ Disable/value 2>/dev/null
    fi
}

# --------------------------------------------------------------------------
# STEP 3: Dual-Vault Logging Subsystem with 50KB Size-Capping
# --------------------------------------------------------------------------
log_event() {
    _TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "BOOT")
    _MSG="[$_TIMESTAMP] $1"
    echo "$_MSG"

    # 1. Primary Vault: Physical NAND (/tmp/mnt/data_persist/autox/logs/<plugin_id>_service.log)
    if [ -d "$LOG_DIR" ] && touch "$LOG_DIR/.wprobe" 2>/dev/null; then
        rm -f "$LOG_DIR/.wprobe" 2>/dev/null
        _NAND_LOG="$LOG_DIR/${PLUGIN_ID}_service.log"
        echo "$_MSG" >> "$_NAND_LOG" 2>/dev/null
        # 50KB Size-Capping Rotation Guard (prevents NAND exhaustion)
        if [ -f "$_NAND_LOG" ] && [ "$(wc -c < "$_NAND_LOG" 2>/dev/null || echo 0)" -gt 51200 ]; then
            tail -n 50 "$_NAND_LOG" > "$_NAND_LOG.tmp" 2>/dev/null && mv -f "$_NAND_LOG.tmp" "$_NAND_LOG" 2>/dev/null
        fi
    fi

    # 2. Secondary Vault: USB Mirror (${USB_ROOT}/_autox/logs/<plugin_id>_service.log)
    if [ -n "$USB_ROOT" ] && [ -d "$USB_LOG_DIR" ] && touch "$USB_LOG_DIR/.wprobe" 2>/dev/null; then
        rm -f "$USB_LOG_DIR/.wprobe" 2>/dev/null
        _USB_LOG="$USB_LOG_DIR/${PLUGIN_ID}_service.log"
        echo "$_MSG" >> "$_USB_LOG" 2>/dev/null
        if [ -f "$_USB_LOG" ] && [ "$(wc -c < "$_USB_LOG" 2>/dev/null || echo 0)" -gt 51200 ]; then
            tail -n 50 "$_USB_LOG" > "$_USB_LOG.tmp" 2>/dev/null && mv -f "$_USB_LOG.tmp" "$_USB_LOG" 2>/dev/null
        fi
    fi
}

# ==============================================================================
# FILE & HOOK OPERATION HELPERS
# ==============================================================================
backup_file() {
    _SRC="$1"
    _ORG="${_SRC}.org"
    if [ -f "$_SRC" ] && [ ! -f "$_ORG" ]; then
        cp -p "$_SRC" "$_ORG" 2>/dev/null || cp "$_SRC" "$_ORG"
        log_event "[BACKUP] Backing up original file: $_SRC -> $_ORG"
    fi
}

restore_file() {
    _SRC="$1"
    _ORG="${_SRC}.org"
    if [ -f "$_ORG" ]; then
        mv -f "$_ORG" "$_SRC" 2>/dev/null || cp -f "$_ORG" "$_SRC"
        log_event "[RESTORE] Restoring original file: $_ORG -> $_SRC"
    fi
}

deploy_file() {
    _SRC="$1"
    _DEST="$2"
    _DIR=$(dirname "$_DEST")
    [ ! -d "$_DIR" ] && mkdir -p "$_DIR"
    cp -f "$_SRC" "$_DEST"
    log_event "[FILE] Adding new file: $_DEST"
}

replace_file() {
    _SRC="$1"
    _DEST="$2"
    backup_file "$_DEST"
    cp -f "$_SRC" "$_DEST"
    log_event "[REPLACE] Replacing existing file: $_DEST"
}

remove_file() {
    _TARGET="$1"
    if [ -f "$_TARGET" ]; then
        rm -f "$_TARGET"
        log_event "[REMOVE] Removing file: $_TARGET"
    fi
}

# --------------------------------------------------------------------------
# STEP 4: Firewall & Port Control
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
open_firewall_ports() {
    log_event "[FIREWALL] Opening TCP inbound port 36000 and ICMP (Ping) on all interfaces (wlan0, eth0, any)..."
    # Ensure kernel allows ICMP echo requests (ping)
    echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 2>/dev/null

    # Flush any previous rules to prevent duplicate rules (including removing legacy port 22)
    for port in 22 36000; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -D INPUT -i wlan0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -D INPUT -i eth0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
    done
    iptables -D INPUT -p icmp -j ACCEPT 2>/dev/null
    iptables -D INPUT -i wlan0 -p icmp -j ACCEPT 2>/dev/null
    iptables -D INPUT -i eth0 -p icmp -j ACCEPT 2>/dev/null
    
    # Insert top-priority accept rules for port 36000 only
    iptables -I INPUT 1 -p tcp --dport 36000 -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i wlan0 -p tcp --dport 36000 -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i eth0 -p tcp --dport 36000 -j ACCEPT 2>/dev/null

    iptables -I INPUT 1 -p icmp -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i wlan0 -p icmp -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i eth0 -p icmp -j ACCEPT 2>/dev/null
}

close_firewall_ports() {
    log_event "[FIREWALL] Closing TCP inbound ports 22 & 36000 and ICMP (eliminating open port risk)..."
    for port in 22 36000; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -D INPUT -i wlan0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -D INPUT -i eth0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
    done
    iptables -D INPUT -p icmp -j ACCEPT 2>/dev/null
    iptables -D INPUT -i wlan0 -p icmp -j ACCEPT 2>/dev/null
    iptables -D INPUT -i eth0 -p icmp -j ACCEPT 2>/dev/null
}

# --------------------------------------------------------------------------
# STEP 6: Host Key Provisioning & SSH Daemon Lifecycle Management
# --------------------------------------------------------------------------
ensure_host_keys() {
    mkdir -p "$DATA_DIR" /tmp/dropbear 2>/dev/null
    
    DROPBEAR_RSA_KEY="$DATA_DIR/dropbear_rsa_host_key"

    # If keys already exist in /etc/dropbear, prioritize them
    if [ -f "/etc/dropbear/dropbear_rsa_host_key" ] && [ -s "/etc/dropbear/dropbear_rsa_host_key" ]; then
        DROPBEAR_RSA_KEY="/etc/dropbear/dropbear_rsa_host_key"
    elif [ ! -f "$DROPBEAR_RSA_KEY" ] || [ ! -s "$DROPBEAR_RSA_KEY" ]; then
        log_event "[KEYS] Generating persistent Dropbear RSA host key in $DROPBEAR_RSA_KEY..."
        if command -v dropbearkey >/dev/null 2>&1; then
            dropbearkey -t rsa -f "$DROPBEAR_RSA_KEY" -s 2048 2>/dev/null || dropbearkey -t rsa -f "$DROPBEAR_RSA_KEY" 2>/dev/null
        elif [ -x /usr/bin/dropbearkey ]; then
            /usr/bin/dropbearkey -t rsa -f "$DROPBEAR_RSA_KEY" 2>/dev/null
        elif [ -x /usr/sbin/dropbearkey ]; then
            /usr/sbin/dropbearkey -t rsa -f "$DROPBEAR_RSA_KEY" 2>/dev/null
        fi

        # Fallback to RAM disk if NAND was read-only
        if [ ! -f "$DROPBEAR_RSA_KEY" ] || [ ! -s "$DROPBEAR_RSA_KEY" ]; then
            DROPBEAR_RSA_KEY="/tmp/dropbear/dropbear_rsa_host_key"
            if command -v dropbearkey >/dev/null 2>&1; then
                dropbearkey -t rsa -f "$DROPBEAR_RSA_KEY" -s 2048 2>/dev/null
            fi
        fi
    fi

    DROPBEAR_KEY_ARGS=""
    if [ -f "$DROPBEAR_RSA_KEY" ] && [ -s "$DROPBEAR_RSA_KEY" ]; then
        DROPBEAR_KEY_ARGS="-r $DROPBEAR_RSA_KEY"
    fi
    if [ -f "/etc/dropbear/dropbear_ecdsa_host_key" ]; then
        DROPBEAR_KEY_ARGS="$DROPBEAR_KEY_ARGS -r /etc/dropbear/dropbear_ecdsa_host_key"
    fi
    if [ -f "/etc/dropbear/dropbear_dss_host_key" ]; then
        DROPBEAR_KEY_ARGS="$DROPBEAR_KEY_ARGS -r /etc/dropbear/dropbear_dss_host_key"
    fi
    if [ -z "$DROPBEAR_KEY_ARGS" ]; then
        DROPBEAR_KEY_ARGS="-R"
    fi
}

start_ssh_daemon() {
    log_event "[DAEMON] Initializing SSH Server Daemon on port 36000..."
    open_firewall_ports
    ensure_host_keys

    # 1. Start dropbear if binary exists (listen exclusively on secure custom port 36000)
    DROPBEAR_BIN=""
    if [ -x /usr/sbin/dropbear ]; then
        DROPBEAR_BIN="/usr/sbin/dropbear"
    elif [ -x /sbin/dropbear ]; then
        DROPBEAR_BIN="/sbin/dropbear"
    elif command -v dropbear >/dev/null 2>&1; then
        DROPBEAR_BIN="$(command -v dropbear)"
    fi

    if [ -n "$DROPBEAR_BIN" ]; then
        killall dropbear 2>/dev/null
        pkill -9 -f "dropbear" 2>/dev/null
        sleep 0.2
        $DROPBEAR_BIN -p 36000 $DROPBEAR_KEY_ARGS -B >> "$SSH_RUN_LOG" 2>&1
        sleep 0.4
        if pidof dropbear >/dev/null 2>&1; then
            log_event "[OK] Dropbear SSH daemon active on port 36000 (PID: $(pidof dropbear))."
        else
            log_event "[WARN] Dropbear launch with key args failed. Retrying with auto-keygen fallback flags (-R -B)..."
            $DROPBEAR_BIN -p 36000 -R -B >> "$SSH_RUN_LOG" 2>&1
            sleep 0.4
            if pidof dropbear >/dev/null 2>&1; then
                log_event "[OK] Dropbear active via auto-keygen fallback on port 36000 (PID: $(pidof dropbear))."
            fi
        fi
    fi

    # 2. Configure & launch OpenSSH sshd if binary exists
    if [ -x /usr/sbin/sshd ]; then
        mkdir -p /etc/ssh /var/empty 2>/dev/null
        cat << 'EOF' > "$SSHD_CONFIG"
Port 36000
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
UsePrivilegeSeparation no
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp /usr/libexec/sftp-server
EOF
        killall sshd 2>/dev/null
        /usr/sbin/sshd -f "$SSHD_CONFIG" 2>/dev/null || /usr/sbin/sshd 2>/dev/null
        log_event "[OK] OpenSSH sshd active on port 36000 (PasswordAuth: Enabled)."
    fi

    mkdir -p "$ENABLED_DIR" 2>/dev/null
    touch "$SSH_FLAG" 2>/dev/null
    sync; sleep 0.2; sync
    log_event "[STATUS] SSH Server Service is now ACTIVE on Port 36000."
}

stop_ssh_daemon() {
    log_event "[DAEMON] Shutting down SSH Server Daemons and locking down open port 36000..."
    
    # Terminate active SSH server daemons
    killall -9 dropbear 2>/dev/null
    killall -9 sshd 2>/dev/null
    pkill -9 -f "dropbear" 2>/dev/null
    pkill -9 -f "sshd" 2>/dev/null

    # Close firewall ports immediately
    close_firewall_ports

    # Clean up temporary configuration
    rm -f "$SSHD_CONFIG" 2>/dev/null
    rm -f "$SSH_FLAG" 2>/dev/null
    sync; sleep 0.2; sync

    log_event "[STATUS] SSH Server Service is now DISABLED (Port 36000 closed)."
}

# --------------------------------------------------------------------------
# STEP 6B: SSH Diagnostics & Troubleshooting Report Routine
# --------------------------------------------------------------------------
run_ssh_diag() {
    echo "=========================================================================="
    echo "AutoX SSH Service Diagnostic & Troubleshooting Suite"
    echo "Target: Mazda Connect CMU FW 74.00.324 | Date: $(date 2>/dev/null || echo 'N/A')"
    echo "=========================================================================="

    echo ""
    echo "[1] Network Interfaces & IP Addresses:"
    for iface in wlan0 eth0 lo; do
        if ifconfig "$iface" >/dev/null 2>&1; then
            IP=$(ifconfig "$iface" 2>/dev/null | awk -F'inet addr:' '{print $2}' | awk '{print $1}')
            [ -z "$IP" ] && IP=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}')
            STATE=$(ifconfig "$iface" 2>/dev/null | grep -q "UP" && echo "UP" || echo "DOWN")
            echo "  - $iface: $STATE (IP: ${IP:-None/Unassigned})"
        else
            echo "  - $iface: Not Present"
        fi
    done

    echo ""
    echo "[2] SSH Binary Detection:"
    for bin in /usr/sbin/dropbear /sbin/dropbear /usr/bin/dropbear /usr/sbin/sshd dropbearkey ssh-keygen iptables; do
        if [ -x "$bin" ]; then
            echo "  - $bin: AVAILABLE (Executable)"
        elif command -v "$bin" >/dev/null 2>&1; then
            echo "  - $bin: AVAILABLE ($(command -v "$bin"))"
        else
            echo "  - $bin: NOT FOUND"
        fi
    done

    echo ""
    echo "[3] Active SSH Processes (PIDs):"
    P_DROPBEAR=$(pidof dropbear 2>/dev/null || pgrep dropbear 2>/dev/null)
    P_SSHD=$(pidof sshd 2>/dev/null || pgrep sshd 2>/dev/null)
    echo "  - Dropbear PID(s): ${P_DROPBEAR:-Not Running}"
    echo "  - OpenSSH sshd PID(s): ${P_SSHD:-Not Running}"

    echo ""
    echo "[4] Listening TCP Port (36000):"
    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep '36000' | sed 's/^/  /' || echo "  No socket listening on port 36000."
    elif [ -f /proc/net/tcp ]; then
        # 8CA0 = 36000 hex
        grep -qi "8CA0" /proc/net/tcp 2>/dev/null && echo "  Found active listening socket in /proc/net/tcp matching port 36000 (0x8CA0)." || echo "  No open socket for port 36000 in /proc/net/tcp."
    else
        echo "  netstat not available; relying on PID checks."
    fi

    echo ""
    echo "[5] Firewall (iptables) Inbound Rules:"
    if command -v iptables >/dev/null 2>&1; then
        iptables -L INPUT -n -v --line-numbers 2>/dev/null | grep -E '36000|dpt:36000|Chain' | sed 's/^/  /' || echo "  No rules found for port 36000 in iptables."
    else
        echo "  iptables not available."
    fi

    echo ""
    echo "[6] User Account & Authentication Status:"
    for user in cmu root; do
        if grep -q "^$user:" /etc/passwd 2>/dev/null; then
            USER_SHELL=$(grep "^$user:" /etc/passwd | cut -d: -f7)
            echo "  - User '$user': EXISTS in /etc/passwd (Shell: $USER_SHELL)"
        else
            echo "  - User '$user': MISSING from /etc/passwd"
        fi
    done

    echo ""
    echo "[7] Host Keys Status:"
    for keypath in /etc/dropbear/dropbear_rsa_host_key "$DATA_DIR/dropbear_rsa_host_key" /tmp/dropbear/dropbear_rsa_host_key /etc/ssh/ssh_host_rsa_key; do
        if [ -f "$keypath" ]; then
            KSIZE=$(wc -c < "$keypath" 2>/dev/null || echo 0)
            echo "  - $keypath: FOUND ($KSIZE bytes)"
        else
            echo "  - $keypath: Not Found"
        fi
    done

    echo ""
    echo "=========================================================================="
    echo "Quick Client Connect Command (Run on your Laptop / PC terminal):"
    echo "  ssh -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedKeyTypes=+ssh-rsa -p 36000 cmu@<CMU_IP>"
    echo "  Default Password: jci"
    echo "=========================================================================="
}

# --------------------------------------------------------------------------
# STEP 7: Status Query Routine (RFC 8259 JSON & Raw API)
# --------------------------------------------------------------------------
get_ssh_status() {
    IS_RUNNING="DISABLED"
    DAEMON_TYPE="none"
    PID_INFO=""

    # Check active running processes
    if pidof sshd >/dev/null 2>&1; then
        DAEMON_TYPE="openssh"
        PID_INFO=$(pidof sshd 2>/dev/null)
    elif pidof dropbear >/dev/null 2>&1; then
        DAEMON_TYPE="dropbear"
        PID_INFO=$(pidof dropbear 2>/dev/null)
    fi

    # Determine status strictly based on AutoX enabled flag
    if [ -f "$SSH_FLAG" ]; then
        if [ -n "$PID_INFO" ]; then
            IS_RUNNING="ENABLED"
        else
            IS_RUNNING="STOPPED"
            DAEMON_TYPE="configured"
        fi
    else
        IS_RUNNING="DISABLED"
    fi

    if [ "$1" = "--raw" ] || [ "$1" = "status" ]; then
        echo "$IS_RUNNING"
    elif [ "$1" = "--json" ] || [ "$1" = "json" ]; then
        cat << EOF
{
  "plugin": "autox_ssh",
  "name": "SSH Server Service",
  "status": "$IS_RUNNING",
  "enabled": $([ "$IS_RUNNING" = "ENABLED" ] && echo "true" || echo "false"),
  "daemon": "$DAEMON_TYPE",
  "ports": [36000],
  "pid": "${PID_INFO:-none}",
  "version": "$VERSION"
}
EOF
    else
        echo "[AutoX SSH] Status: $IS_RUNNING | Daemon: $DAEMON_TYPE | Port: 36000 | PID: ${PID_INFO:-none}"
    fi
}

# --------------------------------------------------------------------------
# STEP 8: Enable Service Routine (Open Firewall, Generate Keys & Launch SSH)
# --------------------------------------------------------------------------
do_enable() {
    acquire_lock
    log_event "=========================================================================="
    log_event "[START] $PLUGIN_NAME v$VERSION Enabling SSH Remote Access"
    log_event "=========================================================================="

    log_event "[STEP 1/5] Remounting CMU root filesystem read-write..."
    cmu_remount_rw

    log_event "[STEP 2/5] Suppressing hardware watchdog for critical write section..."
    mazda_watchdog_disable

    log_event "[STEP 3/5] Ensuring directory structure & generating host keys..."
    mkdir -p "$PLUGINS_DIR" "$ENABLED_DIR" "$LOG_DIR" "$DATA_DIR" 2>/dev/null
    chmod 755 "$PLUGIN_TARGET" 2>/dev/null
    touch "$SSH_FLAG" 2>/dev/null

    log_event "[STEP 4/5] Injecting AutoX SSH Boot Hook into stage_wifi.sh..."
    # 1. Clean legacy hook from stage_1.sh
    if [ -f "$STAGE_1" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_1" 2>/dev/null
        log_event "[HOOK] Cleaned legacy SSH hooks from $STAGE_1"
    fi

    # 2. Inject bounded hook into stage_wifi.sh
    if [ ! -f "$STAGE_WIFI" ]; then
        printf '#!/bin/sh\n' > "$STAGE_WIFI"
    fi
    sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_WIFI" 2>/dev/null
    cat << 'EOF' >> "$STAGE_WIFI"
# === AutoX SSH Server Boot Hook ===
if [ -f /tmp/mnt/data_persist/autox/plugins/enabled/ssh_enabled ] && [ -f /tmp/mnt/data_persist/autox/plugins/autox_ssh.sh ]; then
    /bin/sh /tmp/mnt/data_persist/autox/plugins/autox_ssh.sh start > /tmp/mnt/data_persist/autox/logs/ssh.run.log 2>&1 &
fi
# === AutoX SSH Server Boot Hook End ===
EOF
    chmod 755 "$STAGE_WIFI" 2>/dev/null
    log_event "[HOOK] Placed AutoX SSH boot hook in $STAGE_WIFI"

    log_event "[STEP 5/5] Starting SSH daemon on port 36000 and opening security firewall..."
    start_ssh_daemon

    mazda_watchdog_enable
    cmu_remount_ro
    release_lock

    log_event "=========================================================================="
    log_event "[COMPLETED] $PLUGIN_NAME v$VERSION successfully enabled and active."
    log_event "=========================================================================="

    echo "SSH Server Service: ENABLED (Port 36000 active)"
    return 0
}

# --------------------------------------------------------------------------
# STEP 9: Disable Service Routine ("Easy Button" Security Lockdown)
# --------------------------------------------------------------------------
do_disable() {
    acquire_lock
    log_event "=========================================================================="
    log_event "[START] $PLUGIN_NAME v$VERSION Disabling SSH - Closing Port 36000"
    log_event "=========================================================================="

    log_event "[STEP 1/4] Remounting CMU root filesystem read-write..."
    cmu_remount_rw

    log_event "[STEP 2/4] Removing AutoX SSH Boot Hook from stage_wifi.sh and stage_1.sh..."
    if [ -f "$STAGE_WIFI" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_WIFI" 2>/dev/null
        log_event "[HOOK] Removed AutoX SSH boot hook from $STAGE_WIFI"
    fi
    if [ -f "$STAGE_1" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_1" 2>/dev/null
        log_event "[HOOK] Cleaned legacy SSH hooks from $STAGE_1"
    fi

    log_event "[STEP 3/4] Stopping SSH daemon processes and blocking firewall ports..."
    stop_ssh_daemon
    rm -f "$SSH_FLAG" 2>/dev/null

    log_event "[STEP 4/4] Releasing lock and syncing filesystem..."
    if [ "$IS_UNINSTALLING" != "1" ] && [ "$AUTOX_UNINSTALLING" != "1" ]; then
        cmu_remount_ro
        release_lock
    else
        release_lock
    fi

    log_event "=========================================================================="
    log_event "[COMPLETED] $PLUGIN_NAME v$VERSION disabled. Ports closed and car secured."
    log_event "=========================================================================="

    echo "SSH Server Service: DISABLED (Port 36000 closed)"
    return 0
}

# --------------------------------------------------------------------------
# STEP 10: Master Plugin Installer Routine (Respects INSTALL_STATE)
# --------------------------------------------------------------------------
do_install() {
    acquire_lock
    log_event "=========================================================================="
    log_event "[START] $PLUGIN_NAME v$VERSION Installation Initiated"
    log_event "=========================================================================="

    mkdir -p "$PLUGINS_DIR" "$ENABLED_DIR" "$LOG_DIR" "$DATA_DIR" 2>/dev/null
    release_lock

    # Evaluate INSTALL_STATE: Enabled vs Disabled
    case "$(echo "$INSTALL_STATE" | tr '[:upper:]' '[:lower:]')" in
        "enabled"|"enable"|"1"|"true")
            log_event "INSTALL_STATE is 'enabled'. Activating SSH daemon now..."
            do_enable
            ;;
        "disabled"|"disable"|"0"|"false"|*)
            log_event "INSTALL_STATE is 'disabled'. Plugin deployed in dormant state (waiting for user toggle)."
            rm -f "$SSH_FLAG" 2>/dev/null
            echo "SSH Server Service: DISABLED (Port 36000 closed)"
            ;;
    esac
}

# --------------------------------------------------------------------------
# STEP 11: Standalone Plugin Uninstaller Routine
# --------------------------------------------------------------------------
do_uninstall() {
    export IS_UNINSTALLING=1
    log_event "=========================================================================="
    log_event "[START] $PLUGIN_NAME v$VERSION Uninstallation Initiated"
    log_event "=========================================================================="
    log_event "[STEP 1/3] Terminating active SSH server daemons..."
    
    # Direct termination of SSH daemons without heavy nested lock or iptables teardown
    killall -9 dropbear sshd 2>/dev/null
    pkill -9 -f "dropbear" 2>/dev/null
    pkill -9 -f "sshd" 2>/dev/null
    close_firewall_ports
    
    log_event "[STEP 2/3] Removing AutoX SSH Boot Hooks..."
    # Remove AutoX SSH Boot Hook from stage_wifi.sh and stage_1.sh
    if [ -f "$STAGE_WIFI" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_WIFI" 2>/dev/null
        log_event "[HOOK] Removed boot hook from $STAGE_WIFI"
    fi
    if [ -f "$STAGE_1" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_1" 2>/dev/null
        log_event "[HOOK] Cleaned legacy boot hook from $STAGE_1"
    fi
    
    log_event "[STEP 3/3] Removing plugin specific state flags and configs..."
    # Remove plugin specific state flags and configs
    rm -f "$SSHD_CONFIG" "$SSH_FLAG" "$LOCK_FILE" 2>/dev/null
    release_lock
    log_event "=========================================================================="
    log_event "[COMPLETED] $PLUGIN_NAME v$VERSION uninstalled."
    log_event "=========================================================================="
    return 0
}

# --------------------------------------------------------------------------
# STEP 12: Interactive Toggle Handler (Used by Opera Web GUI & CGI Dispatcher)
# --------------------------------------------------------------------------
do_toggle() {
    if [ -f "$SSH_FLAG" ]; then
        do_disable
    else
        do_enable
    fi
}

# --------------------------------------------------------------------------
# STEP 13: CLI Dispatcher & Argument Router (Zero-Dialog Headless Contract)
# --------------------------------------------------------------------------
case "$1" in
    start|--start)
        log_event "Started do_start event"
        start_ssh_daemon
        ;;
    stop|--stop)
        log_event "Started do_stop event"
        stop_ssh_daemon
        ;;
    restart|--restart|reload)
        log_event "Started do_restart event"
        echo "[AutoX SSH] Restarting SSH Daemons..."
        stop_ssh_daemon
        sleep 0.5
        start_ssh_daemon
        ;;
    diag|--diag|diagnose|doctor|report)
        log_event "Started do_diag event"
        run_ssh_diag
        ;;
    test|--test)
        log_event "Started do_test event"
        echo "[AutoX SSH] Running immediate test suite..."
        run_ssh_diag
        ;;
    debug|--debug)
        log_event "Started do_debug event"
        echo "[AutoX SSH] Launching Dropbear in foreground debug mode on port 36000 (Ctrl+C to exit)..."
        open_firewall_ports
        ensure_host_keys
        killall dropbear 2>/dev/null
        pkill -9 -f "dropbear" 2>/dev/null
        if [ -x /usr/sbin/dropbear ]; then
            /usr/sbin/dropbear -F -E -p 36000 $DROPBEAR_KEY_ARGS -B
        elif [ -x /sbin/dropbear ]; then
            /sbin/dropbear -F -E -p 36000 $DROPBEAR_KEY_ARGS -B
        else
            dropbear -F -E -p 36000 -R -B
        fi
        ;;
    install|--install|-i)
        log_event "Started do_install event"
        do_install "$2"
        ;;
    enable|--enable)
        log_event "Started do_enable event"
        do_enable "$2"
        ;;
    disable|--disable)
        log_event "Started do_disable event"
        do_disable "$2"
        ;;
    uninstall|--uninstall|-u|off|--off)
        log_event "Started do_uninstall event"
        do_uninstall "$2"
        ;;
    toggle|--toggle)
        log_event "Started do_toggle event"
        do_toggle
        ;;
    status|--status|-s)
        get_ssh_status --raw
        ;;
    meta|--meta|info|--info)
        _STAT=$(get_ssh_status --raw 2>/dev/null)
        echo "{\"id\":\"$PLUGIN_ID\",\"title\":\"$PLUGIN_TITLE\",\"subtitle\":\"$PLUGIN_SUBTITLE\",\"category\":\"$PLUGIN_CATEGORY\",\"order\":$PLUGIN_ORDER,\"version\":\"$VERSION\",\"status\":\"$_STAT\",\"show_in_gui\":true}"
        ;;
    json|--json)
        get_ssh_status --json
        ;;
    shutdown|--shutdown)
        log_event "Shutdown signal received - stopping SSH daemon"
        stop_ssh_daemon
        exit 0
        ;;
    help|--help|-h|*)
        log_event "Started do_help/usage event"
        echo "$PLUGIN_NAME v$VERSION"
        echo "Usage: autox_ssh.sh [start|stop|restart|enable|disable|toggle|status|json|meta|diag|install|uninstall]"
        ;;
esac
