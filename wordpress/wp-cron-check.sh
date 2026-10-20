#!/usr/bin/env bash
# wp-cron-check.sh - Diagnose missed scheduled posts and optionally move WP-Cron to a real cron job.
#
# Read-only by default: lists future (scheduled) posts, due cron events and runs
# `wp cron test`. With --install it (after confirmation) sets
# DISABLE_WP_CRON true in wp-config.php and adds a crontab line for the current
# user that runs due events every 5 minutes.
#
# Usage: ./wp-cron-check.sh [--path /path/to/wordpress] [--install]
#   --path     WordPress root (default: current directory)
#   --install  disable WP-Cron and add the system cron job (asks first)
# Needs: WP-CLI (wp). Run as the site's user, not root.
#
# Article: https://blog.progineous.com/wordpress-missed-schedule-wp-cron/
set -euo pipefail

WP_PATH=$PWD; INSTALL=0
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) WP_PATH=${2:?}; shift 2 ;;
    --install) INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

WP=$(command -v wp) || { echo "WP-CLI (wp) not found." >&2; exit 2; }
[[ $EUID -eq 0 ]] && { echo "Run as the site's user, not root." >&2; exit 1; }
wpc() { "$WP" --path="$WP_PATH" "$@"; }
wpc core is-installed || { echo "No WordPress install at $WP_PATH" >&2; exit 1; }

echo "== Scheduled (future) posts =="
wpc post list --post_status=future --fields=ID,post_title,post_date
echo; echo "== Cron events =="
wpc cron event list
echo; echo "== Cron test =="
wpc cron test || echo "WP-Cron cannot reach itself; a system cron job is the usual fix."

(( INSTALL )) || { echo; echo "Read-only run. Use --install to switch to a system cron job."; exit 0; }

line="*/5 * * * * cd $WP_PATH && $WP cron event run --due-now --quiet"
echo; echo "About to: set DISABLE_WP_CRON true and add this crontab line:"; echo "  $line"
read -r -p "Continue? [y/N] " a </dev/tty
[[ $a =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }
if crontab -l 2>/dev/null | grep -Fq "$WP_PATH && $WP cron event run"; then
  echo "Crontab entry already present."
else
  (crontab -l 2>/dev/null || true; echo "$line") | crontab -
fi
wpc config set DISABLE_WP_CRON true --raw
echo "Done. Check again in 10 minutes with: wp cron event list"
