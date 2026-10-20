#!/usr/bin/env bash
# rdap-lookup.sh - Show a short RDAP summary for one domain.
#
# Prints name, status (e.g. clientTransferProhibited = locked), registration /
# expiration events, nameservers, DNSSEC, and the registrar's RDAP link if the
# registry offers one. The RDAP server is picked from the IANA bootstrap file.
#
# Usage: ./rdap-lookup.sh DOMAIN [--raw]
#   --raw   print the full RDAP JSON instead of the summary
# Needs: curl, jq.
#
# Article: https://blog.progineous.com/rdap-domain-lookup/
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
for c in curl jq; do command -v "$c" >/dev/null || { echo "Missing: $c" >&2; exit 2; }; done

d=${1,,}; tld=${d##*.}
base=$(curl -fsS https://data.iana.org/rdap/dns.json \
  | jq -r --arg t "$tld" 'first(.services[] | select(.[0] | index($t)) | .[1][0]) // empty')
[[ -n $base ]] || { echo "No RDAP server listed for .$tld; check the registry's own lookup." >&2; exit 1; }

json=$(curl -fsS "${base%/}/domain/$d") || { echo "RDAP lookup failed for $d at $base" >&2; exit 1; }
if [[ ${2:-} == --raw ]]; then jq . <<<"$json"; exit 0; fi

jq '{
  name: .ldhName,
  status,
  events: ([.events[]? | {(.eventAction): .eventDate}] | add),
  nameservers: [.nameservers[]?.ldhName],
  dnssec: .secureDNS.delegationSigned
}' <<<"$json"
rel=$(jq -r '[.links[]? | select(.rel == "related") | .href] | first // empty' <<<"$json")
[[ -n $rel ]] && echo "Registrar RDAP: $rel"
exit 0
