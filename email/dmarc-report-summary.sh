#!/usr/bin/env bash
# dmarc-report-summary.sh - Summarise DMARC aggregate (rua) reports by source IP.
#
# Accepts .zip, .xml.gz and .xml report files, extracts them to a temporary
# directory (your originals are left untouched) and prints one line per record:
#   source_ip count dkim=<pass|fail> spf=<pass|fail> signer=<dkim domain>
# sorted by message count. Rows that fail both DKIM and SPF are the ones to
# chase before moving to p=quarantine or p=reject.
#
# Usage: ./dmarc-report-summary.sh REPORT [REPORT ...]
# Needs: xmlstarlet, unzip, gunzip.
#
# Article: https://blog.progineous.com/read-dmarc-reports/
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
for c in xmlstarlet unzip gunzip; do command -v "$c" >/dev/null || { echo "Missing: $c" >&2; exit 2; }; done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
i=0
for f in "$@"; do
  i=$((i+1))
  case "$f" in
    *.zip) unzip -qo "$f" -d "$tmp/$i" ;;
    *.gz)  mkdir -p "$tmp/$i"; gunzip -c "$f" > "$tmp/$i/report.xml" ;;
    *.xml) mkdir -p "$tmp/$i"; cp "$f" "$tmp/$i/" ;;
    *) echo "Skipping $f (not .zip/.gz/.xml)" >&2 ;;
  esac
done

mapfile -t xmls < <(find "$tmp" -type f -name '*.xml')
(( ${#xmls[@]} )) || { echo "No XML reports found." >&2; exit 1; }

xmlstarlet sel -t -m //record -v row/source_ip -o ' ' -v row/count \
  -o ' dkim=' -v row/policy_evaluated/dkim -o ' spf=' -v row/policy_evaluated/spf \
  -o ' signer=' -v 'auth_results/dkim[1]/domain' -n "${xmls[@]}" | sort -k2 -rn
