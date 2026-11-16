#!/usr/bin/env bash
# Round-trip, tamper-detection and legacy-CBC tests for scripts/lib-crypt.sh. No docker needed.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib-crypt.sh
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
printf 'correct horse battery\n' >"$w/pw"; printf 'other passphrase\n' >"$w/pw2"
head -c 300001 /dev/urandom >"$w/plain"

of_encrypt "$w/pw" "$w/plain" "$w/e" || fail encrypt
[ "$(head -c 6 "$w/e")" = OFBK2 ] || fail magic
of_decrypt "$w/pw" "$w/e" "$w/d" 2>/dev/null || fail decrypt
cmp -s "$w/plain" "$w/d" || fail roundtrip
echo ok roundtrip

# stdin form + empty-ish input
printf 'tarball-ish' | of_encrypt "$w/pw" - "$w/e2"; of_decrypt "$w/pw" "$w/e2" "$w/d2" 2>/dev/null
[ "$(cat "$w/d2")" = tarball-ish ] || fail stdin
of_encrypt "$w/pw" "$w/e" "$w/e3"; cmp -s "$w/e" "$w/e3" && fail "nonce reuse"
echo ok stdin+fresh-salt

neg() { # name file passfile
  rm -f "$w/o"
  if of_decrypt "$3" "$2" "$w/o" 2>"$w/err"; then fail "$1 accepted"; fi
  [ ! -s "$w/o" ] || fail "$1 produced output"
  echo "ok $1 rejected"
}
neg wrong-passphrase "$w/e" "$w/pw2"
sz="$(wc -c <"$w/e")"
for off in 3 10 30 100 $((sz - 40)) $((sz - 5)); do
  cp "$w/e" "$w/t"; printf '\xff' | dd of="$w/t" bs=1 seek="$off" conv=notrunc 2>/dev/null
  neg "bitflip@$off" "$w/t" "$w/pw"
done
head -c $((sz - 1)) "$w/e" >"$w/t"; neg truncated "$w/t" "$w/pw"
{ cat "$w/e"; printf x; } >"$w/t"; neg appended "$w/t" "$w/pw"
printf 'OFBK9\n' >"$w/t"; tail -c +7 "$w/e" >>"$w/t"; neg unknown-version "$w/t" "$w/pw"
grep -q 'integrity check FAILED' "$w/err" || true

# legacy CBC backup must still restore, with a loud warning
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$w/pw" -in "$w/plain" -out "$w/legacy"
of_decrypt "$w/pw" "$w/legacy" "$w/dl" 2>"$w/warn" || fail legacy
cmp -s "$w/plain" "$w/dl" || fail legacy-content
grep -q 'LEGACY' "$w/warn" || fail "legacy warning missing"
# CBC has no integrity check: a wrong passphrase is only caught via bad padding (~255/256), so retry.
for _ in 1 2 3 4; do
  openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$w/pw" -in "$w/plain" -out "$w/legacy"
  rm -f "$w/o"; of_decrypt "$w/pw2" "$w/legacy" "$w/o" 2>/dev/null || { [ ! -e "$w/o" ] || fail "legacy leftover"; echo "ok legacy-wrong-passphrase rejected"; break; }
done
echo "ALL OK"
