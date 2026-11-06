#!/bin/sh
# ==============================================================================
# AutoX SSH Server Service Plugin - Standard Target Module (OpenSSH sshd)
# ==============================================================================
# Target Platform: Mazda Connect CMU FW 74.00.324 ONLY
# Architecture: ARMv7 / i.MX6 Dual/Quad SoC
# Security Notice: SSH provides root shell access over custom port 36000.
#                  Disable when not performing diagnostics to prevent exposure.
# ==============================================================================

PATH=/bin:/usr/bin:/sbin:/usr/sbin:$PATH
export PATH

# --------------------------------------------------------------------------
# 1. MANDATORY METADATA MANIFEST
# --------------------------------------------------------------------------
NAME="AutoX SSH Server Service"
AUTHOR="AutoX Developer Network"
ID="ssh"
TITLE="SSH Remote Access"
SUBTITLE="Port 36000 root shell (Easy Toggle)"
CATEGORY="tweak"
ORDER=20
SHOW_IN_GUI="true"
VERSION="0.11"
INSTALL_STATE="disabled"

# --------------------------------------------------------------------------
# 2. DETERMINISTIC TOPOLOGY PATHS
# --------------------------------------------------------------------------
AUTOX_DIR="/tmp/mnt/data_persist/autox"
PLUGINS_DIR="$AUTOX_DIR/plugins"
ENABLED_DIR="$PLUGINS_DIR/enabled"
LOG_DIR="$AUTOX_DIR/logs"
DATA_DIR="$AUTOX_DIR/data"

FLAG="$ENABLED_DIR/${ID}_enabled"
LOCK_FILE="/tmp/autox_${ID}.lock"
PLUGIN_TARGET="$PLUGINS_DIR/autox_${ID}.sh"
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
[ -z "$SCRIPT_PATH" ] && SCRIPT_PATH="$0"

SSH_RUN_LOG="$LOG_DIR/ssh.run.log"
SSHD_CONFIG="/tmp/autox_sshd_config"
STAGE_1="/jci/scripts/stage_1.sh"
STAGE_WIFI="/jci/scripts/stage_wifi.sh"

# --------------------------------------------------------------------------
# 3. CENTRALIZED AUTOX RUNTIME LIBRARY
# --------------------------------------------------------------------------
. /tmp/mnt/data_persist/autox/lib/autox_lib.sh

# --------------------------------------------------------------------------
# 4. FIREWALL & PORT CONTROL
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Summary: Firewall Port Opening Routine (Allows TCP 36000 & ICMP on all interfaces)
# --------------------------------------------------------------------------
open_firewall_ports() {
    log_event "[FIREWALL] Opening TCP inbound port 36000 and ICMP on all interfaces..."
    echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 2>/dev/null

    for port in 22 36000; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -D INPUT -i wlan0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -D INPUT -i eth0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null
    done
    iptables -D INPUT -p icmp -j ACCEPT 2>/dev/null
    iptables -D INPUT -i wlan0 -p icmp -j ACCEPT 2>/dev/null
    iptables -D INPUT -i eth0 -p icmp -j ACCEPT 2>/dev/null

    iptables -I INPUT 1 -p tcp --dport 36000 -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i wlan0 -p tcp --dport 36000 -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i eth0 -p tcp --dport 36000 -j ACCEPT 2>/dev/null

    iptables -I INPUT 1 -p icmp -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i wlan0 -p icmp -j ACCEPT 2>/dev/null
    iptables -I INPUT 1 -i eth0 -p icmp -j ACCEPT 2>/dev/null
}

