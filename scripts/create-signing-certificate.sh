#!/bin/bash
#
# Creates the self-signed code-signing certificate that the "Build DMG" workflow uses to give every CI
# build the same code identity, so macOS keeps Soduto's Accessibility permission and keychain access
# across updates. Run it once on any Mac (or Linux) machine with openssl.
#
#   scripts/create-signing-certificate.sh [owner/repo]
#
# With the GitHub CLI (`gh`, logged in) and a repository argument, it stores the two secrets directly.
# Otherwise it prints them for you to add under the repository's
# Settings › Secrets and variables › Actions › New repository secret:
#
#   SODUTO_SIGNING_P12        base64 of the certificate + private key (.p12)
#   SODUTO_SIGNING_PASSWORD   the .p12 password
#
# The private key never needs to leave the secret store; the script deletes its temporary files.
# Keep the same certificate for as long as you want permissions to carry over: a new certificate means
# re-granting Accessibility once.

set -euo pipefail

REPO="${1:-}"
NAME="Soduto Self-Signed Code Signing"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/certificate.cnf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = $NAME

[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -config "$WORKDIR/certificate.cnf" \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/certificate.pem" 2> /dev/null

PASSWORD="$(openssl rand -base64 24)"
# SHA1/3DES keeps the .p12 readable by macOS `security import` with both LibreSSL and OpenSSL 3
openssl pkcs12 -export \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/certificate.pem" \
    -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASSWORD" \
    -out "$WORKDIR/certificate.p12"

P12_BASE64="$(base64 < "$WORKDIR/certificate.p12" | tr -d '\n')"

echo "Created \"$NAME\" (valid for 10 years)"
openssl x509 -in "$WORKDIR/certificate.pem" -noout -fingerprint -sha256

if [ -n "$REPO" ] && command -v gh > /dev/null 2>&1; then
    printf '%s' "$P12_BASE64" | gh secret set SODUTO_SIGNING_P12 --repo "$REPO"
    printf '%s' "$PASSWORD" | gh secret set SODUTO_SIGNING_PASSWORD --repo "$REPO"
    echo "Stored SODUTO_SIGNING_P12 and SODUTO_SIGNING_PASSWORD in $REPO."
    echo "The next workflow run signs with this certificate."
else
    echo
    echo "Add these two repository secrets (Settings › Secrets and variables › Actions):"
    echo
    echo "SODUTO_SIGNING_PASSWORD:"
    echo "$PASSWORD"
    echo
    echo "SODUTO_SIGNING_P12:"
    echo "$P12_BASE64"
fi
