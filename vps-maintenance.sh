#!/usr/bin/env bash
# =============================================================================
#  vps-maintenance.sh -- Monthly Ubuntu VPS Maintenance Script
#
#  Usage:  bash vps-maintenance.sh
#          (will prompt for sudo password once if not run as root)
#
#  Or:     sudo bash vps-maintenance.sh
# =============================================================================

# Strict mode -- but we DON'T use 'set -e' here on purpose, because individual
# checks (grep returning no matches, optional binaries missing, etc.) should
# not abort the entire run. We handle errors per-step with the err()/warn()
# helpers and an explicit ERRORS counter.
set -uo pipefail

# -- Colors (auto-disabled if terminal doesn't support them) ------------------
# Pass --no-color as first argument to force plain output
if [[ "${1:-}" == "--no-color" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
else
    # Use $'...' so the escape character is stored literally, not as backslash-033
    RED=$'\033[0;31m'
    YELLOW=$'\033[1;33m'
    GREEN=$'\033[0;32m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
fi

# -- Config --------------------------------------------------------------------
LOG_DIR="/var/log/vps-maintenance"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="${LOG_DIR}/maintenance_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/report_${TIMESTAMP}.txt"
DISK_WARN_PERCENT=80        # warn if disk usage exceeds this
LOAD_WARN_MULTIPLIER=2      # warn if load avg > (cores x multiplier)
MEM_WARN_PERCENT=90         # warn if memory usage exceeds this
SSH_FAIL_WARN=50            # warn if failed SSH attempts > this in 24h

# -- Counters & results --------------------------------------------------------
WARNINGS=0
ERRORS=0
APT_UPDATE_OK=0    # set by docker/apt index step; read by package upgrades
declare -A RESULTS   # task name -> status string
RESULT_ORDER=()      # preserve insertion order for the report

# -- Sudo gate (request once, keep alive) --------------------------------------
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        echo "ERROR: This script needs root privileges, but 'sudo' is not installed."
        echo "       Either install sudo, or run this script as root: su -c 'bash $0'"
        exit 1
    fi

    echo -e "\033[1m[vps-maintenance]\033[0m This script needs sudo access."
    echo "Please enter your sudo password (will be cached for the rest of the run):"
    if ! sudo -v; then
        echo "ERROR: Failed to obtain sudo privileges. Exiting."
        exit 1
    fi

    # Keep sudo timestamp alive in the background so no further prompts appear
    ( while true; do sleep 50; sudo -n true </dev/null >/dev/null 2>&1; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null; wait $SUDO_KEEPALIVE_PID 2>/dev/null; stty sane 2>/dev/null; tput cnorm 2>/dev/null' EXIT INT TERM HUP
    SUDO="sudo"
else
    SUDO=""
fi

# -- Init log directory (needs root, so do this AFTER the sudo gate) ----------
$SUDO mkdir -p "$LOG_DIR"
$SUDO touch "$LOG_FILE" "$REPORT_FILE"
$SUDO chmod 644 "$LOG_FILE" "$REPORT_FILE"
# Make the log dir writable by the invoking user so we can append from this script
$SUDO chown -R "$(whoami)":"$(id -gn)" "$LOG_DIR" 2>/dev/null || true

# -- Helpers -------------------------------------------------------------------
log()  { echo -e "$*" | tee -a "$LOG_FILE"; }
info() { log "${CYAN}  >>${RESET}  $*"; }
ok()   { log "${GREEN}  OK${RESET}  $*"; }
warn() { log "${YELLOW}  !!${RESET}  $*"; WARNINGS=$((WARNINGS+1)); }
err()  { log "${RED}  XX${RESET}  $*"; ERRORS=$((ERRORS+1)); }

section() {
    log ""
    log "${BOLD}${CYAN}======================================================${RESET}"
    log "${BOLD}  $*${RESET}"
    log "${BOLD}${CYAN}======================================================${RESET}"
}

# Record a task result (preserves insertion order)
result() {
    local task="$1"; local status="$2"
    if [[ -z "${RESULTS[$task]+x}" ]]; then
        RESULT_ORDER+=("$task")
    fi
    RESULTS["$task"]="$status"
}

# Gracefully stop running Docker containers (reusable for upgrade/reboot paths).
# Args:
#   $1 = reason string (for logs)
#   $2 = result key name
stop_docker_gracefully() {
    local reason="${1:-maintenance}"
    local result_key="${2:-Docker Containers}"

    if ! command -v docker &>/dev/null; then
        info "Docker is not installed -- skipping container shutdown"
        result "$result_key" "-  Docker not installed"
        return 2
    fi

    if ! $SUDO docker info &>/dev/null; then
        info "Docker daemon is not running -- nothing to stop"
        result "$result_key" "OK  Docker daemon not running"
        return 0
    fi

    local running_containers
    running_containers=$($SUDO docker ps -q)
    if [[ -z "$running_containers" ]]; then
        ok "Docker is running, but no containers are currently active"
        result "$result_key" "OK  No running containers"
        return 0
    fi

    local container_count
    container_count=$(echo "$running_containers" | wc -l)
    info "Stopping $container_count running Docker container(s) gracefully before ${reason}..."
    if $SUDO docker stop $running_containers 2>&1 | tee -a "$LOG_FILE"; then
        ok "All running Docker containers stopped"
        result "$result_key" "OK  Stopped $container_count container(s)"
        return 0
    fi

    warn "Some Docker containers could not be stopped gracefully"
    result "$result_key" "!!  Failed to stop one or more containers"
    return 1
}

# Terminal/report helpers (used by task_final_report)
colorize_status() {
    local s="$1"
    if [[ "$s" == OK* ]] || [[ "$s" == "[OK]"* ]]; then
        printf '%s%s%s' "$GREEN" "$s" "$RESET"
    elif [[ "$s" == "!!"* ]] || [[ "$s" == "[WARN]"* ]]; then
        printf '%s%s%s' "$YELLOW" "$s" "$RESET"
    elif [[ "$s" == XX* ]] || [[ "$s" == "[ERROR]"* ]]; then
        printf '%s%s%s' "$RED" "$s" "$RESET"
    else
        printf '%s' "$s"
    fi
}

# print_report: $1="color" for terminal, $1="plain" for log/report files
print_report() {
    local mode="${1:-plain}"
    echo "+==============================================================+"
    echo "|                   VPS MAINTENANCE REPORT                     |"
    echo "+==============================================================+"
    printf "|  Host     : %-48s |\n" "$(hostname -f 2>/dev/null || hostname)"
    printf "|  Started  : %-48s |\n" "$TIMESTAMP"
    printf "|  Finished : %-48s |\n" "$FINISH_TIME"
    printf "|  Kernel   : %-48s |\n" "$(uname -r)"
    echo "+==============================================================+"
    echo "|  TASK RESULTS                                                |"
    echo "+==============================================================+"
    if [[ ${#RESULT_ORDER[@]} -gt 0 ]]; then
        for key in "${RESULT_ORDER[@]}"; do
            local val="${RESULTS[$key]:-?}"
            if [[ "$mode" == "color" ]]; then
                local padded
                padded=$(printf "%-35s" "$val")
                printf "|  %-22s : %s |\n" "$key" "$(colorize_status "$padded")"
            else
                printf "|  %-22s : %-35s |\n" "$key" "$val"
            fi
        done
    else
        echo "|  (no task results recorded)                                  |"
    fi
    echo "+==============================================================+"
    printf "|  Warnings : %-48s |\n" "$WARNINGS"
    printf "|  Errors   : %-48s |\n" "$ERRORS"
    echo "+==============================================================+"
    local status_text
    if (( ERRORS > 0 )); then
        status_text="[ERROR]  COMPLETED WITH ERRORS"
    elif (( WARNINGS > 0 )); then
        status_text="[WARN]   COMPLETED WITH WARNINGS"
    else
        status_text="[OK]     ALL CLEAR"
    fi
    if [[ "$mode" == "color" ]]; then
        local padded
        padded=$(printf "%-48s" "$status_text")
        printf "|  STATUS   : %s |\n" "$(colorize_status "$padded")"
    else
        printf "|  STATUS   : %-48s |\n" "$status_text"
    fi
    echo "+==============================================================+"
    printf "|  Log file : %-48s |\n" "$LOG_FILE"
    printf "|  Report   : %-48s |\n" "$REPORT_FILE"
    echo "+==============================================================+"
    echo "|  To review this run:                                         |"
    printf "|    cat %-54s |\n" "$LOG_FILE"
    echo "|  To review all past reports:                                 |"
    echo "|    ls -lt /var/log/vps-maintenance/                          |"
    echo "+==============================================================+"
}

# =============================================================================
#  Task functions -- comment out invocations at bottom of script to skip steps
# =============================================================================

task_header() {
# -- Header --------------------------------------------------------------------
log ""
log "${BOLD}+======================================================+${RESET}"
log "${BOLD}|   VPS Monthly Maintenance -- ${TIMESTAMP}    |${RESET}"
log "${BOLD}+======================================================+${RESET}"
log "  Host : $(hostname -f 2>/dev/null || hostname)"
log "  User : $(whoami)"
log "  Log  : ${LOG_FILE}"
}

task_system_health_snapshot_before() {
# =============================================================================
#  1. SYSTEM HEALTH SNAPSHOT (before)
# =============================================================================
section "1 . System Health Snapshot (before)"

UPTIME_STR=$(uptime -p 2>/dev/null || uptime)
info "Uptime : $UPTIME_STR"

CORES=$(nproc)
LOAD=$(cut -d' ' -f1 /proc/loadavg)
LOAD_THRESH=$((CORES * LOAD_WARN_MULTIPLIER))
info "Load   : $LOAD (cores: $CORES, threshold: $LOAD_THRESH)"
# awk for float comparison (more portable than bc)
if awk "BEGIN{exit !($LOAD > $LOAD_THRESH)}"; then
    warn "High load average detected: $LOAD"
    result "Load Average" "!!  HIGH ($LOAD / threshold ${LOAD_THRESH})"
else
    ok "Load average normal"
    result "Load Average" "OK  OK ($LOAD)"
fi

# Memory
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_USED=$(free -m  | awk '/^Mem:/{print $3}')
MEM_PCT=$(awk "BEGIN{printf \"%.0f\", ($MEM_USED/$MEM_TOTAL)*100}")
info "Memory : ${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PCT}%)"
if (( MEM_PCT >= MEM_WARN_PERCENT )); then
    warn "High memory usage: ${MEM_PCT}%"
    result "Memory Usage" "!!  HIGH (${MEM_PCT}%)"
else
    ok "Memory usage OK (${MEM_PCT}%)"
    result "Memory Usage" "OK  OK (${MEM_PCT}%)"
fi

# Disk
DISK_ISSUES=0
while IFS= read -r line; do
    PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
    MNT=$(echo "$line" | awk '{print $6}')
    info "Disk   : $line"
    if [[ "$PCT" =~ ^[0-9]+$ ]] && (( PCT >= DISK_WARN_PERCENT )); then
        warn "Disk usage high on $MNT: ${PCT}%"
        DISK_ISSUES=$((DISK_ISSUES+1))
    fi
done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2)
if (( DISK_ISSUES == 0 )); then
    ok "All disk partitions below ${DISK_WARN_PERCENT}%"
    result "Disk Usage" "OK  All partitions OK"
else
    result "Disk Usage" "!!  $DISK_ISSUES partition(s) above ${DISK_WARN_PERCENT}%"
fi
}

task_docker_shutdown() {
# -----------------------------------------------------------------------------
#  Stop all running Docker containers (optional; see run list at bottom).
#  Independent of apt / Docker package detection in task_docker_pre_update_shutdown.
# -----------------------------------------------------------------------------
section "Docker -- graceful container shutdown"

stop_docker_gracefully "maintenance" "Docker Shutdown"
}

task_docker_pre_update_shutdown() {
# =============================================================================
#  2. DOCKER PRE-UPDATE SHUTDOWN
# =============================================================================
section "2 . Docker Pre-Update Shutdown"

APT_UPDATE_OK=0
info "Updating apt package index..."
if $SUDO apt-get update 2>&1 | tee -a "$LOG_FILE"; then
    APT_UPDATE_OK=1
    ok "Package index updated"
    result "Package Index" "OK  Updated"
else
    err "apt-get update failed"
    result "Package Index" "XX  FAILED"
fi

info "Checking available upgrades..."
if (( APT_UPDATE_OK )); then
    UPGRADABLE_LIST=$($SUDO apt list --upgradable 2>/dev/null | tail -n +2 || true)
    UPGRADABLE_RAW=$(echo "$UPGRADABLE_LIST" | sed '/^\s*$/d' | wc -l)
    info "$UPGRADABLE_RAW package(s) available to upgrade"

    DOCKER_UPDATES=$(echo "$UPGRADABLE_LIST" | awk -F/ '{print $1}' | grep -Eic '^(docker|containerd|runc|moby)' || true)
    if (( DOCKER_UPDATES > 0 )); then
        warn "Detected $DOCKER_UPDATES Docker-related package update(s); stopping containers before upgrade"
        stop_docker_gracefully "Docker package upgrades" "Docker Pre-Update Stop"
    else
        info "No Docker-related package updates detected -- no pre-upgrade container stop needed"
        result "Docker Pre-Update Stop" "OK  Not required (no Docker package updates)"
    fi
else
    warn "Skipping upgradable-package scan and Docker pre-stop (apt update failed)"
    UPGRADABLE_LIST=""
    UPGRADABLE_RAW=0
    info "Package upgrade list not refreshed -- treating as 0 upgradable packages"
    result "Docker Pre-Update Stop" "-  Skipped (apt update failed)"
fi
}

task_package_updates() {
# =============================================================================
#  3. PACKAGE UPDATES
# =============================================================================
section "3 . Package Updates"

if (( APT_UPDATE_OK )); then
    info "Proceeding with package upgrades..."

    info "Upgrading packages..."
    UPGRADE_OUT=$(DEBIAN_FRONTEND=noninteractive \
    $SUDO apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>&1 | tee -a "$LOG_FILE")

    # Parse the apt summary line: "X upgraded, Y newly installed, Z to remove..."
    UPGRADED=$(echo "$UPGRADE_OUT" | grep -oP '\d+(?= upgraded)' | tail -1)
    NEWLY=$(echo "$UPGRADE_OUT"    | grep -oP '\d+(?= newly installed)' | tail -1)
    UPGRADED=${UPGRADED:-0}
    NEWLY=${NEWLY:-0}

    ok "Package upgrade complete -- ${UPGRADED} upgraded, ${NEWLY} newly installed"
    result "Package Upgrades" "OK  ${UPGRADED} upgraded, ${NEWLY} newly installed"
else
    warn "Skipping apt-get upgrade because apt-get update failed"
    result "Package Upgrades" "XX  SKIPPED (apt update failed)"
fi
}

task_cleanup() {
# =============================================================================
#  4. CLEANUP
# =============================================================================
section "4 . Cleanup"

info "Running autoremove..."
AUTOREMOVE_OUT=$(DEBIAN_FRONTEND=noninteractive $SUDO apt-get autoremove -y 2>&1)
echo "$AUTOREMOVE_OUT" | tee -a "$LOG_FILE"
# autoremove summary line: "X upgraded, Y newly installed, Z to remove..."
REMOVED_COUNT=$(echo "$AUTOREMOVE_OUT" | grep -oP '\d+(?= to remove)' | tail -1)
REMOVED_COUNT=${REMOVED_COUNT:-0}
ok "autoremove complete -- ${REMOVED_COUNT} package(s) removed"
result "Autoremove" "OK  ${REMOVED_COUNT} package(s) removed"

info "Running autoclean..."
$SUDO apt-get autoclean -y 2>&1 | tee -a "$LOG_FILE"
ok "autoclean complete"
result "Autoclean" "OK  Done"

info "Cleaning apt cache..."
$SUDO apt-get clean 2>&1 | tee -a "$LOG_FILE"
ok "apt cache cleaned"
result "Apt Cache Clean" "OK  Done"

# Old kernels (keep current + 1 previous as safety net)
info "Checking for old kernel images..."
CURRENT_KERNEL=$(uname -r)
info "Current kernel: $CURRENT_KERNEL"
ALL_KERNELS=$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}')
if [[ -n "$ALL_KERNELS" ]]; then
    info "Installed kernel images:"
    echo "$ALL_KERNELS" | tee -a "$LOG_FILE"
    OLD_KERNELS=$(echo "$ALL_KERNELS" | grep -v "$CURRENT_KERNEL" | head -n -1 || true)
    if [[ -n "$OLD_KERNELS" ]]; then
        KERNEL_COUNT=$(echo "$OLD_KERNELS" | wc -l)
        info "Removing $KERNEL_COUNT old kernel(s)..."
        echo "$OLD_KERNELS" | xargs $SUDO apt-get purge -y 2>&1 | tee -a "$LOG_FILE"
        ok "Old kernels removed"
        result "Old Kernels" "OK  $KERNEL_COUNT removed"
    else
        ok "No old kernels to remove (keeping current + 1 backup)"
        result "Old Kernels" "OK  None to remove"
    fi
else
    info "No matching kernel packages detected"
    result "Old Kernels" "OK  None detected"
fi

# Journal logs older than 30 days
info "Vacuuming systemd journal (older than 30 days)..."
JOURNAL_OUT=$($SUDO journalctl --vacuum-time=30d 2>&1)
echo "$JOURNAL_OUT" | tee -a "$LOG_FILE"
JOURNAL_FREED=$(echo "$JOURNAL_OUT" | grep -oE 'freed [0-9.]+[A-Z]+' | tail -1 || true)
ok "Journal vacuumed${JOURNAL_FREED:+ -- $JOURNAL_FREED}"
result "Journal Cleanup" "OK  Vacuumed${JOURNAL_FREED:+ ($JOURNAL_FREED)}"

# Temp files
info "Cleaning /tmp files older than 7 days..."
TMP_COUNT=$($SUDO find /tmp -type f -atime +7 2>/dev/null | wc -l)
$SUDO find /tmp -type f -atime +7 -delete 2>/dev/null || true
ok "/tmp cleaned -- $TMP_COUNT file(s) removed"
result "Temp Files" "OK  $TMP_COUNT file(s) removed"

}

task_security_checks() {
# =============================================================================
#  5. SECURITY CHECKS
# =============================================================================
section "5 . Security Checks"

# Failed SSH logins in last 24h
info "Checking failed SSH login attempts (last 24h)..."
if $SUDO test -r /var/log/auth.log; then
    # grep exits 1 when there are no matches; keep pipefail from failing the assignment
    FAILED_SSH=$($SUDO grep "Failed password" /var/log/auth.log 2>/dev/null \
        | awk -v d="$(date --date='24 hours ago' '+%b %e')" \
        '$0 >= d' | wc -l | tr -d '[:space:]') || true
elif command -v journalctl &>/dev/null; then
    # Newer systems may not have auth.log; use journalctl
    # grep -c prints 0 and exits 1 when there are no matches -- do not append a second "0"
    FAILED_SSH=$($SUDO journalctl _COMM=sshd --since "24 hours ago" 2>/dev/null \
        | grep -c "Failed password" || true)
else
    FAILED_SSH="N/A"
fi

if [[ "$FAILED_SSH" != "N/A" ]]; then
    FAILED_SSH=${FAILED_SSH:-0}
fi

if [[ "$FAILED_SSH" == "N/A" ]]; then
    info "Could not access SSH logs"
    result "Failed SSH Logins" "-  Not available"
elif (( FAILED_SSH > SSH_FAIL_WARN )); then
    warn "High number of failed SSH logins in 24h: $FAILED_SSH"
    result "Failed SSH Logins" "!!  $FAILED_SSH attempts (last 24h)"
else
    ok "Failed SSH logins in 24h: $FAILED_SSH"
    result "Failed SSH Logins" "OK  $FAILED_SSH attempts (last 24h)"
fi

# Users with empty passwords (NOT locked accounts -- that's normal)
info "Checking for accounts with empty passwords..."
EMPTY_PASS=$( $SUDO awk -F: '($2 == "") {print $1}' /etc/shadow \
    2>/dev/null | tr '\n' ',' | sed 's/,$//' )
if [[ -n "$EMPTY_PASS" ]]; then
    warn "Accounts with empty passwords: $EMPTY_PASS"
    result "Empty Passwords" "!!  $EMPTY_PASS"
else
    ok "No accounts with empty passwords"
    result "Empty Passwords" "OK  None found"
fi

# Listening ports
info "Listening TCP/UDP ports:"
if command -v ss &>/dev/null; then
    PORTS_OUT=$($SUDO ss -tlnpu 2>/dev/null)
    PORTS_UNOWNED=$($SUDO ss -H -tlnpu 2>/dev/null | awk 'index($0,"users:(")==0' | wc -l)
elif command -v netstat &>/dev/null; then
    PORTS_OUT=$($SUDO netstat -tlnpu 2>/dev/null)
    PORTS_UNOWNED=$($SUDO netstat -tlnpu 2>/dev/null | awk 'NR>2 && ($NF=="-" || $NF=="-/-")' | wc -l)
else
    PORTS_OUT="(neither ss nor netstat available)"
    PORTS_UNOWNED=-1
fi
echo "$PORTS_OUT" | tee -a "$LOG_FILE"
if (( PORTS_UNOWNED == -1 )); then
    result "Listening Ports" "-  ss/netstat unavailable"
elif (( PORTS_UNOWNED > 0 )); then
    warn "Found $PORTS_UNOWNED listening port(s) without visible owning process"
    info "Note: some listeners (e.g. kernel/root-only) may omit process info in ss/netstat — verify if unexpected"
    result "Listening Ports" "!!  $PORTS_UNOWNED with no visible process"
else
    ok "All listening ports have an owning process"
    result "Listening Ports" "OK  All listeners mapped to a process"
fi

# UFW firewall
if command -v ufw &>/dev/null; then
    info "Firewall (ufw) status:"
    UFW_OUT=$($SUDO ufw status verbose 2>/dev/null)
    echo "$UFW_OUT" | tee -a "$LOG_FILE"
    UFW_STATUS=$(echo "$UFW_OUT" | head -1)
    if echo "$UFW_OUT" | head -1 | grep -qi "active"; then
        ok "UFW is active"
        result "Firewall (UFW)" "OK  $UFW_STATUS"
    else
        warn "UFW is installed but not active"
        result "Firewall (UFW)" "!!  $UFW_STATUS"
    fi
else
    warn "ufw not installed -- no host firewall detected"
    result "Firewall (UFW)" "!!  Not installed"
fi

# Unattended security upgrades
if command -v unattended-upgrades &>/dev/null; then
    ok "unattended-upgrades is installed"
    result "Unattended Upgrades" "OK  Installed"
else
    warn "unattended-upgrades not installed -- consider: apt install unattended-upgrades"
    result "Unattended Upgrades" "!!  Not installed"
fi

}

task_services_check() {
# =============================================================================
#  6. SERVICES CHECK
# =============================================================================
section "6 . Services Check"

info "Checking for failed systemd services..."
FAILED_SERVICES=$($SUDO systemctl list-units --state=failed --no-legend 2>/dev/null || true)
if [[ -z "$FAILED_SERVICES" ]]; then
    ok "No failed services"
    result "Failed Services" "OK  None"
else
    echo "$FAILED_SERVICES" | tee -a "$LOG_FILE"
    FAILED_NAMES=$(echo "$FAILED_SERVICES" | awk '{print $1}' | tr '\n' ' ')
    warn "Failed services detected: $FAILED_NAMES"
    result "Failed Services" "!!  $FAILED_NAMES"
fi

# Reboot required?
if [[ -f /var/run/reboot-required ]]; then
    warn "A system REBOOT is required (kernel or core lib was updated)"
    stop_docker_gracefully "system reboot" "Docker Pre-Reboot Stop"
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        REBOOT_PKGS=$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
        warn "Packages triggering reboot: $REBOOT_PKGS"
    fi
    result "Reboot Required" "!!  YES -- reboot recommended"
else
    ok "No reboot required"
    result "Reboot Required" "OK  No"
fi

}

task_ssl_certificate_check() {
# =============================================================================
#  7. SSL CERTIFICATE CHECK
# =============================================================================
section "7 . SSL Certificate Check"

CERT_WARN_DAYS=30   # warn if cert expires within this many days
CERT_ISSUES=0
CERT_COUNT=0

# Check via certbot if available
if command -v certbot &>/dev/null; then
    info "Certbot found -- checking certificate status..."

    # Check certbot timer (preferred way to run certbot on Ubuntu)
    if systemctl list-units --type=timer 2>/dev/null | grep -q "certbot.timer"; then
        TIMER_STATUS=$(systemctl is-active certbot.timer 2>/dev/null || echo "unknown")
        if [[ "$TIMER_STATUS" == "active" ]]; then
            ok "certbot.timer is active (auto-renewal is enabled)"
        else
            warn "certbot.timer is not active -- auto-renewal may be disabled"
            CERT_ISSUES=$((CERT_ISSUES+1))
        fi
    fi

    # Run certbot renew dry-run to check if renewal would work
    info "Running certbot renew dry-run..."
    CERTBOT_DRY=$($SUDO certbot renew --dry-run 2>&1)
    echo "$CERTBOT_DRY" | tee -a "$LOG_FILE"
    if echo "$CERTBOT_DRY" | grep -qi "congratulations\|no renewals\|success"; then
        ok "Certbot dry-run passed -- renewals are working"
        result "Certbot Renewal" "OK  Dry-run passed"
    elif echo "$CERTBOT_DRY" | grep -qi "failed\|error"; then
        warn "Certbot dry-run reported errors -- check output above"
        result "Certbot Renewal" "!!  Dry-run errors detected"
        CERT_ISSUES=$((CERT_ISSUES+1))
    else
        ok "Certbot dry-run completed"
        result "Certbot Renewal" "OK  Completed"
    fi

    # List all certs and check expiry dates
    info "Checking certificate expiry dates..."
    CERTBOT_CERTS=$($SUDO certbot certificates 2>/dev/null)
    if [[ -n "$CERTBOT_CERTS" ]]; then
        # Parse each domain and expiry
        while IFS= read -r line; do
            if echo "$line" | grep -q "Domains:"; then
                CURRENT_DOMAIN=$(echo "$line" | awk '{print $2}')
            fi
            if echo "$line" | grep -q "Expiry Date:"; then
                EXPIRY_STR=$(echo "$line" | grep -oP '\d{4}-\d{2}-\d{2}')
                if [[ -n "$EXPIRY_STR" ]]; then
                    EXPIRY_EPOCH=$(date -d "$EXPIRY_STR" +%s 2>/dev/null || echo "0")
                    NOW_EPOCH=$(date +%s)
                    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                    CERT_COUNT=$((CERT_COUNT+1))
                    if (( DAYS_LEFT <= 0 )); then
                        err "EXPIRED certificate for ${CURRENT_DOMAIN:-unknown}: expired $EXPIRY_STR"
                        result "Cert: ${CURRENT_DOMAIN:-unknown}" "XX  EXPIRED ($EXPIRY_STR)"
                        CERT_ISSUES=$((CERT_ISSUES+1))
                    elif (( DAYS_LEFT <= CERT_WARN_DAYS )); then
                        warn "Certificate for ${CURRENT_DOMAIN:-unknown} expires in $DAYS_LEFT days ($EXPIRY_STR)"
                        result "Cert: ${CURRENT_DOMAIN:-unknown}" "!!  Expires in $DAYS_LEFT days"
                        CERT_ISSUES=$((CERT_ISSUES+1))
                    else
                        ok "Certificate for ${CURRENT_DOMAIN:-unknown}: $DAYS_LEFT days remaining ($EXPIRY_STR)"
                        result "Cert: ${CURRENT_DOMAIN:-unknown}" "OK  $DAYS_LEFT days remaining"
                    fi
                fi
            fi
        done <<< "$CERTBOT_CERTS"
    else
        info "No certbot-managed certificates found"
        result "Certbot Certs" "OK  None found"
    fi
else
    info "Certbot not installed -- skipping certificate check"
    result "SSL Certificates" "OK  Certbot not installed"
fi

# Traefik ACME verification (for setups using Traefik instead of certbot)
TRAEFIK_CONTAINER=""
TRAEFIK_ACTIVE=0

if command -v docker &>/dev/null && $SUDO docker info &>/dev/null; then
    TRAEFIK_CONTAINER=$($SUDO docker ps --format '{{.Names}}' | grep -Ei '(^|[-_])traefik($|[-_])|traefik' | head -n1 || true)
    if [[ -n "$TRAEFIK_CONTAINER" ]]; then
        TRAEFIK_ACTIVE=1
        ok "Traefik Docker container is running: $TRAEFIK_CONTAINER"
        result "Traefik Container" "OK  Running ($TRAEFIK_CONTAINER)"
    fi
fi

# Only evaluate systemd if Traefik was not found in Docker.
if [[ -z "$TRAEFIK_CONTAINER" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^traefik\.service'; then
    if systemctl is-active --quiet traefik; then
        TRAEFIK_ACTIVE=1
        ok "Traefik systemd service is active"
        result "Traefik Service" "OK  Active"
    else
        warn "Traefik service is installed but not active"
        result "Traefik Service" "!!  Installed but not active"
        CERT_ISSUES=$((CERT_ISSUES+1))
    fi
fi

if (( TRAEFIK_ACTIVE == 1 )); then
    TRAEFIK_ACME_FILE=""
    for CANDIDATE in /etc/traefik/acme.json /var/lib/traefik/acme.json /opt/traefik/acme.json /srv/traefik/acme.json; do
        if $SUDO test -f "$CANDIDATE"; then
            TRAEFIK_ACME_FILE="$CANDIDATE"
            break
        fi
    done

    # If Traefik is in Docker, try to discover the host-side acme.json mount path.
    if [[ -z "$TRAEFIK_ACME_FILE" && -n "$TRAEFIK_CONTAINER" ]]; then
        TRAEFIK_ACME_FILE=$($SUDO docker inspect "$TRAEFIK_CONTAINER" \
            --format '{{range .Mounts}}{{println .Source " " .Destination}}{{end}}' \
            | awk '$1 ~ /acme\.json$/ || $2 ~ /acme\.json$/ {print $1; exit}')
    fi

    if [[ -n "$TRAEFIK_ACME_FILE" ]] && $SUDO test -r "$TRAEFIK_ACME_FILE"; then
        ACME_MTIME=$($SUDO stat -c %Y "$TRAEFIK_ACME_FILE" 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        ACME_AGE_DAYS=$(( (NOW_EPOCH - ACME_MTIME) / 86400 ))

        info "Traefik ACME storage file: $TRAEFIK_ACME_FILE"
        if (( ACME_AGE_DAYS > 60 )); then
            warn "Traefik acme.json has not changed for $ACME_AGE_DAYS days (expected renewals around every 60-90 days)"
            result "Traefik ACME" "!!  acme.json stale (${ACME_AGE_DAYS}d)"
            CERT_ISSUES=$((CERT_ISSUES+1))
        else
            ok "Traefik acme.json updated $ACME_AGE_DAYS day(s) ago"
            result "Traefik ACME" "OK  acme.json recent (${ACME_AGE_DAYS}d)"
        fi
    elif (( TRAEFIK_ACTIVE == 1 )); then
        warn "Traefik appears active, but acme.json was not found/readable"
        result "Traefik ACME" "!!  acme.json not found"
        CERT_ISSUES=$((CERT_ISSUES+1))
    fi

    # Optional signal: recent renewal messages in logs.
    RENEW_LOG_HITS=0
    if [[ -n "$TRAEFIK_CONTAINER" ]]; then
        RENEW_LOG_HITS=$($SUDO docker logs --since 2160h "$TRAEFIK_CONTAINER" 2>&1 \
            | grep -Eic 'renew|acme|obtained certificate|lego' || true)
    elif systemctl is-active --quiet traefik 2>/dev/null; then
        RENEW_LOG_HITS=$(journalctl -u traefik --since "90 days ago" 2>/dev/null \
            | grep -Eic 'renew|acme|obtained certificate|lego' || true)
    fi

    if (( RENEW_LOG_HITS > 0 )); then
        ok "Traefik logs contain ACME/renewal events in the last 90 days"
        result "Traefik ACME Logs" "OK  Renewal signals present"
    else
        info "No clear Traefik ACME renewal messages found in last 90 days"
        result "Traefik ACME Logs" "-  No renewal messages found"
    fi
fi

# Also check any certs in /etc/ssl/certs or /etc/nginx/ssl if certbot not used
if [[ $CERT_COUNT -eq 0 ]] && command -v openssl &>/dev/null; then
    for CERT_PATH in /etc/nginx/ssl/*.crt /etc/nginx/ssl/*.pem                      /etc/apache2/ssl/*.crt /etc/ssl/private/*.crt; do
        [[ -f "$CERT_PATH" ]] || continue
        EXPIRY_STR=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null             | cut -d= -f2)
        if [[ -n "$EXPIRY_STR" ]]; then
            EXPIRY_EPOCH=$(date -d "$EXPIRY_STR" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
            CERT_COUNT=$((CERT_COUNT+1))
            CERT_NAME=$(basename "$CERT_PATH")
            if (( DAYS_LEFT <= 0 )); then
                err "EXPIRED certificate: $CERT_NAME"
                result "Cert: $CERT_NAME" "XX  EXPIRED"
                CERT_ISSUES=$((CERT_ISSUES+1))
            elif (( DAYS_LEFT <= CERT_WARN_DAYS )); then
                warn "Certificate $CERT_NAME expires in $DAYS_LEFT days"
                result "Cert: $CERT_NAME" "!!  Expires in $DAYS_LEFT days"
                CERT_ISSUES=$((CERT_ISSUES+1))
            else
                ok "Certificate $CERT_NAME: $DAYS_LEFT days remaining"
                result "Cert: $CERT_NAME" "OK  $DAYS_LEFT days remaining"
            fi
        fi
    done
fi

if (( CERT_COUNT == 0 )); then
    info "No certificates found to check"
elif (( CERT_ISSUES == 0 )); then
    ok "All $CERT_COUNT certificate(s) are healthy"
fi

}

task_system_health_snapshot_after() {
# =============================================================================
#  8. HEALTH SNAPSHOT (after)
# =============================================================================
section "8 . System Health Snapshot (after)"

info "Disk usage after cleanup:"
while IFS= read -r line; do
    info "$line"
done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2)

MEM_AFTER_USED=$(free -m | awk '/^Mem:/{print $3}')
MEM_AFTER_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_AFTER_PCT=$(awk "BEGIN{printf \"%.0f\", ($MEM_AFTER_USED/$MEM_AFTER_TOTAL)*100}")
info "Memory after: ${MEM_AFTER_USED}MB / ${MEM_AFTER_TOTAL}MB (${MEM_AFTER_PCT}%)"

DISK_AFTER=$(df -h / | tail -1 | awk '{print $3 " used / " $2 " ("$5")"}')
ok "Health snapshot complete"
result "Disk (after)" "$DISK_AFTER"
result "Memory (after)" "${MEM_AFTER_USED}MB / ${MEM_AFTER_TOTAL}MB (${MEM_AFTER_PCT}%)"

}

task_final_report() {
# =============================================================================
#  9. FINAL REPORT
# =============================================================================
section "9 . Maintenance Report"

FINISH_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# Build and print the report directly (no subshell, so we can't silently fail).
# Terminal gets color, files get plain text (so log files don't have ANSI junk).
print_report color
print_report plain >> "$LOG_FILE"
print_report plain | $SUDO tee "$REPORT_FILE" > /dev/null

}

# -- Run maintenance tasks (comment out any line below to skip that step) -----
task_header
task_system_health_snapshot_before
# task_docker_shutdown   # uncomment to stop all running containers before apt/upgrades
task_docker_pre_update_shutdown
task_package_updates
task_cleanup
task_security_checks
task_services_check
task_ssl_certificate_check
task_system_health_snapshot_after
task_final_report

log ""
# Restore terminal to a sane state regardless of what happened during the run
stty sane 2>/dev/null || true
tput cnorm 2>/dev/null || true  # restore cursor if it was hidden

if (( ERRORS > 0 )); then
    log "${RED}${BOLD}Maintenance finished with $ERRORS error(s). Review the log above.${RESET}"
    exit 1
elif (( WARNINGS > 0 )); then
    log "${YELLOW}${BOLD}Maintenance finished with $WARNINGS warning(s). Review items above.${RESET}"
    exit 0
else
    log "${GREEN}${BOLD}Maintenance complete -- everything looks healthy!${RESET}"
    exit 0
fi
