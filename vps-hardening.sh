#!/usr/bin/env bash
# Apply baseline VPS hardening on Ubuntu/Debian (SSH drop-in, UFW, sysctl).
# Run with: sudo ./vps-harden.sh   or   sudo bash vps-harden.sh

set -euo pipefail

readonly SSH_DROPIN="/etc/ssh/sshd_config.d/99-vps-hardening.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-network-hardening.conf"

usage() {
  echo "Usage: sudo $0 [--force]"
  echo "  Ensures SSH hardening drop-in, host firewall (UFW + SSH), and network sysctl."
  echo "  Refuses to disable password SSH unless at least one key is in authorized_keys"
  echo "  for the sudo-invoking user (SUDO_USER) or root."
  echo "  --force  Skip the authorized_keys safety check (lockout risk)."
  exit "${1:-0}"
}

FORCE=0
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

have_ssh_keys() {
  local f
  for f in /root/.ssh/authorized_keys; do
    [[ -s "$f" ]] && return 0
  done
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    f="/home/${SUDO_USER}/.ssh/authorized_keys"
    [[ -s "$f" ]] && return 0
  fi
  return 1
}

if [[ "$FORCE" -eq 0 ]] && ! have_ssh_keys; then
  echo "Refusing: no non-empty /root/.ssh/authorized_keys or ~${SUDO_USER:-}/.ssh/authorized_keys." >&2
  echo "Set up SSH public-key auth first, or re-run with: sudo $0 --force" >&2
  exit 1
fi

backup_if_exists() {
  local f=$1
  if [[ -f "$f" ]]; then
    cp -a -- "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

echo "==> SSH drop-in: $SSH_DROPIN"
backup_if_exists "$SSH_DROPIN"
umask 022
cat >"$SSH_DROPIN" <<'EOF'
# Baseline VPS hardening (key-based interactive auth; smaller brute-force surface)
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
PermitRootLogin prohibit-password
MaxAuthTries 4
ClientAliveInterval 120
ClientAliveCountMax 3
X11Forwarding no
DebianBanner no
EOF
chmod 0644 "$SSH_DROPIN"

if ! sshd -t; then
  echo "sshd -t failed; fix errors above. Drop-in left at $SSH_DROPIN" >&2
  exit 1
fi
systemctl reload ssh
echo "    ssh reloaded OK"

echo "==> UFW (default deny in, allow OpenSSH)"
ufw default deny incoming
ufw default allow outgoing
if ! ufw status 2>/dev/null | grep -qE 'OpenSSH|22/tcp'; then
  ufw allow OpenSSH comment 'SSH'
fi
ufw --force enable
ufw status verbose

echo "==> Sysctl: $SYSCTL_FILE"
backup_if_exists "$SYSCTL_FILE"
cat >"$SYSCTL_FILE" <<'EOF'
# Network hardening for VPS
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
chmod 0644 "$SYSCTL_FILE"
sysctl --system >/dev/null
echo "    sysctl applied"

echo "==> Done. Verify: sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin'"
echo "    Add UFW rules for extra services (e.g. sudo ufw allow 80,443/tcp)."