# --------------------------------------------------------------------------
# Summary: Firewall Lockdown Routine (Closes TCP 22 & 36000 and ICMP)
# --------------------------------------------------------------------------
close_firewall_ports() {
    log_event "[FIREWALL] Closing TCP inbound ports 22 & 36000 and ICMP..."
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
# 5. HOST KEY PROVISIONING & OPENSSH DAEMON LIFECYCLE (ZERO-FALLBACK)
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Summary: Persistent RSA Host Key Provisioning (Generates host key if missing)
# --------------------------------------------------------------------------
ensure_host_keys() {
    mkdir -p "$DATA_DIR" 2>/dev/null
    SSH_RSA_KEY="$DATA_DIR/ssh_host_rsa_key"

    if [ ! -f "$SSH_RSA_KEY" ] || [ ! -s "$SSH_RSA_KEY" ]; then
        log_event "[KEYS] Generating persistent OpenSSH RSA host key in $SSH_RSA_KEY..."
        if [ ! -x /usr/bin/ssh-keygen ]; then
            log_event "[ERROR] /usr/bin/ssh-keygen not found. Cannot provision host key."
            return 1
        fi
        /usr/bin/ssh-keygen -t rsa -N "" -f "$SSH_RSA_KEY" >/dev/null 2>&1
        if [ ! -f "$SSH_RSA_KEY" ] || [ ! -s "$SSH_RSA_KEY" ]; then
            log_event "[ERROR] Failed to write persistent RSA host key to $SSH_RSA_KEY."
            return 1
        fi
    fi

    chmod 600 "$SSH_RSA_KEY" 2>/dev/null
    return 0
}

# --------------------------------------------------------------------------
# Summary: Daemon Lifecycle Start Handler (Launches OpenSSH sshd on port 36000)
# --------------------------------------------------------------------------
start_ssh_daemon() {
    log_event "[DAEMON] Initializing OpenSSH sshd on port 36000..."
    open_firewall_ports

    if [ ! -x /usr/sbin/sshd ]; then
        log_event "[ERROR] /usr/sbin/sshd binary not found."
        return 1
    fi

    if ! ensure_host_keys; then
        log_event "[ERROR] Host key provisioning failed. Aborting sshd start."
        return 1
    fi

    mkdir -p /var/empty /tmp/var/run 2>/dev/null
    cat << EOF > "$SSHD_CONFIG"
Port 36000
Protocol 2
PidFile /tmp/var/run/sshd.pid
HostKey $SSH_RSA_KEY
UsePrivilegeSeparation no
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
ChallengeResponseAuthentication no
UsePAM no
EOF

    killall -9 sshd 2>/dev/null
    usleep 300000

    /usr/sbin/sshd -f "$SSHD_CONFIG" >> "$SSH_RUN_LOG" 2>&1
    usleep 300000

    if pidof sshd >/dev/null 2>&1; then
        log_event "[OK] OpenSSH sshd active on port 36000 (PID: $(pidof sshd))."
    else
        log_event "[ERROR] OpenSSH sshd failed to bind port 36000. Check $SSH_RUN_LOG."
        return 1
    fi

    mkdir -p "$ENABLED_DIR" 2>/dev/null
    touch "$FLAG" 2>/dev/null
    sync
    log_event "[STATUS] SSH Server Service is now ACTIVE on Port 36000."
    return 0
}

# --------------------------------------------------------------------------
# Summary: Daemon Lifecycle Stop Handler (Kills sshd, restores firewall & cleans state)
# --------------------------------------------------------------------------
stop_ssh_daemon() {
    log_event "[DAEMON] Shutting down OpenSSH sshd and locking down port 36000..."
    killall -9 sshd 2>/dev/null
    close_firewall_ports
    rm -f "$SSHD_CONFIG" "$FLAG" 2>/dev/null
    sync
    log_event "[STATUS] SSH Server Service is now DISABLED (Port 36000 closed)."
}

# --------------------------------------------------------------------------
# 6. DIAGNOSTICS & STATUS QUERY ROUTINES
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Summary: Comprehensive Diagnostic Suite (Inspects interfaces, binaries, ports, firewall & keys)
# --------------------------------------------------------------------------
run_ssh_diag() {
    echo "=========================================================================="
    echo "AutoX SSH Service Diagnostic & Troubleshooting Suite"
    echo "Target: Mazda Connect CMU FW 74.00.324 | Date: $(date 2>/dev/null)"
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
    for bin in /usr/sbin/sshd /usr/bin/ssh-keygen /usr/sbin/iptables; do
        if [ -x "$bin" ]; then
            echo "  - $bin: AVAILABLE (Executable)"
        else
            echo "  - $bin: NOT FOUND"
        fi
    done

    echo ""
    echo "[3] Active SSH Processes (PIDs):"
    P_SSHD=$(pidof sshd 2>/dev/null)
    echo "  - OpenSSH sshd PID(s): ${P_SSHD:-Not Running}"

    echo ""
    echo "[4] Listening TCP Port (36000):"
    if [ -f /proc/net/tcp ]; then
        grep -qi "8CA0" /proc/net/tcp 2>/dev/null && echo "  Found active listening socket in /proc/net/tcp matching port 36000 (0x8CA0)." || echo "  No open socket for port 36000 in /proc/net/tcp."
    fi

    echo ""
    echo "[5] Firewall (iptables) Inbound Rules:"
    iptables -L INPUT -n -v --line-numbers 2>/dev/null | grep -E '36000|dpt:36000|Chain' | sed 's/^/  /'

    echo ""
    echo "[6] Host Key Status:"
    if [ -f "$DATA_DIR/ssh_host_rsa_key" ]; then
        KSIZE=$(wc -c < "$DATA_DIR/ssh_host_rsa_key" 2>/dev/null)
        echo "  - $DATA_DIR/ssh_host_rsa_key: FOUND ($KSIZE bytes)"
    else
        echo "  - $DATA_DIR/ssh_host_rsa_key: Not Found"
    fi
}

# --------------------------------------------------------------------------
# Summary: Runtime Execution State Query (Returns "ENABLED" | "STOPPED" | "DISABLED", supports --json)
# --------------------------------------------------------------------------
get_status() {
    IS_RUNNING="DISABLED"
    PID_INFO=$(pidof sshd 2>/dev/null)

    if [ -f "$FLAG" ]; then
        if [ -n "$PID_INFO" ]; then
            IS_RUNNING="ENABLED"
        else
            IS_RUNNING="STOPPED"
        fi
    fi

    if [ "$1" = "--json" ]; then
        cat << EOF
{
  "plugin": "autox_ssh",
  "name": "$NAME",
  "status": "$IS_RUNNING",
  "enabled": $([ "$IS_RUNNING" = "ENABLED" ] && echo "true" || echo "false"),
  "daemon": "openssh",
  "ports": [36000],
  "pid": "${PID_INFO:-none}",
  "version": "$VERSION"
}
EOF
    else
        echo "$IS_RUNNING"
    fi
}

# --------------------------------------------------------------------------
# 7. CORE WORKER LIFECYCLE ROUTINES
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Summary: Persistent Service Activation (Injects boot hooks, suppresses recovery, launches daemon)
# --------------------------------------------------------------------------
do_enable() {
    acquire_lock
    log_event "[START] $NAME v$VERSION Enabling SSH Remote Access"

    cmu_remount_rw
    mazda_watchdog_disable

    mkdir -p "$PLUGINS_DIR" "$ENABLED_DIR" "$LOG_DIR" "$DATA_DIR" 2>/dev/null
    chmod 755 "$PLUGIN_TARGET" 2>/dev/null

    if [ -f "$STAGE_1" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_1" 2>/dev/null
        log_event "[HOOK] Cleaned legacy SSH hooks from $STAGE_1"
    fi

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

    start_ssh_daemon
    _RC=$?

    sync
    mazda_watchdog_enable
    cmu_remount_ro
    release_lock

    if [ $_RC -eq 0 ]; then
        log_event "[COMPLETED] $NAME v$VERSION successfully enabled and active."
        echo "SSH Server Service: ENABLED (Port 36000 active)"
    else
        rm -f "$FLAG" 2>/dev/null
        log_event "[ERROR] $NAME v$VERSION failed to start daemon."
    fi
    return $_RC
}

# --------------------------------------------------------------------------
# Summary: Service Deactivation (Strips boot hooks, suppresses recovery, shuts down daemon)
# --------------------------------------------------------------------------
do_disable() {
    acquire_lock
    log_event "[START] $NAME v$VERSION Disabling SSH - Closing Port 36000"

    cmu_remount_rw
    mazda_watchdog_disable

    if [ -f "$STAGE_WIFI" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_WIFI" 2>/dev/null
        log_event "[HOOK] Removed AutoX SSH boot hook from $STAGE_WIFI"
    fi
    if [ -f "$STAGE_1" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_1" 2>/dev/null
        log_event "[HOOK] Cleaned legacy SSH hooks from $STAGE_1"
    fi

    stop_ssh_daemon

    sync
    mazda_watchdog_enable
    cmu_remount_ro
    release_lock

    log_event "[COMPLETED] $NAME v$VERSION disabled. Ports closed."
    echo "SSH Server Service: DISABLED (Port 36000 closed)"
    return 0
}

# --------------------------------------------------------------------------
# Summary: First-Run Deployment Routine (NAND Staging & Initial State Configuration)
# --------------------------------------------------------------------------
do_install() {
    acquire_lock
    log_event "[START] $NAME v$VERSION Installation Initiated"
    mkdir -p "$PLUGINS_DIR" "$ENABLED_DIR" "$LOG_DIR" "$DATA_DIR" 2>/dev/null
    release_lock

    case "$(echo "$INSTALL_STATE" | tr '[:upper:]' '[:lower:]')" in
        "enabled"|"enable"|"1"|"true")
            log_event "INSTALL_STATE is 'enabled'. Activating SSH daemon now..."
            do_enable
            ;;
        "disabled"|"disable"|"0"|"false"|*)
            log_event "INSTALL_STATE is 'disabled'. Plugin deployed in dormant state."
            rm -f "$FLAG" 2>/dev/null
            echo "SSH Server Service: DISABLED (Port 36000 closed)"
            ;;
    esac
}

# --------------------------------------------------------------------------
# Summary: In-Place Upgrade Handler (Version Matching & Safe State Preservation)
# --------------------------------------------------------------------------
do_reinstall() {
    FORCE=0
    [ "$1" = "--force" ] || [ "$2" = "--force" ] && FORCE=1

    CUR_VER="0"
    if [ -f "$PLUGIN_TARGET" ]; then
        CUR_VER=$("/bin/sh" "$PLUGIN_TARGET" version 2>/dev/null)
        [ -z "$CUR_VER" ] && CUR_VER="0"
    fi
    if [ "$CUR_VER" = "$VERSION" ] && [ $FORCE -eq 0 ]; then
        log_event "[SKIP] $ID already at v$VERSION. Skipping in-place rewrite."
        return 0
    fi

    WAS_ENABLED=0
    [ -f "$FLAG" ] && WAS_ENABLED=1
    [ -f "$PLUGIN_TARGET" ] && /bin/sh "$PLUGIN_TARGET" uninstall 2>/dev/null
    cp -f "$SCRIPT_PATH" "$PLUGIN_TARGET"
    chmod 755 "$PLUGIN_TARGET" 2>/dev/null

    if [ $WAS_ENABLED -eq 1 ]; then
        /bin/sh "$PLUGIN_TARGET" enable --staged
    fi
    log_event "[REINSTALL] Successfully updated $ID to v$VERSION."
}

# --------------------------------------------------------------------------
# Summary: Total Plugin Purge (Strips hooks, closes ports, deletes plugin files from flash)
# --------------------------------------------------------------------------
do_uninstall() {
    acquire_lock
    log_event "[START] $NAME v$VERSION Uninstallation Initiated"

    killall -9 sshd 2>/dev/null
    close_firewall_ports

    cmu_remount_rw
    mazda_watchdog_disable

    if [ -f "$STAGE_WIFI" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_WIFI" 2>/dev/null
        log_event "[HOOK] Removed boot hook from $STAGE_WIFI"
    fi
    if [ -f "$STAGE_1" ]; then
        sed -i '/# === AutoX SSH Server/,/# === AutoX SSH Server Boot Hook End/d' "$STAGE_1" 2>/dev/null
        log_event "[HOOK] Cleaned legacy SSH hooks from $STAGE_1"
    fi

    sync
    mazda_watchdog_enable
    cmu_remount_ro

    rm -f "$SSHD_CONFIG" "$FLAG" "$LOCK_FILE" "$PLUGIN_TARGET" 2>/dev/null
    release_lock
    log_event "[COMPLETED] $NAME v$VERSION uninstalled."
    echo "SUCCESS: Plugin hooks stripped."
    return 0
}

# --------------------------------------------------------------------------
# Summary: State Inversion Utility (Toggles between enabled and disabled)
# --------------------------------------------------------------------------
do_toggle() {
    if [ -f "$FLAG" ]; then
        do_disable
    else
        do_enable
    fi
}

# --------------------------------------------------------------------------
# 8. MASTER ROUTER FRAMEWORK DISPATCH ENTRY POINT
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Summary: Master CLI Action Router & Framework Dispatcher
# --------------------------------------------------------------------------
execute_plugin() {
    _ACTION="$1"
    case "$_ACTION" in
        "version"|"--version")
            echo "$VERSION"
            ;;
        "start"|"--start")
            log_event "Started do_start event"
            start_ssh_daemon
            ;;
        "stop"|"--stop")
            log_event "Started do_stop event"
            stop_ssh_daemon
            ;;
        "restart"|"--restart"|"reload")
            log_event "Started do_restart event"
            stop_ssh_daemon
            usleep 300000
            start_ssh_daemon
            ;;
        "diag"|"--diag"|"diagnose"|"doctor"|"report"|"test"|"--test")
            log_event "Started do_diag event"
            run_ssh_diag
            ;;
        "debug"|"--debug")
            log_event "Started do_debug event"
            open_firewall_ports
            ensure_host_keys || return 1
            killall -9 sshd 2>/dev/null
            if [ -x /usr/sbin/sshd ]; then
                /usr/sbin/sshd -D -e -p 36000 -h "$SSH_RSA_KEY"
            else
                log_event "[ERROR] /usr/sbin/sshd not found."
                return 1
            fi
            ;;
        "install"|"--install"|"-i")
            log_event "Started do_install event"
            do_install "$2"
            ;;
        "reinstall")
            log_event "Started do_reinstall event"
            do_reinstall "$2" "$3"
            ;;
        "enable"|"--enable")
            log_event "Started do_enable event"
            do_enable "$2"
            ;;
        "disable"|"--disable")
            log_event "Started do_disable event"
            do_disable "$2"
            ;;
        "uninstall"|"--uninstall"|"-u"|"off"|"--off")
            log_event "Started do_uninstall event"
            do_uninstall "$2"
            ;;
        "toggle"|"--toggle")
            log_event "Started do_toggle event"
            do_toggle
            ;;
        "status"|"--status"|"-s"|"raw"|"--raw")
            get_status
            ;;
        "meta"|"--meta"|"info"|"--info")
            _STAT=$(get_status)
            echo "{\"id\":\"$ID\",\"name\":\"$NAME\",\"title\":\"$TITLE\",\"subtitle\":\"$SUBTITLE\",\"author\":\"$AUTHOR\",\"category\":\"$CATEGORY\",\"order\":$ORDER,\"version\":\"$VERSION\",\"status\":\"$_STAT\",\"show_in_gui\":$SHOW_IN_GUI,\"install_state\":\"$INSTALL_STATE\"}"
            ;;
        "json"|"--json")
            get_status --json
            ;;
        "shutdown"|"--shutdown")
            log_event "Shutdown signal received - stopping SSH daemon"
            stop_ssh_daemon
            exit 0
            ;;
        "help"|"--help"|"-h"|*)
            log_event "Started do_help/usage event"
            echo "$NAME v$VERSION"
            echo "Usage: autox_${ID}.sh [install|reinstall|enable|disable|toggle|start|stop|restart|status|raw|meta|json|diag|debug|shutdown|uninstall|version|help]"
            ;;
    esac
}

execute_plugin "$@"
