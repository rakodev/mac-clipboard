#!/bin/bash

# Setup script for MacClipboard development code signing
# This creates a self-signed certificate that persists across builds,
# so you don't have to re-grant accessibility permissions after each rebuild.
#
# Run this once on a new machine: ./scripts/setup-dev-signing.sh

set -e

CERT_NAME="MacClipboard Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"

echo "🔐 MacClipboard Development Signing Setup"
echo "=========================================="
echo ""

# Check if certificate already exists and is valid for code signing
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' already exists and is valid for code signing."
    echo ""
    echo "To verify it works, run: ./run.sh"
    echo ""
    echo "To recreate the certificate (if having issues):"
    echo "  1. Open Keychain Access"
    echo "  2. Search for '$CERT_NAME' and delete both the certificate and private key"
    echo "  3. Run this script again"
    exit 0
fi

# Check if certificate exists but isn't trusted
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN_PATH" &>/dev/null; then
    echo "⚠️  Certificate exists but isn't trusted for code signing."
    echo "   Attempting to add trust..."
    echo ""
fi

echo "Creating self-signed certificate for development..."
echo ""
echo "⚠️  You may be prompted for your macOS password."
echo ""

# Create temporary directory for certificate files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Generate key
openssl genrsa -out "$TEMP_DIR/key.pem" 2048 2>/dev/null

# Create certificate config
cat > "$TEMP_DIR/openssl.cnf" << 'CNFEOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = MacClipboard Dev

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:FALSE
CNFEOF

# Create self-signed certificate
echo "📜 Creating self-signed certificate..."
openssl req -x509 -new -nodes -key "$TEMP_DIR/key.pem" \
    -sha256 -days 3650 \
    -out "$TEMP_DIR/cert.pem" \
    -config "$TEMP_DIR/openssl.cnf" 2>/dev/null

# Convert to p12 format with a password (required for import)
# Use -legacy flag for OpenSSL 3.x compatibility with macOS security command
echo "📦 Converting to PKCS12 format..."
openssl pkcs12 -export \
    -out "$TEMP_DIR/cert.p12" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" \
    -password pass:temppass123 \
    -legacy 2>/dev/null || \
openssl pkcs12 -export \
    -out "$TEMP_DIR/cert.p12" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" \
    -password pass:temppass123

echo "🔑 Importing certificate to keychain..."

# Import the p12 file
security import "$TEMP_DIR/cert.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "temppass123" \
    -T /usr/bin/codesign \
    -T /usr/bin/productsign \
    -T /usr/bin/security 2>/dev/null || true

# Allow codesign to access the key without prompting
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN_PATH" 2>/dev/null || true

# Add trust for code signing - this is the key step!
echo "🔒 Adding code signing trust (may require password)..."

# Export the cert to add trust
security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN_PATH" > "$TEMP_DIR/cert_export.pem" 2>/dev/null

# Add trusted cert with code signing trust
# This requires admin privileges and will prompt for password
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "/Library/Keychains/System.keychain" "$TEMP_DIR/cert_export.pem" 2>/dev/null || \
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN_PATH" "$TEMP_DIR/cert_export.pem" 2>/dev/null || true

echo ""

# Verify the certificate was created and is trusted
sleep 1  # Give keychain a moment to update
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' created and trusted successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Run ./run.sh to build and launch the app"
    echo "  2. Grant accessibility permission once to 'MacClipboard-Dev'"
    echo "  3. Future builds will keep the permission (same signature)"
else
    echo "⚠️  Certificate created but may need manual trust setup."
    echo ""
    echo "Please complete setup manually:"
    echo "  1. Open Keychain Access"
    echo "  2. Find '$CERT_NAME' certificate"
    echo "  3. Double-click it → Trust → Code Signing: Always Trust"
    echo "  4. Close and enter password when prompted"
    echo ""
    echo "Then run ./run.sh"
fi
