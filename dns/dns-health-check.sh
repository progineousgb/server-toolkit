#!/usr/bin/env bash
# dns-health-check.sh - Check the DNS and mail records a domain publishes.
#
# Looks at NS, SOA, A/AAAA for the apex and www, MX (and that each MX host
# resolves), SPF (one record, the all mechanism, lookup count against the limit
# of 10), DMARC (policy and rua), DKIM, plus MTA-STS, TLS-RPT and CAA as info.
# Prints PASS / WARN / FAIL / INFO per check. Read-only.
#
# Usage: ./dns-health-check.sh DOMAIN [--selector NAME] [--json]
#   --selector NAME  DKIM selector to try (default: default, google, selector1,
#                    selector2, k1, mail, dkim)
#   --json           print the results as JSON instead of text
# Exit: 0 all pass, 1 warnings, 2 failures.
# Needs: dig or curl. Uses DNS over HTTPS (Cloudflare) if dig gets no answer.
# jq is used for DoH and JSON output when installed, but is optional.
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
domain=""; selector=""; json=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage; exit 0;;
    --selector) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; selector=$2; shift;;
    --json) json=1;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2;;
    *) domain=${1,,}; domain=${domain%.};;
  esac
  shift
done
[[ -n $domain ]] || { usage >&2; exit 2; }
command -v dig >/dev/null || command -v curl >/dev/null || { echo "Missing: dig or curl" >&2; exit 2; }
have_jq=0; command -v jq >/dev/null && have_jq=1

# Resolver. Try dig first; if it times out, is not installed or looks
# intercepted, switch to DoH for the rest of the run. Output is one record per line, like dig +short.
use_doh=0
# q() runs inside $(...), so a switch to DoH made there would be lost.
# Remember it in a file instead.
doh_flag=$(mktemp); trap 'rm -f "$doh_flag"' EXIT
command -v dig >/dev/null || use_doh=1
# Some networks answer every query themselves: fake A records in 198.18.0.0/15
# and empty answers for the rest. The root zone always has an SOA, so an empty
# answer there means the local resolver can't be trusted.
if (( ! use_doh )); then
  probe=$(dig +time=2 +tries=1 +short SOA . 2>/dev/null || true)
  [[ -z $probe ]] && use_doh=1
fi
declare -A typenum=([A]=1 [NS]=2 [CNAME]=5 [SOA]=6 [MX]=15 [TXT]=16 [AAAA]=28 [CAA]=257)

doh() {
  local out t=${typenum[$1]}
  out=$(curl -fsS --max-time 8 -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=$2&type=$1") || return 1
  if (( have_jq )); then
    jq -r --argjson t "$t" '.Answer[]? | select(.type == $t) | .data' <<<"$out"
  else
    grep -o "\"type\":$t,\"TTL\":[0-9]*,\"data\":\"\\([^\"\\\\]\\|\\\\.\\)*\"" <<<"$out" \
      | sed 's/.*"data":"//; s/"$//; s/\\"/"/g' || true
  fi
}

q() {
  local out
  [[ -s $doh_flag ]] && use_doh=1
  if (( ! use_doh )); then
    if out=$(dig +time=2 +tries=1 +noall +answer +comments "$1" "$2" 2>/dev/null) \
       && grep -q 'status:' <<<"$out"; then
      awk -v t="$1" '!/^;/ && NF >= 5 && $4 == t { $1=$2=$3=$4=""; sub(/^ +/, ""); print }' <<<"$out"
      return 0
    fi
    use_doh=1; echo 1 > "$doh_flag"
  fi
  doh "$1" "$2" || { echo "DNS lookup failed for $2 $1 (dig and DoH)" >&2; return 1; }
}

# TXT strings come back quoted and sometimes split; join them into one line each.
txt() { q TXT "$1" | sed 's/" "//g; s/^"//; s/"$//'; }

results=(); worst=0
add() { # STATUS CHECK MESSAGE
  results+=("$1"$'\t'"$2"$'\t'"$3")
  case $1 in WARN) (( worst < 1 )) && worst=1;; FAIL) worst=2;; esac
  return 0
}
joined() { paste -sd' ' - | sed 's/ /, /g'; }

d=$domain

# NS and SOA
ns=$(q NS "$d" | sed 's/\.$//' | sort)
if [[ -n $ns ]]; then add PASS ns "$(joined <<<"$ns")"; else add FAIL ns "no NS records"; fi
soa=$(q SOA "$d")
if [[ -n $soa ]]; then add PASS soa "$(awk '{print $1, $2, "serial", $3}' <<<"$soa")"
else add FAIL soa "no SOA record"; fi

# Addresses for apex and www
for h in "$d" "www.$d"; do
  a=$(q A "$h" | grep -E '^[0-9.]+$' || true)
  aaaa=$(q AAAA "$h" | grep ':' || true)
  if [[ -n $a ]]; then add PASS "a $h" "$(joined <<<"$a")"
  elif [[ $h == "$d" ]]; then add WARN "a $h" "no A record"
  else add INFO "a $h" "no A record"; fi
  if [[ -n $aaaa ]]; then add PASS "aaaa $h" "$(joined <<<"$aaaa")"
  else add INFO "aaaa $h" "no AAAA record"; fi
done

# MX
mx=$(q MX "$d" | sort -n)
if [[ -z $mx ]]; then add WARN mx "no MX records (fine if the domain sends no mail)"
elif [[ $(awk '{print $2}' <<<"$mx") == "." ]]; then add INFO mx "null MX, domain accepts no mail"
else
  while read -r pref host; do
    host=${host%.}
    if [[ -n $(q A "$host")$(q AAAA "$host") ]]; then add PASS "mx $host" "pref $pref, resolves"
    else add FAIL "mx $host" "pref $pref, host does not resolve"; fi
  done <<<"$mx"
