#!/usr/bin/env bash
# =============================================================================
#  post-reboot-check.sh -- Post-reboot app/container verification
#
#  Purpose:
#    - Run after reboot
#    - Start the main application
#    - Verify Docker containers are healthy/running
#    - Scan container logs for common error patterns
#
#  Usage:
#    MAIN_APP_START_CMD="docker compose up -d" \
#    MAIN_APP_WORKDIR="/opt/myapp" \
#    bash post-reboot-check.sh
# =============================================================================

set -uo pipefail

# -- Colors --------------------------------------------------------------------
if [[ "${1:-}" == "--no-color" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
else
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
LOG_FILE="${LOG_DIR}/post_reboot_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/post_reboot_report_${TIMESTAMP}.txt"

# Set these via env vars, or edit defaults here.
MAIN_APP_START_CMD="${MAIN_APP_START_CMD:-docker compose up -d}"
MAIN_APP_WORKDIR="${MAIN_APP_WORKDIR:-/opt}"
DOCKER_WAIT_TIMEOUT_SEC="${DOCKER_WAIT_TIMEOUT_SEC:-180}"
POST_START_WAIT_SEC="${POST_START_WAIT_SEC:-20}"
LOG_SCAN_WINDOW_MIN="${LOG_SCAN_WINDOW_MIN:-30}"
ERROR_REGEX="${ERROR_REGEX:-error|exception|fatal|panic|segfault|traceback|out of memory|oom|crash|failed to|connection refused}"

WARNINGS=0
ERRORS=0

# -- Sudo gate -----------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        echo "ERROR: This script needs root privileges and 'sudo' is missing."
        exit 1
    fi
    if ! sudo -v; then
        echo "ERROR: Failed to obtain sudo privileges."
        exit 1
    fi
    SUDO="sudo"
else
    SUDO=""
fi

# -- Init logs -----------------------------------------------------------------
$SUDO mkdir -p "$LOG_DIR"
$SUDO touch "$LOG_FILE" "$REPORT_FILE"
$SUDO chmod 644 "$LOG_FILE" "$REPORT_FILE"
$SUDO chown -R "$(whoami)":"$(id -gn)" "$LOG_DIR" 2>/dev/null || true

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

wait_for_docker() {
    if ! command -v docker &>/dev/null; then
        err "Docker CLI not found."
        return 1
    fi

    info "Waiting for Docker daemon (timeout: ${DOCKER_WAIT_TIMEOUT_SEC}s)..."
    local start_ts now elapsed
    start_ts=$(date +%s)
    while true; do
        if $SUDO docker info &>/dev/null; then
            ok "Docker daemon is ready."
            return 0
        fi
        now=$(date +%s)
        elapsed=$((now - start_ts))
        if (( elapsed >= DOCKER_WAIT_TIMEOUT_SEC )); then
            err "Docker daemon did not become ready in time."
            return 1
        fi
        sleep 3
    done
}

start_main_app() {
    section "Start Main Application"
    info "Command : $MAIN_APP_START_CMD"
    info "Workdir : $MAIN_APP_WORKDIR"

    if [[ ! -d "$MAIN_APP_WORKDIR" ]]; then
        err "Main app workdir does not exist: $MAIN_APP_WORKDIR"
        return 1
    fi

    if [[ -z "$MAIN_APP_START_CMD" ]]; then
        err "MAIN_APP_START_CMD is empty."
        return 1
    fi

    if ( cd "$MAIN_APP_WORKDIR" && eval "$MAIN_APP_START_CMD" ) 2>&1 | tee -a "$LOG_FILE"; then
        ok "Main application start command completed."
        return 0
    fi

    err "Main application start command failed."
    return 1
}

check_containers() {
    section "Container Status Check"
    local running_count total_count
    running_count=$($SUDO docker ps -q | wc -l)
    total_count=$($SUDO docker ps -aq | wc -l)
    info "Containers: $running_count running / $total_count total"

    if (( total_count == 0 )); then
        warn "No Docker containers found."
        return 0
    fi

    local non_running
    non_running=$($SUDO docker ps -a --filter status=exited --filter status=dead --filter status=created --format '{{.Names}} ({{.Status}})')
    if [[ -n "$non_running" ]]; then
        warn "Non-running container(s) detected:"
        echo "$non_running" | tee -a "$LOG_FILE"
    else
        ok "All discovered containers are running."
    fi
}

scan_logs_for_errors() {
    section "Container Log Scan"
    info "Window: last ${LOG_SCAN_WINDOW_MIN} minute(s)"
    info "Regex : $ERROR_REGEX"

    local containers
    containers=$($SUDO docker ps --format '{{.Names}}')
    if [[ -z "$containers" ]]; then
        warn "No running containers to scan."
        return 0
    fi

    local container hit_count total_hits
    total_hits=0
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        hit_count=$($SUDO docker logs --since "${LOG_SCAN_WINDOW_MIN}m" "$container" 2>&1 \
            | grep -Eic "$ERROR_REGEX" || true)
        if [[ -z "$hit_count" ]]; then
            hit_count=0
        fi
        if (( hit_count > 0 )); then
            warn "[$container] matched $hit_count potential error line(s)."
            total_hits=$((total_hits + hit_count))
        else
            ok "[$container] no common error patterns detected."
        fi
    done <<< "$containers"

    if (( total_hits > 0 )); then
        warn "Total potential error log matches: $total_hits"
    else
        ok "No common error patterns found in running container logs."
    fi
}

# -- Run -----------------------------------------------------------------------
section "Post-Reboot Validation"
info "Host : $(hostname -f 2>/dev/null || hostname)"
info "Time : $(date '+%Y-%m-%d %H:%M:%S')"
info "Log  : $LOG_FILE"

wait_for_docker || true
start_main_app || true

if (( POST_START_WAIT_SEC > 0 )); then
    info "Waiting ${POST_START_WAIT_SEC}s for services to settle..."
    sleep "$POST_START_WAIT_SEC"
fi

if command -v docker &>/dev/null && $SUDO docker info &>/dev/null; then
    check_containers
    scan_logs_for_errors
else
    err "Skipping container checks because Docker is unavailable."
fi

section "Post-Reboot Summary"
printf "Warnings: %s\nErrors: %s\n" "$WARNINGS" "$ERRORS" | tee -a "$LOG_FILE" | $SUDO tee "$REPORT_FILE" > /dev/null
info "Report saved: $REPORT_FILE"

if (( ERRORS > 0 )); then
    err "Post-reboot check completed with errors."
    exit 1
elif (( WARNINGS > 0 )); then
    warn "Post-reboot check completed with warnings."
    exit 0
else
    ok "Post-reboot check completed successfully."
    exit 0
fi
