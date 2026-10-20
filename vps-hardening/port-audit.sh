#!/usr/bin/env bash
# port-audit.sh - Read-only check of what is listening on this server.
#
# Lists listening TCP/UDP sockets (ss -tulpn), flags common database and admin
# ports that are bound to a public address instead of localhost, and prints the
# UFW status if UFW is installed. Changes nothing.
#
# Usage: sudo ./port-audit.sh [--help]
#   (root is only needed to see process names)
#
# Articles: https://blog.progineous.com/secure-linux-vps-15-minutes/
#           https://blog.progineous.com/how-to-secure-a-vps/
set -euo pipefail

if [[ ${1:-} == -h || ${1:-} == --help ]]; then sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi
command -v ss >/dev/null || { echo "ss (iproute2) is required." >&2; exit 1; }

# Ports that usually belong on localhost only.
declare -A RISKY=([3306]=MySQL/MariaDB [5432]=PostgreSQL [6379]=Redis [27017]=MongoDB
                  [11211]=Memcached [9200]=Elasticsearch [8080]=admin/alt-HTTP [2375]=Docker-API)

echo "== Listening sockets =="
ss -tulpn
echo
echo "== Public bindings worth a look =="
found=0
while read -r _ _ _ _ local _; do
  addr=${local%:*}; port=${local##*:}
  [[ -n ${RISKY[$port]:-} ]] || continue
  case "$addr" in 127.*|"[::1]"|::1|localhost) continue ;; esac
  printf 'WARN  %-8s %-14s bound to %s\n' "$port" "${RISKY[$port]}" "$addr"; found=1
done < <(ss -H -tuln)
(( found )) || echo "None of the usual database/admin ports are on a public address."
echo
if command -v ufw >/dev/null; then echo "== UFW =="; ufw status verbose 2>/dev/null || echo "(run as root to see UFW status)"; fi
echo
echo "Also check from outside (e.g. a phone on mobile data) and remember IPv6 and any provider firewall."
exit $found
