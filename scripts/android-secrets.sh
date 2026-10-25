#!/usr/bin/env bash
# Prints the `gh secret set` commands for the Android release workflow.
# Prints no secret values; the printed commands read them from the key store
# directory at run time. Usage: scripts/android-secrets.sh [owner/repo]
set -euo pipefail
KEYS="${OPENFAMILY_KEYS_DIR:-/home/dockhub/OpenFamily/private/keys}"
REPO="${1:-OWNER/REPO}"
JKS="$KEYS/openfamily-release.jks"
PROPS="$KEYS/key.properties"
[ -f "$JKS" ] && [ -f "$PROPS" ] || { echo "Missing $JKS or $PROPS" >&2; exit 1; }
cat <<OUT
# Run these yourself (gh must be logged in with admin rights on the repo).
base64 -w0 '$JKS' | gh secret set ANDROID_KEYSTORE_BASE64 --repo $REPO
sed -n 's/^storePassword=//p' '$PROPS' | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD --repo $REPO
sed -n 's/^keyPassword=//p' '$PROPS' | tr -d '\n' | gh secret set ANDROID_KEY_PASSWORD --repo $REPO
sed -n 's/^keyAlias=//p' '$PROPS' | tr -d '\n' | gh secret set ANDROID_KEY_ALIAS --repo $REPO
OUT
