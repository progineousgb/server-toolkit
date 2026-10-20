#!/usr/bin/env bash
# domain-expiry.sh - Check expiry dates and risky status flags for a list of domains over RDAP.
#
# Finds the right RDAP server per TLD from the IANA bootstrap file, reads the
# "expiration" event and flags hold / redemption / pending delete / auto renew period.
# Exit code: 0 all fine, 1 something needs attention, 2 bootstrap fetch failed.
#
# Usage: ./domain-expiry.sh DOMAINS_FILE [WARN_DAYS]
#   DOMAINS_FILE  one domain per line (blank lines and # comments ignored)
#   WARN_DAYS     warn when fewer days remain (default 30)
# Cron example (weekly, mail only on problems via moreutils' chronic):
#   0 8 * * 1  chronic /usr/local/bin/domain-expiry.sh /etc/domains.txt 45
# Needs: curl, jq, GNU date.
#
# Article: https://blog.progineous.com/rdap-domain-lookup/
set -euo pipefail

if [[ ${1:-} == -h || ${1:-} == --help || $# -lt 1 ]]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; [[ $# -lt 1 ]] && exit 2; exit 0
fi
for c in curl jq date; do command -v "$c" >/dev/null || { echo "Missing: $c" >&2; exit 2; }; done

list=$1; warn=${2:-30}; rc=0
[[ -r $list ]] || { echo "Cannot read $list" >&2; exit 2; }
[[ $warn =~ ^[0-9]+$ ]] || { echo "WARN_DAYS must be a number" >&2; exit 2; }
boot=$(curl -fsS https://data.iana.org/rdap/dns.json) || exit 2

while read -r d || [[ -n $d ]]; do
  d=${d%%#*}; d=${d//[[:space:]]/}
  [[ -z $d ]] && continue
  tld=${d##*.}
  base=$(jq -r --arg t "$tld" \
    'first(.services[] | select(.[0] | index($t)) | .[1][0]) // empty' <<<"$boot")
  if [[ -z $base ]]; then
    printf '%-26s no RDAP server for .%s, check by hand\n' "$d" "$tld"; continue
  fi

  json=$(curl -s -w '\n%{http_code}' "${base%/}/domain/$d" || true)
  code=${json##*$'\n'}; json=${json%$'\n'*}
  if [[ $code != 200 ]]; then
    printf '%-26s lookup failed: HTTP %s\n' "$d" "$code"; rc=1; continue
  fi

  exp=$(jq -r 'first(.events[]? | select(.eventAction=="expiration") | .eventDate) // empty' <<<"$json")
  flags=$(jq -r '[.status[]? | select(test("hold|redemption|pending delete|auto renew period"))] | join(", ")' <<<"$json")
  if [[ -z $exp ]]; then
    printf '%-26s no expiration date in the RDAP reply\n' "$d"; rc=1; continue
  fi
  days=$(( ($(date -d "$exp" +%s) - $(date +%s)) / 86400 ))

  note=ok
  if (( days < warn )); then note="RENEW SOON"; rc=1; fi
  if [[ -n $flags ]]; then note="CHECK: $flags"; rc=1; fi
  printf '%-26s expires %s  %4d days  %s\n' "$d" "${exp%%T*}" "$days" "$note"
  sleep 1   # be polite to registry servers
done < "$list"
exit $rc
