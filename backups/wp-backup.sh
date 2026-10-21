#!/usr/bin/env bash
# wp-backup.sh - Back up a WordPress site: files plus a database dump, with retention.
#
# Creates DEST/<site>-<timestamp>.tar.gz containing wp-config.php, .htaccess (if
# present), wp-content and WordPress core, plus a SQL dump made with the database's
# own tool (wp db export via WP-CLI). Keeps daily archives for KEEP_DAYS
# (default 7) and asks before deleting older ones unless --yes is given.
# Copy the result off the server (rsync/rclone to another account or region) and
# test a restore on a spare folder; a backup you have not restored is a guess.
#
# Usage: ./wp-backup.sh --path /path/to/wordpress --dest /backups [--keep 7] [--yes]
# Needs: WP-CLI (wp), tar, gzip. Run as the site's user.
#
# Articles: https://blog.progineous.com/how-to-back-up-wordpress/
#           https://blog.progineous.com/how-to-back-up-a-vps/
set -euo pipefail

WP_PATH=""; DEST=""; KEEP=7; ASSUME_YES=0
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) WP_PATH=${2:?}; shift 2 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    --keep) KEEP=${2:?}; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n $WP_PATH && -n $DEST ]] || { usage >&2; exit 2; }
[[ $KEEP =~ ^[0-9]+$ ]] || { echo "--keep must be a number" >&2; exit 2; }
command -v wp >/dev/null || { echo "WP-CLI (wp) not found." >&2; exit 2; }
[[ -f $WP_PATH/wp-config.php ]] || { echo "No wp-config.php in $WP_PATH" >&2; exit 1; }
case "$(realpath "$DEST" 2>/dev/null || echo "$DEST")" in
  "$(realpath "$WP_PATH")"|"$(realpath "$WP_PATH")"/*) echo "DEST must not be inside the WordPress folder." >&2; exit 1 ;;
esac

umask 077   # archives contain wp-config.php and the database
mkdir -p "$DEST"
site=$(basename "$(realpath "$WP_PATH")"); ts=$(date +%Y%m%d-%H%M%S)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Refuse to fill the disk: need roughly the site size free.
need=$(du -sk "$WP_PATH" | cut -f1); free=$(df -Pk "$DEST" | awk 'NR==2{print $4}')
(( free > need )) || { echo "Not enough free space in $DEST (${free}K free, ~${need}K needed)." >&2; exit 1; }

echo "Dumping database..."
wp --path="$WP_PATH" db export "$work/database.sql" --quiet
[[ -s $work/database.sql ]] || { echo "Database dump is empty." >&2; exit 1; }

out="$DEST/$site-$ts.tar.gz"
echo "Archiving files to $out ..."
tar -czf "$out" -C "$work" database.sql -C "$(dirname "$(realpath "$WP_PATH")")" "$site"
tar -tzf "$out" >/dev/null && echo "Archive OK: $(du -h "$out" | cut -f1)"

mapfile -t old < <(find "$DEST" -maxdepth 1 -name "$site-*.tar.gz" -mtime +"$KEEP" -print)
if (( ${#old[@]} )); then
  printf 'Older than %s days:\n' "$KEEP"; printf '  %s\n' "${old[@]}"
  ok=$ASSUME_YES
  if (( ! ok )); then read -r -p "Delete these? [y/N] " a </dev/tty || a=n; [[ $a =~ ^[Yy]$ ]] && ok=1; fi
  if (( ok )); then rm -f -- "${old[@]}"; echo "Old archives removed."; else echo "Kept old archives."; fi
fi
echo "Next: copy $out off this server and test a restore."
