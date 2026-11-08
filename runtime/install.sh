#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
cd "$BASE"
fail() { echo "Installation: $*" >&2; exit 1; }
[ ! -f rootfs.img ] || { echo 'rootfs.img existiert bereits; unverändert belassen.'; exit 0; }
[ -f rootfs.img.gz ] && [ -f rootfs.img.gz.sha256 ] && [ -f rootfs.size ] || fail 'Rootfs oder Integritätsdateien fehlen.'
[ ! -d run/lock ] || [ -f run/runner.pid ] || fail 'Verwaister Laufzeitzustand; erst android.sh recover verwenden.'
bytes=$(cat rootfs.size)
case "$bytes" in ''|*[!0-9]*) fail 'Ungültige rootfs.size.' ;; esac
[ "$bytes" -gt 0 ] && [ "$bytes" -lt 4294967295 ] || fail 'Image passt nicht in eine FAT32-Datei.'
sha256sum -c rootfs.img.gz.sha256 || fail 'Prüfsumme des komprimierten Images stimmt nicht.'
avail_kb=$(df -Pk . | awk 'END {print $4}')
need_kb=$(( (bytes + 1023) / 1024 + 65536 ))
[ "$avail_kb" -ge "$need_kb" ] || fail "Zu wenig freier Speicher: mindestens $need_kb KiB zusätzlich nötig."
# A failed decompression never replaces a working image. No mount or firmware write.
tmp="rootfs.img.new.$$"
trap 'rm -f "$tmp"' EXIT
trap 'exit 1' INT TERM HUP
gzip -dc rootfs.img.gz > "$tmp"
actual=$(wc -c < "$tmp" | tr -d ' ')
[ "$actual" = "$bytes" ] || fail "Imagegröße falsch: $actual statt $bytes."
mv "$tmp" rootfs.img
sync
echo 'Rootfs installiert. Kernel prüfen: sh android.sh check'
