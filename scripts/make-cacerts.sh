#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Erzeugt runtime/cacerts/ (Android-4.4-Format HASH.0, alter OpenSSL-Hash) aus einem PEM-Bundle.
# KitKat kennt moderne Wurzeln (z. B. ISRG Root X1) nicht; ohne sie scheitern fast alle HTTPS-Seiten.
# Aufruf: bash scripts/make-cacerts.sh cacert.pem   (z. B. aus "pip download certifi" oder curl.se/ca)
set -euo pipefail
bundle="${1:?PEM-Bundle fehlt}"
out="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime/cacerts"
rm -rf "$out"; mkdir -p "$out"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++; f=sprintf("%s/c%04d.pem", d, n)} f{print > f} /END CERTIFICATE/{close(f); f=""}' "$bundle"
for c in "$tmp"/c*.pem; do
    h=$(openssl x509 -in "$c" -noout -subject_hash_old)
    i=0; while [ -e "$out/$h.$i" ]; do i=$((i + 1)); done
    { openssl x509 -in "$c"; openssl x509 -in "$c" -noout -text -fingerprint; } > "$out/$h.$i"
done
echo "$(ls "$out" | wc -l) Zertifikate in $out"
