#!/bin/bash
# Creates a per-machine self-signed code-signing identity for MountMate.
#
# Nothing here is ever shared between machines. The private key is generated locally
# and stays in this Mac's login keychain; a friend installing MountMate gets their
# own identity created the same way (spec §6, §7). The certificate does not need to
# be *trusted* — it exists only so `codesign` can produce a stable designated
# requirement, which is what SMAppService needs for launch-at-login to survive a
# rebuild. Gatekeeper never evaluates a locally compiled binary, because such
# binaries never receive com.apple.quarantine.
#
# Deliberately does NOT run `security add-trusted-cert`: trust settings only matter
# for Gatekeeper verification, which never happens here, and setting them requires
# administrator authorisation.
set -euo pipefail

IDENTITY="${MOUNTMATE_IDENTITY:-MountMate Self-Signed}"
KEYCHAIN="${MOUNTMATE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# --- already done? -------------------------------------------------------------
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "Identity \"$IDENTITY\" already exists. Nothing to do."
    exit 0
fi

# The private key is written to disk for a moment on its way into the keychain.
# Remove it whatever happens, including on failure.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- generate ------------------------------------------------------------------
# An explicit config file rather than -addext: macOS ships LibreSSL, whose support
# for -addext varies by version, while a config file works on both.
cat >"$WORK/openssl.cnf" <<CONFIG
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $IDENTITY

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" 2>/dev/null

# A random passphrase for the transport file only. It never leaves this script.
P12PASS="$(openssl rand -base64 24)"
openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -name "$IDENTITY" \
    -passout "pass:$P12PASS" 2>/dev/null

# --- import --------------------------------------------------------------------
# -T /usr/bin/codesign puts codesign on the key's access list, so signing does not
# prompt every time. macOS may still ask once for permission to use the new key;
# choose "Always Allow" when it does.
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# --- verify --------------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    cat >&2 <<MESSAGE
The certificate was imported but does not appear as a valid code-signing identity.

Create one by hand instead:
  Keychain Access > Certificate Assistant > Create a Certificate...
    Name:             $IDENTITY
    Identity Type:    Self Signed Root
    Certificate Type: Code Signing
MESSAGE
    exit 1
fi

cat <<DONE
Created code-signing identity "$IDENTITY" in
  $KEYCHAIN

It is self-signed, valid for 10 years, and specific to this machine. Now run:
  ./Scripts/install.sh

The first signing may ask for permission to use the new key — choose "Always Allow".
DONE
