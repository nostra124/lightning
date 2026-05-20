#!/bin/bash
# Refresh the vendored standards from upstream (FEAT-178).
#
# Reads UPSTREAM.txt (TSV: local-path / url / retrieved-on)
# and re-fetches each entry. Updates the retrieved-on column
# in-place. Run from the standards/ directory.

set -e

cd "$(dirname "$0")"
[ -f UPSTREAM.txt ] || { echo "refresh.sh: UPSTREAM.txt missing" >&2; exit 1; }
command -v curl >/dev/null || { echo "refresh.sh: curl required" >&2; exit 127; }

today=$(date -u +%Y-%m-%d)
tmp=$(mktemp)

while IFS=$'\t' read -r path url _; do
	case "$path" in '#'*|'') echo "$path	$url	" >> "$tmp"; continue ;; esac
	mkdir -p "$(dirname "$path")"
	if curl -fsSL "$url" -o "$path"; then
		echo "refresh.sh: ✓ $path"
		printf '%s\t%s\t%s\n' "$path" "$url" "$today" >> "$tmp"
	else
		echo "refresh.sh: ✗ $path (kept previous)" >&2
		printf '%s\t%s\t%s\n' "$path" "$url" "(stale)" >> "$tmp"
	fi
done < UPSTREAM.txt

mv "$tmp" UPSTREAM.txt
echo "refresh.sh: done"