fi

# SPF. Count terms that cost a DNS lookup, following include and redirect.
lookups=0
spf_count() { # DOMAIN DEPTH
  local rec term target
  (( $2 > 10 )) && return 0
  rec=$(txt "$1" | grep -i '^v=spf1' | head -n1 || true)
  for term in $rec; do
    term=${term#[+?~-]}
    case ${term,,} in
      include:*|redirect=*)
        lookups=$((lookups + 1)); target=${term#*[:=]}
        [[ $target == *%* ]] || spf_count "$target" $(( $2 + 1 ));;
      a|a:*|a/*|mx|mx:*|mx/*|ptr|ptr:*|exists:*) lookups=$((lookups + 1));;
    esac
  done
}
spf=$(txt "$d" | grep -i '^v=spf1' || true)
n=$(grep -c . <<<"$spf" || true)
if (( n == 0 )); then add FAIL spf "no SPF record"
elif (( n > 1 )); then add FAIL spf "$n SPF records, receivers expect exactly one"
else
  case ${spf,,} in
    *" -all") add PASS spf "ends in -all";;
    *" ~all") add PASS spf "ends in ~all (softfail)";;
    *" ?all") add WARN spf "ends in ?all (neutral), gives no protection";;
    *" +all"|*" all") add WARN spf "ends in +all, any server may send as $d";;
    *redirect=*) add PASS spf "uses redirect";;
    *) add WARN spf "no all mechanism at the end";;
  esac
  spf_count "$d" 0
  if (( lookups > 10 )); then add WARN "spf lookups" "$lookups DNS lookups, the limit is 10"
  else add PASS "spf lookups" "$lookups of 10"; fi
fi

# DMARC
dmarc=$(txt "_dmarc.$d" | grep -i '^v=DMARC1' || true)
if [[ -z $dmarc ]]; then add FAIL dmarc "no DMARC record at _dmarc.$d"
else
  p=$(grep -oiE '(^|;)[[:space:]]*p=[a-z]+' <<<"$dmarc" | sed 's/.*=//' | head -n1 || true)
  case ${p,,} in
    reject|quarantine) add PASS dmarc "p=${p,,}";;
    none) add WARN dmarc "p=none, monitoring only";;
    *) add FAIL dmarc "no valid p= tag";;
  esac
  if grep -qi 'rua=' <<<"$dmarc"; then add PASS "dmarc rua" "$(grep -oiE 'rua=[^;]+' <<<"$dmarc" | head -n1)"
  else add WARN "dmarc rua" "no rua= address, no aggregate reports"; fi
fi

# DKIM
if [[ -n $selector ]]; then sels=("$selector"); else sels=(default google selector1 selector2 k1 mail dkim); fi
found=""; revoked=""
for s in "${sels[@]}"; do
  k=$(txt "$s._domainkey.$d" || true)
  [[ -z $k ]] && k=$(q CNAME "$s._domainkey.$d" || true)
  [[ -z $k ]] && continue
  # An empty p= means the key was revoked on purpose.
  if grep -qiE '(^|;)[[:space:]]*p=[[:space:]]*(;|$)' <<<"$k"; then revoked+="$s "; else found+="$s "; fi
done
if [[ -n $found ]]; then add PASS dkim "selector(s) found: ${found% }"
elif [[ -n $revoked ]]; then add WARN dkim "only revoked keys (empty p=): ${revoked% }"
elif [[ -n $selector ]]; then add FAIL dkim "selector $selector does not answer"
else add WARN dkim "none of the common selectors answer, pass --selector to check yours"; fi

# Info only
v=$(txt "_mta-sts.$d" | grep -i '^v=STSv1' || true)
add INFO mta-sts "${v:-not published}"
v=$(txt "_smtp._tls.$d" | grep -i '^v=TLSRPTv1' || true)
add INFO tls-rpt "${v:-not published}"
v=$(q CAA "$d" | sed 's/"//g' || true)
if [[ -n $v ]]; then add INFO caa "$(paste -sd';' - <<<"$v" | sed 's/;/; /g')"; else add INFO caa "not published, any CA may issue"; fi

# Output
via=dig; [[ -s $doh_flag ]] && use_doh=1; (( use_doh )) && via=doh
if (( json )); then
  if (( have_jq )); then
    printf '%s\n' "${results[@]}" | jq -Rn --arg d "$d" --arg via "$via" --argjson rc "$worst" \
      '{domain: $d, resolver: $via, exit: $rc, checks: [inputs | split("\t") | {status: .[0], check: .[1], detail: .[2]}]}'
  else
    esc() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
    printf '{"domain":%s,"resolver":"%s","exit":%d,"checks":[' "$(esc "$d")" "$via" "$worst"
    sep=""
    for r in "${results[@]}"; do
      IFS=$'\t' read -r st ck dt <<<"$r"
      printf '%s{"status":"%s","check":%s,"detail":%s}' "$sep" "$st" "$(esc "$ck")" "$(esc "$dt")"; sep=","
    done
    printf ']}\n'
  fi
else
  echo "DNS health for $d (via $via)"
  for r in "${results[@]}"; do
    IFS=$'\t' read -r st ck dt <<<"$r"
    printf '%-5s %-26s %s\n' "$st" "$ck" "$dt"
  done
  case $worst in 0) echo "Result: all checks passed";; 1) echo "Result: warnings";; 2) echo "Result: failures";; esac
fi
exit "$worst"
