# vps-maintenance.sh

Monthly Ubuntu VPS maintenance in one script: updates, cleanup, security snapshot, service/tls checks, and a saved report.

Works on Ubuntu 20.04 / 22.04 / 24.04.

---

## Run

```bash
bash vps-maintenance.sh              # sudo password once if not root
sudo bash vps-maintenance.sh
```

Logs and reports go to `/var/log/vps-maintenance/` (`maintenance_<timestamp>.log`, `report_<timestamp>.txt`).

---

## What it runs (in order)

1. **Health snapshot** — load, memory, disk vs thresholds  
2. **Docker guard** — `apt-get update`; if Docker-related packages are upgradable, stops running containers gracefully before upgrades  
3. **Package updates** — non-interactive `apt-get upgrade`  
4. **Cleanup** — autoremove, autoclean/clean, old kernels (keep current + one backup), journal vacuum, old `/tmp` files  
5. **Security** — failed SSH logins (24h), empty passwords, listening TCP/UDP ports (+ listeners without a visible owning process), UFW status, unattended-upgrades presence  
6. **Services** — failed systemd units; reboot-required flag; stops Docker gracefully before reboot when reboot is needed  
7. **TLS** — certbot checks when present; Traefik-in-Docker ACME hints (`acme.json`, logs); optional fallback cert paths via `openssl`  
8. **Health snapshot (after)** — disk/memory  
9. **Report** — task summary table and exit status  

---

## Deploy on a server

```bash
sudo curl -fsSL https://raw.githubusercontent.com/magicka7/vps-maintenance/main/vps-maintenance.sh \
  -o /usr/local/sbin/vps-maintenance.sh \
  && sudo chmod +x /usr/local/sbin/vps-maintenance.sh
```

Pin a commit by replacing `main` with a commit hash in the URL.

Many hosts:

```bash
for VPS in user@vps1.example.com user@vps2.example.com; do
  ssh "$VPS" 'sudo curl -fsSL https://raw.githubusercontent.com/magicka7/vps-maintenance/main/vps-maintenance.sh -o /usr/local/sbin/vps-maintenance.sh && sudo chmod +x /usr/local/sbin/vps-maintenance.sh'
done
```

---

## Cron (monthly, root)

```bash
sudo crontab -e
```

```
0 3 1 * * /usr/local/sbin/vps-maintenance.sh --no-color >> /var/log/vps-maintenance/cron.log 2>&1
```

Use root’s crontab so sudo is not required.

---

## Tunables (top of script)

| Variable | Default | Role |
|----------|---------|------|
| `DISK_WARN_PERCENT` | 80 | Disk warn threshold |
| `MEM_WARN_PERCENT` | 90 | Memory warn threshold |
| `LOAD_WARN_MULTIPLIER` | 2 | Warn when load > cores × this |
| `SSH_FAIL_WARN` | 50 | Failed SSH attempts (24h) warn threshold |
| `CERT_WARN_DAYS` | 30 | Certificate expiry warn window |

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Finished (warnings allowed) |
| 1 | Finished with errors — check log |

---

## Requirements

- Ubuntu 20.04+  
- `bash`, `sudo`, `apt`, usual CLI tools (`df`, `free`, `ss` or `netstat`, `systemctl`, `journalctl`)  
- Optional: `docker`, `certbot`, `ufw`

---

## Notes

- Uses `apt-get upgrade`, not `dist-upgrade`, for predictable unattended updates.  
- Keeps one extra kernel when pruning old images.
