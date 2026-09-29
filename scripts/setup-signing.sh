#!/bin/sh
set -eu
umask 077

keychain="$HOME/Library/Keychains/login.keychain-db"
identity='Fman Development'

if security find-identity -v -p codesigning "$keychain" | grep -Fq "\"$identity\""; then
    echo "$identity is already installed."
    exit 0
fi
if security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
    echo "$identity exists but is not a valid signing identity. Check it in Keychain Access." >&2
    exit 1
fi

signing_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fman-signing.XXXXXX")
trap 'rm -rf "$signing_tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$identity/" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' \
    -keyout "$signing_tmp/key.pem" -out "$signing_tmp/cert.pem" 2>"$signing_tmp/openssl.log"
signing_password=$(openssl rand -hex 24)
printf '%s\n' "$signing_password" | /usr/bin/openssl pkcs12 -export -name "$identity" -inkey "$signing_tmp/key.pem" \
    -in "$signing_tmp/cert.pem" -out "$signing_tmp/identity.p12" -passout stdin \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$signing_tmp/identity.p12" -k "$keychain" -P "$signing_password" -x -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$signing_tmp/cert.pem"
security find-identity -v -p codesigning "$keychain"
