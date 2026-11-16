#!/usr/bin/env bash
# Authenticated at-rest encryption for scripts/backup.sh and friends. Needs only bash + openssl (>= 1.1.1).
# `openssl enc` cannot do AEAD (no GCM), so this is encrypt-then-MAC.
#
# FILE FORMAT "OFBK2" (written by backup.sh as *.dump.enc and *.server-key.tar.enc; names unchanged):
#   offset 0   6 bytes   magic  "OFBK2\n"        (format version; unknown versions are refused)
#   offset 6  16 bytes   salt   (random)
#   offset 22 16 bytes   iv     (random)
#   offset 38  N bytes   ciphertext = AES-256-CTR(enc_key, iv, plaintext)
#   last 32   32 bytes   tag    = HMAC-SHA256(mac_key, magic || salt || iv || ciphertext)
# Keys: master = PBKDF2-HMAC-SHA256(passphrase-file first line, salt, 600000 iterations, 32 bytes);
#   PRK = HMAC(salt, master)  (HKDF-Extract);  enc_key = HMAC(PRK, "orbitly-backup-enc\x01"),
#   mac_key = HMAC(PRK, "orbitly-backup-mac\x01")  (HKDF-Expand, one block each; separate keys).
# Decryption verifies the tag in constant-time style (compare of HMACs under a fresh random key)
# BEFORE any decryption; a bad tag outputs nothing. Wrong passphrase and tampering both fail the tag.
# LEGACY: files starting with "Salted__" are old unauthenticated AES-256-CBC (pbkdf2, 600000). They are
# still restorable, with a loud warning (no integrity protection: re-back-up after restoring).
#
# of_encrypt PASSFILE IN|- OUT      of_decrypt PASSFILE IN OUT

_of_hex() { od -An -v -tx1 | tr -d ' \n'; }
_of_hmac() { # keyhex  (data on stdin) -> hex
  openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -r | cut -d' ' -f1
}
_of_keys() { # passfile salthex -> sets _of_enc _of_mac (hex)
  local master prk
  master="$(openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -S "$2" -pass "file:$1" -P </dev/null 2>/dev/null | sed -n 's/^key *= *//p')"
  [ "${#master}" = 64 ] || { echo "error: key derivation failed" >&2; return 1; }
  prk="$(printf '%s' "$master" | xxd -r -p | _of_hmac "$2")"
  _of_enc="$(printf 'orbitly-backup-enc\001' | _of_hmac "$prk")"
  _of_mac="$(printf 'orbitly-backup-mac\001' | _of_hmac "$prk")"
}

of_encrypt() {
  local pass="$1" in="$2" out="$3" salt iv tag tmp
  salt="$(openssl rand -hex 16)"; iv="$(openssl rand -hex 16)"
  _of_keys "$pass" "$salt" || return 1
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  { printf 'OFBK2\n'; printf '%s' "$salt$iv" | xxd -r -p; } >"$out" || return 1
  if [ "$in" = "-" ]; then
    openssl enc -aes-256-ctr -K "$_of_enc" -iv "$iv" >>"$out" || return 1
  else
    openssl enc -aes-256-ctr -K "$_of_enc" -iv "$iv" -in "$in" >>"$out" || return 1
  fi
  tag="$(_of_hmac "$_of_mac" <"$out")" || return 1
  printf '%s' "$tag" | xxd -r -p >>"$out"
}

of_decrypt() {
  local pass="$1" in="$2" out="$3" size magic salt iv tag calc ck a b
  size="$(wc -c <"$in" | tr -d ' ')"
  magic="$(head -c 8 "$in" | LC_ALL=C tr -d '\0')"
  case "$magic" in
    Salted__*)
      echo "WARNING: $in is a LEGACY backup (AES-256-CBC, NO integrity protection)." >&2
      echo "WARNING: tampering or corruption cannot be detected. Restore it, then take a new backup." >&2
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$pass" -in "$in" -out "$out" 2>/dev/null \
        || { rm -f "$out"; echo "error: decryption failed (wrong passphrase?)" >&2; return 1; }
      return 0 ;;
  esac
  if [ "$(head -c 6 "$in")" != "OFBK2" ]; then
    echo "error: not a recognised encrypted backup (unknown format or version)" >&2; return 1
  fi
  [ "$size" -ge $((38 + 32)) ] || { echo "error: encrypted backup is truncated" >&2; return 1; }
  salt="$(head -c 22 "$in" | tail -c 16 | _of_hex)"
  iv="$(head -c 38 "$in" | tail -c 16 | _of_hex)"
  tag="$(tail -c 32 "$in" | _of_hex)"
  _of_keys "$pass" "$salt" || return 1
  calc="$(head -c $((size - 32)) "$in" | _of_hmac "$_of_mac")"
  ck="$(openssl rand -hex 32)"
  a="$(printf '%s' "$calc" | _of_hmac "$ck")"; b="$(printf '%s' "$tag" | _of_hmac "$ck")"
  if [ "$a" != "$b" ]; then
    echo "error: integrity check FAILED (wrong passphrase, or the backup is corrupted or was tampered with); nothing was decrypted" >&2
    return 1
  fi
  head -c $((size - 32)) "$in" | tail -c +39 | openssl enc -d -aes-256-ctr -K "$_of_enc" -iv "$iv" -out "$out" \
    || { echo "error: decryption failed" >&2; return 1; }
}
