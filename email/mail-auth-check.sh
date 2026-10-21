#!/usr/bin/env bash
# mail-auth-check.sh - Show the DMARC, SPF and DKIM records a domain publishes.
#
# Runs the same lookups the DMARC article starts with and adds a few plain checks:
# exactly one SPF record, a DMARC record present, its policy (p=) and report
# address (rua=), and whether a DKIM selector answers. Read-only.
#
# Usage: ./mail-auth-check.sh DOMAIN [DKIM_SELECTOR ...]
#   DKIM selectors are provider specific (e.g. s1, google, selector1); find yours
#   in a message's DKIM-Signature header (s=).
# Needs: dig.
#
# Articles: https://blog.progineous.com/read-dmarc-reports/
#           https://blog.progineous.com/how-to-keep-email-out-of-spam/
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
command -v dig >/dev/null || { echo "Missing: dig" >&2; exit 2; }

d=$1; shift; rc=0
txt() { dig +short TXT "$1" | sed 's/" "//g; s/^"//; s/"$//'; }

echo "== DMARC (_dmarc.$d) =="
dmarc=$(txt "_dmarc.$d" | grep -i '^v=DMARC1' || true)
if [[ -z $dmarc ]]; then echo "MISSING: no DMARC record"; rc=1
else
  echo "$dmarc"
  p=$(grep -oiE '(^|;)[[:space:]]*p=[a-z]+' <<<"$dmarc" | sed 's/.*=//' || true)
  echo "policy: ${p:-unknown}"
  grep -qi 'rua=' <<<"$dmarc" || { echo "NOTE: no rua= address, so no aggregate reports will arrive"; rc=1; }
fi

echo; echo "== SPF ($d) =="
spf=$(txt "$d" | grep -i '^v=spf1' || true)
n=$(grep -c . <<<"$spf" || true)
if (( n == 0 )); then echo "MISSING: no SPF record"; rc=1
elif (( n > 1 )); then echo "PROBLEM: $n SPF records (receivers expect exactly one)"; echo "$spf"; rc=1
else
  echo "$spf"
  case "${spf,,}" in
    *" ?all") echo "NOTE: ends in ?all (neutral)";;
    *" ~all") echo "NOTE: ends in ~all (softfail)";;
    *" -all") echo "ends in -all (hard fail for unlisted senders)";;
    *" +all"|*" all") echo "PROBLEM: ends in +all, any server may send as $d"; rc=1;;
    *) echo "NOTE: no all mechanism at the end";;
  esac
fi

for s in "$@"; do
  echo; echo "== DKIM ($s._domainkey.$d) =="
  k=$(txt "$s._domainkey.$d")
  if [[ -z $k ]]; then echo "MISSING: selector $s does not answer"; rc=1; else echo "${k:0:120}..."; fi
done
exit $rc
