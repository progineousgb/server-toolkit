#!/usr/bin/env bash
# secure-vps.sh - Walk a fresh Debian/Ubuntu VPS through a basic hardening routine.
#
# Steps (each one asks before changing anything):
#   1. apt update && apt upgrade
#   2. create a sudo user (default: deploy)
#   3. turn off root SSH login and password auth (only after you confirm key login works)
#   4. UFW: deny incoming, allow outgoing, allow OpenSSH, 80/tcp, 443/tcp
#   5. install and enable fail2ban (sshd jail)
#   6. install unattended-upgrades
#   7. optional: set timezone, optional swap file
#   8. print listening sockets (ss -tulpn)
#
# Usage: sudo ./secure-vps.sh [--user NAME] [--timezone TZ] [--swap SIZE] [--yes] [--dry-run]
#   --user NAME     sudo user to create (default: deploy)
#   --timezone TZ   set timezone, e.g. UTC (default: leave as is)
#   --swap SIZE     create /swapfile of SIZE, e.g. 1G (default: no swap)
#   --dry-run       print the commands instead of running them
#   --yes           do not ask per step (still refuses SSH lockdown without an authorized key)
#
# Keep your provider's web console open while you run this.
# Article: https://blog.progineous.com/secure-linux-vps-15-minutes/
set -euo pipefail

USER_NAME=deploy; TZ_SET=""; SWAP=""; ASSUME_YES=0; DRY=0

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME=${2:?}; shift 2 ;;
    --timezone) TZ_SET=${2:?}; shift 2 ;;
    --swap) SWAP=${2:?}; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# apt and dpkg never stop to ask; changed config files keep the local version.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

run() { if (( DRY )); then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
confirm() {
  (( ASSUME_YES )) && return 0
  local a; read -r -p "$1 [y/N] " a </dev/tty || return 1
  [[ $a =~ ^[Yy]$ ]]
}

if (( ! DRY )) && [[ $EUID -ne 0 ]]; then echo "Run as root (sudo), or use --dry-run." >&2; exit 1; fi
command -v apt-get >/dev/null || { echo "This script expects Debian/Ubuntu (apt)." >&2; exit 1; }

if confirm "1/8 Update and upgrade packages?"; then
  run apt-get update && run apt-get "${APT_OPTS[@]}" upgrade
fi

if confirm "2/8 Create sudo user '$USER_NAME'?"; then
  if id "$USER_NAME" >/dev/null 2>&1; then echo "User $USER_NAME already exists, skipping."
  elif (( ASSUME_YES )); then run adduser --disabled-password --gecos "" "$USER_NAME"
  else run adduser "$USER_NAME"; fi
  run usermod -aG sudo "$USER_NAME"
  echo "From your own machine run: ssh-copy-id $USER_NAME@YOUR_SERVER_IP"
  echo "Then open a second session and confirm the key login works before step 3."
fi

KEYS="/home/$USER_NAME/.ssh/authorized_keys"
if [[ -s $KEYS ]] || (( DRY )); then
  if confirm "3/8 Disable root SSH login and password auth (key login for $USER_NAME tested)?"; then
    conf=/etc/ssh/sshd_config.d/99-hardening.conf
    if (( DRY )); then echo "[dry-run] write $conf"
    else
      printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\n' > "$conf"
      sshd -t
    fi
    run systemctl reload ssh || run systemctl reload sshd
  fi
else
  echo "3/8 Skipped: $KEYS is empty or missing. Add a key first so you don't lock yourself out."
fi

if confirm "4/8 Configure UFW (deny incoming; allow OpenSSH, 80/tcp, 443/tcp) and enable it?"; then
  command -v ufw >/dev/null || run apt-get "${APT_OPTS[@]}" install ufw
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow OpenSSH
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  run ufw --force enable
  run ufw status verbose
fi

if confirm "5/8 Install and enable fail2ban with the sshd jail?"; then
  run apt-get "${APT_OPTS[@]}" install fail2ban
  # Keep any jail config the admin already wrote.
  if [[ -e /etc/fail2ban/jail.local || -e /etc/fail2ban/jail.d/sshd.local ]]; then
    echo "Existing /etc/fail2ban/jail.local or jail.d/sshd.local found, leaving it unchanged."
  elif (( DRY )); then echo "[dry-run] write /etc/fail2ban/jail.d/sshd.local"
  else printf '[sshd]\nenabled = true\n' > /etc/fail2ban/jail.d/sshd.local; fi
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
  run fail2ban-client status sshd || true
fi

if confirm "6/8 Install unattended-upgrades?"; then
  run apt-get "${APT_OPTS[@]}" install unattended-upgrades
  run dpkg-reconfigure -f noninteractive -plow unattended-upgrades
  run systemctl status unattended-upgrades --no-pager || true
fi

if [[ -n $TZ_SET ]] && confirm "7/8 Set timezone to $TZ_SET?"; then run timedatectl set-timezone "$TZ_SET"; fi
if [[ -n $SWAP ]]; then
  if swapon --show 2>/dev/null | grep -q /swapfile || [[ -e /swapfile ]]; then echo "/swapfile already exists, skipping."
  elif confirm "7/8 Create a $SWAP swap file at /swapfile?"; then
    run fallocate -l "$SWAP" /swapfile
    run chmod 600 /swapfile
    run mkswap /swapfile
    run swapon /swapfile
    if (( DRY )); then echo "[dry-run] append /swapfile to /etc/fstab"
    elif ! grep -q '^/swapfile ' /etc/fstab; then echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi
  fi
fi

echo "8/8 Listening sockets (anything here you did not expect deserves a look):"
run ss -tulpn
