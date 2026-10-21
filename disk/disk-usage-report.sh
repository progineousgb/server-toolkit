#!/usr/bin/env bash
# disk-usage-report.sh - Read-only report of what is filling a Linux server's disk.
#
# Shows df -h and df -i, the biggest directories and files on one filesystem
# (it stays on that filesystem, like du -x), journald usage, the apt cache and
# old kernels, Docker usage if Docker is installed, and deleted files that a
# process still holds open. Deletes nothing. Cleanup commands are only printed
# so you can review them first.
#
# Usage: sudo ./disk-usage-report.sh [-n COUNT] [MOUNTPOINT]
#   MOUNTPOINT  filesystem to inspect (default /)
#   -n COUNT    rows to show in the directory and file lists (default 10)
#   Root is needed to read every directory and to see other users' processes.
#
# Article: https://blog.progineous.com/vps-disk-full/
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

top=10
target=/
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -n) [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "-n needs a number" >&2; exit 2; }; top=$2; shift 2 ;;
    -*) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    *) target=$1; shift ;;
  esac
done
[[ -d $target ]] || { echo "Not a directory: $target" >&2; exit 2; }
(( EUID == 0 )) || echo "Note: not running as root, so some directories and processes will be missing." >&2

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }
suggest() { printf '  suggestion: %s\n' "$1"; }

section "Filesystem $target"
df -h "$target"
df -i "$target"
use=$(df --output=pcent "$target" | tail -n 1 | tr -dc '0-9')
iuse=$(df --output=ipcent "$target" | tail -n 1 | tr -dc '0-9')
(( ${use:-0} >= 90 )) && echo "WARN  space is ${use}% used"
(( ${iuse:-0} >= 90 )) && echo "WARN  inodes are ${iuse}% used: look for directories with huge numbers of small files (sessions, cache, mail queue)"

if have findmnt && have tune2fs; then
  read -r src fstype < <(findmnt -no SOURCE,FSTYPE --target "$target")
  if [[ $fstype == ext[234] && -b $src ]]; then
    blocks=$(tune2fs -l "$src" 2>/dev/null | awk -F: '/^Reserved block count/ {gsub(/ /,"",$2); print $2}')
    bsize=$(tune2fs -l "$src" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /,"",$2); print $2}')
    if [[ -n ${blocks:-} && -n ${bsize:-} ]]; then
      echo "Reserved for root on $src: $(numfmt --to=iec $(( blocks * bsize ))) (not shown as Avail to normal users)"
    fi
  fi
fi

section "Biggest directories on $target (this filesystem only)"
du -xh --max-depth=1 "$target" 2>/dev/null | sort -rh > "$tmp" || true
head -n "$(( top + 1 ))" "$tmp"
echo "  next step: run du -xh --max-depth=1 on the biggest one and keep drilling down"

section "Files over 100M on $target"
find "$target" -xdev -type f -size +100M -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null | sort -rn > "$tmp" || true
if [[ -s $tmp ]]; then
  head -n "$top" "$tmp" | numfmt --field=1 --to=iec --padding=7
else
  echo "None."
fi

section "systemd journal"
if have journalctl; then
  journalctl --disk-usage 2>/dev/null || echo "Could not read the journal (run as root)."
  suggest "journalctl --vacuum-size=200M   (and set SystemMaxUse= in /etc/systemd/journald.conf)"
else
  echo "journalctl not found."
fi

section "Package cache and kernels"
if have apt-get; then
  du -sh /var/cache/apt/archives 2>/dev/null || true
  suggest "apt-get clean   (removes downloaded .deb files only)"
  if have dpkg-query; then
    echo "Running kernel: $(uname -r)"
    echo "Installed kernel packages:"
    dpkg-query -W -f='${Status} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '/ installed /{print "  " $4}' > "$tmp" || true
    if [[ -s $tmp ]]; then cat "$tmp"; else echo "  (none found by dpkg)"; fi
    suggest "apt autoremove --purge   (read the list it prints before you answer yes)"
  fi
elif have dnf; then
  du -sh /var/cache/dnf 2>/dev/null || true
  suggest "dnf clean packages"
else
  echo "No apt or dnf found."
fi

section "Docker"
if have docker && docker info >/dev/null 2>&1; then
  docker system df
  root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
  find "$root/containers" -name '*-json.log' -size +50M -printf '%s\t%p\n' 2>/dev/null | sort -rn > "$tmp" || true
  if [[ -s $tmp ]]; then
    echo "Container logs over 50M (not counted by docker system df):"
    head -n "$top" "$tmp" | numfmt --field=1 --to=iec --padding=7
    suggest "set log-opts max-size/max-file in /etc/docker/daemon.json, then recreate the container"
  fi
  suggest "docker image prune -a   (unused images only; check docker ps -a first)"
  suggest "docker builder prune    (build cache)"
  echo "  leave volumes alone unless you know what is in them: docker volume prune deletes data"
elif have docker; then
  echo "Docker is installed but the daemon is not reachable (not running, or run as root)."
else
  echo "Docker not installed."
fi

section "Deleted files still held open on $target (1M or more)"
found=0
if have lsof; then
  # Only files of 1M or more; small deleted temp files are normal.
  rows=$(lsof -nP -a +L1 "$target" 2>/dev/null | awk 'NR == 1 || $7 + 0 >= 1048576' || true)
  if (( $(wc -l <<<"$rows") > 1 )); then echo "$rows"; found=1; fi
else
  find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p -> %l\n' 2>/dev/null > "$tmp" || true
  if [[ -s $tmp ]]; then cat "$tmp"; found=1; fi
fi
if (( found )); then
  suggest "restart the process that holds the file (systemctl restart <service>)"
  suggest "or empty it in place: : > /proc/<PID>/fd/<FD>"
else
  echo "None."
fi

printf '\nNothing was changed. Read the suggestions above before running any of them.\n'
