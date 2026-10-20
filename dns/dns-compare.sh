#!/usr/bin/env bash
# dns-compare.sh - Compare a DNS answer across the authoritative nameservers and public resolvers.
#
# Looks up the domain's NS set, asks each authoritative server directly
# (+norecurse), then asks 1.1.1.1 and 8.8.8.8, and prints the answers side by side.
# Mismatches usually mean a stale cache (wait for the TTL) or nameservers that
# disagree with each other (fix at the DNS host). Read-only.
#
# Usage: ./dns-compare.sh NAME [TYPE]
#   TYPE defaults to A (e.g. AAAA, MX, TXT, CNAME, NS)
# Needs: dig (dnsutils / bind-utils).
#
# Article: https://blog.progineous.com/read-dig-output-dns/
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
command -v dig >/dev/null || { echo "Missing: dig" >&2; exit 2; }

name=$1; type=${2:-A}
# Walk up from the name until something returns NS records (the zone apex).
zone=$name; ns=""
while [[ -n $zone ]]; do
  ns=$(dig +short NS "$zone" | sort)
  [[ -n $ns ]] && break
  [[ $zone == *.* ]] || break
  zone=${zone#*.}
done
[[ -n $ns ]] || { echo "Could not find NS records for $name" >&2; exit 1; }

X

echo "Zone: $zone   Query: $name $type"
declare -A seen=(); rc=0
for s in $ns; do
  a=$(answer "@$s" +norecurse); printf '%-28s %s\n' "auth $s" "${a:-<empty>}"; seen["$a"]=1
done
for r in 1.1.1.1 8.8.8.8; do
  a=$(answer "@$r"); printf '%-28s %s\n' "public $r" "${a:-<empty>}"; seen["$a"]=1
done
if (( ${#seen[@]} > 1 )); then
  echo "Answers differ. If the authoritative servers agree, public caches are waiting out the TTL."
  echo "If the authoritative servers disagree, fix the zone at the DNS host. 'dig +trace $name' shows the path."
  rc=1
else
  echo "All answers match."
fi
exit $rc
