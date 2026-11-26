#!/bin/bash
#
# Stores your Apple Development certificate as the signing secrets of the "Build DMG" workflow, so CI
# builds are signed by your team like local Xcode builds: Soduto Share can then reach the app through
# its App Group (named after the Team ID, which macOS only grants to apps signed by that team), and
# permissions carry over between builds.
#
#   scripts/store-signing-certificate.sh certificate.p12 [owner/repo]
#
# Get the .p12 on your Mac:
#   1. If you have no "Apple Development" certificate yet: Xcode › Settings › Accounts › your Apple ID ›
#      Manage Certificates › + › Apple Development. A free Apple ID (Personal Team) works.
#   2. Keychain Access › My Certificates › "Apple Development: <you> (<ID>)" › Export… › .p12, with a
#      password.
#
# The script reads the Team ID from the certificate (its Organizational Unit) and, with the GitHub CLI,
# stores SODUTO_SIGNING_P12, SODUTO_SIGNING_PASSWORD and SODUTO_TEAM_ID in the repository given or the
# one `gh` resolves for this checkout. Without `gh` it prints them to add under Settings › Secrets and
# variables › Actions.
#
# Certificates from a free Apple ID last a year: run this again with a new one when it expires.

set -euo pipefail

P12="${1:-}"
if [ -z "$P12" ] || [ ! -f "$P12" ]; then
    echo "Usage: $0 certificate.p12 [owner/repo]" >&2
    exit 1
fi
REPO="${2:-}"

read -r -s -p "Password of $P12: " PASSWORD
echo

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# -legacy reads .p12 files exported by Keychain Access with OpenSSL 3; fall back for LibreSSL
if ! openssl pkcs12 -legacy -in "$P12" -passin "pass:$PASSWORD" -nokeys -clcerts -out "$WORKDIR/cert.pem" 2> /dev/null; then
    openssl pkcs12 -in "$P12" -passin "pass:$PASSWORD" -nokeys -clcerts -out "$WORKDIR/cert.pem"
fi

SUBJECT="$(openssl x509 -in "$WORKDIR/cert.pem" -noout -subject -nameopt multiline)"
TEAM_ID="$(echo "$SUBJECT" | sed -n 's/^ *organizationalUnitName *= *//p' | head -n 1)"
COMMON_NAME="$(echo "$SUBJECT" | sed -n 's/^ *commonName *= *//p' | head -n 1)"
if [ -z "$TEAM_ID" ]; then
    echo "No Team ID (Organizational Unit) in this certificate. Is it an Apple Development certificate?" >&2
    exit 1
fi
echo "Certificate: $COMMON_NAME"
echo "Team ID:     $TEAM_ID"
openssl x509 -in "$WORKDIR/cert.pem" -noout -enddate

P12_BASE64="$(base64 < "$P12" | tr -d '\n')"

if [ -z "$REPO" ] && command -v gh > /dev/null 2>&1; then
    DETECTED="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null || true)"
    if [ -n "$DETECTED" ]; then
        read -r -p "Store the signing secrets in $DETECTED? [Y/n] " ANSWER
        case "$ANSWER" in
            [nN]*) echo "Pass the repository explicitly, e.g. $0 $P12 owner/repo"; exit 1 ;;
            *) REPO="$DETECTED" ;;
        esac
    fi
fi

if [ -n "$REPO" ] && command -v gh > /dev/null 2>&1; then
    printf '%s' "$P12_BASE64" | gh secret set SODUTO_SIGNING_P12 --repo "$REPO"
    printf '%s' "$PASSWORD" | gh secret set SODUTO_SIGNING_PASSWORD --repo "$REPO"
    printf '%s' "$TEAM_ID" | gh secret set SODUTO_TEAM_ID --repo "$REPO"
    echo "Stored SODUTO_SIGNING_P12, SODUTO_SIGNING_PASSWORD and SODUTO_TEAM_ID in $REPO."
    echo "The next workflow run signs with this certificate for team $TEAM_ID."
else
    echo
    echo "Add these three repository secrets (Settings › Secrets and variables › Actions):"
    echo
    echo "SODUTO_TEAM_ID:"
    echo "$TEAM_ID"
    echo
    echo "SODUTO_SIGNING_PASSWORD: (the password you just typed)"
    echo
    echo "SODUTO_SIGNING_P12:"
    echo "$P12_BASE64"
fi
