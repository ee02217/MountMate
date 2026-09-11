#!/bin/bash
# Creates a per-machine self-signed code-signing identity for MountMate.
#
# Nothing here is ever shared between machines. The private key is generated locally
# and stays in this Mac's login keychain; a friend installing MountMate gets their
# own identity created the same way. The certificate exists so
# `codesign` can produce a stable designated requirement, which is what SMAppService
# needs for launch-at-login to survive a rebuild.
#
# It DOES set trust, in the user domain only. An untrusted self-signed certificate is
# imported successfully but `security find-identity -v` will not list it and codesign
# cannot select it by name — "valid" means trusted for code signing. Trust is scoped
# to the codeSign policy rather than granted wholesale, and the user domain avoids
# needing administrator rights. macOS asks for the login password once.
set -euo pipefail

IDENTITY="${MOUNTMATE_IDENTITY:-MountMate Self-Signed}"
KEYCHAIN="${MOUNTMATE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# --- already usable? -----------------------------------------------------------
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "Identity \"$IDENTITY\" already exists and is valid. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- reuse an existing certificate if there is one ------------------------------
# A previous run may have imported the certificate without trusting it. Generating
# another would leave a duplicate in the keychain for no reason.
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "Found an existing \"$IDENTITY\" certificate; adding trust to it."
    security find-certificate -c "$IDENTITY" -p >"$WORK/cert.pem"
else
    # --- generate --------------------------------------------------------------
    # An explicit config file rather than -addext: macOS ships LibreSSL, whose
    # support for -addext varies by version, while a config file works on both.
    cat >"$WORK/openssl.cnf" <<CONFIG
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $IDENTITY

[ v3 ]
basicConstraints     = critical,CA:true
keyUsage             = critical,keyCertSign,digitalSignature
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

    # -T /usr/bin/codesign puts codesign on the key's access list, so signing does
    # not prompt on every build.
    security import "$WORK/identity.p12" \
        -k "$KEYCHAIN" -P "$P12PASS" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
fi

# --- trust ---------------------------------------------------------------------
echo
echo "macOS will now ask for your login password to trust this certificate for"
echo "code signing. This is the one prompt; it is not asked again."
echo

# -r trustRoot: it is its own root. -p codeSign: trusted for that and nothing else.
# No -d, so this is the user's trust domain and needs no administrator rights.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# --- warn about duplicates ------------------------------------------------------
# `add-trusted-cert` adds the certificate file to the keychain as well as trusting
# it, so trusting an already-imported certificate can leave a second, keyless copy.
# Harmless — install.sh signs by SHA-1 hash, and only the copy with a private key
# appears as an identity — but worth saying out loud rather than leaving to be
# discovered as "ambiguous (matches ... and ...)".
CERT_COUNT="$(security find-certificate -a -c "$IDENTITY" -Z 2>/dev/null | grep -c 'SHA-1 hash' || true)"
if [ "${CERT_COUNT:-0}" -gt 1 ]; then
    echo
    echo "Note: $CERT_COUNT certificates named \"$IDENTITY\" are in the keychain."
    echo "Only the one holding a private key is used, and install.sh selects it by"
    echo "hash, so this is safe to ignore. To tidy up, delete the extras in Keychain"
    echo "Access — the one to keep shows a private key beneath it when expanded."
fi

# --- verify --------------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    cat >&2 <<MESSAGE
The certificate is present but still does not count as a valid code-signing
identity. Trust may not have been applied.

Create one by hand instead:
  Keychain Access > Certificate Assistant > Create a Certificate...
    Name:             $IDENTITY
    Identity Type:    Self Signed Root
    Certificate Type: Code Signing
MESSAGE
    exit 1
fi

cat <<DONE
Created and trusted code-signing identity "$IDENTITY" in
  $KEYCHAIN

It is self-signed, valid for 10 years, trusted only for code signing, and specific
to this machine. Now run:
  ./Scripts/install.sh

The first signing may ask for permission to use the new key — choose "Always Allow".
DONE
