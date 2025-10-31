#!/bin/bash
set -e

echo "======================================"
echo "Kafka SSL Certificate Generation"
echo "======================================"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Change to script directory
cd "$(dirname "$0")/.."

# Create directories
echo -e "${YELLOW}Creating directory structure...${NC}"
mkdir -p kafka-security/{ca,broker,client}

# Certificate Authority
echo -e "${YELLOW}Generating Certificate Authority...${NC}"
openssl req -new -x509 -keyout kafka-security/ca/ca-key.pem \
  -out kafka-security/ca/ca-cert.pem \
  -days 3650 -passout pass:changeit \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=IT/CN=KafkaCA"

echo -e "${GREEN}✓ CA certificate generated${NC}"

# Broker Certificates
echo -e "${YELLOW}Generating broker certificates...${NC}"

# --- CHANGED: add keystore/alias variables and safe cleanup to avoid "alias already exists" ---
BROKER_KEYSTORE=kafka-security/broker/kafka.server.keystore.jks
BROKER_ALIAS=kafka-broker
BROKER_STOREPASS=changeit

# Ensure broker directory exists
mkdir -p "$(dirname "$BROKER_KEYSTORE")"

# If keystore exists, try to delete the alias or remove the keystore to avoid conflicts
if [ -f "$BROKER_KEYSTORE" ]; then
  echo "Broker keystore already exists at $BROKER_KEYSTORE"
  if keytool -list -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" -alias "$BROKER_ALIAS" >/dev/null 2>&1; then
    echo "Alias $BROKER_ALIAS already exists in keystore — deleting alias..."
    keytool -delete -alias "$BROKER_ALIAS" -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" || true
  else
    echo "Keystore exists but alias $BROKER_ALIAS not found — removing keystore file to start fresh..."
    rm -f "$BROKER_KEYSTORE"
  fi
fi

# Generate broker keystore (use genkeypair to avoid deprecation)
keytool -genkeypair -keyalg RSA -keysize 2048 \
  -keystore "$BROKER_KEYSTORE" \
  -validity 3650 -storepass "$BROKER_STOREPASS" -keypass "$BROKER_STOREPASS" \
  -dname "CN=kafka-broker,OU=IT,O=Organization,L=City,ST=State,C=US" \
  -alias "$BROKER_ALIAS" \
  -ext SAN=dns:kafka-broker,dns:localhost,ip:127.0.0.1
# --- END CHANGED ---

# Create CSR, sign it and ensure the signed cert matches the keystore public key.
# If mismatch occurs, regenerate keypair/CSR and retry (prevents "Public keys in reply and keystore don't match").
MAX_ATTEMPTS=3
BROKER_CSR=kafka-security/broker/kafka-broker.csr
BROKER_SIGNED=kafka-security/broker/kafka-broker-signed.pem
V3_EXT=kafka-security/broker/v3.ext

# Clean up any existing files
rm -f "$BROKER_CSR" "$BROKER_SIGNED" "$V3_EXT"

# Create proper v3.ext file with all required sections
cat > "$V3_EXT" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
authorityKeyIdentifier = keyid,issuer
subjectAltName = @alt_names

[alt_names]
DNS.1 = kafka-broker
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

for attempt in $(seq 1 $MAX_ATTEMPTS); do
  echo -e "${YELLOW}Attempt $attempt of $MAX_ATTEMPTS${NC}"
  
  # Generate fresh CSR
  keytool -keystore "$BROKER_KEYSTORE" -certreq \
    -file "$BROKER_CSR" \
    -alias "$BROKER_ALIAS" \
    -storepass "$BROKER_STOREPASS" -keypass "$BROKER_STOREPASS"

  # Sign with proper x509v3 extensions
  openssl x509 -req \
    -CA kafka-security/ca/ca-cert.pem \
    -CAkey kafka-security/ca/ca-key.pem \
    -in "$BROKER_CSR" \
    -out "$BROKER_SIGNED" \
    -days 3650 \
    -CAcreateserial \
    -passin pass:changeit \
    -extfile "$V3_EXT"

  echo "Comparing public keys..."
  
  # Extract public keys in text format for comparison
  KEYSTORE_PUB=$(keytool -exportcert -rfc \
    -keystore "$BROKER_KEYSTORE" \
    -alias "$BROKER_ALIAS" \
    -storepass "$BROKER_STOREPASS" | 
    openssl x509 -pubkey -noout 2>/dev/null)
  
  SIGNED_PUB=$(openssl x509 -in "$BROKER_SIGNED" -pubkey -noout 2>/dev/null)

  if [ "$KEYSTORE_PUB" = "$SIGNED_PUB" ]; then
    echo -e "${GREEN}✓ Public keys match${NC}"
    break
  else
    echo -e "${YELLOW}Public keys don't match, showing diff:${NC}"
    diff <(echo "$KEYSTORE_PUB") <(echo "$SIGNED_PUB") || true
    
    if [ $attempt -eq $MAX_ATTEMPTS ]; then
      echo -e "${YELLOW}Maximum attempts reached. Final debug info:${NC}"
      echo "Keystore certificate info:"
      keytool -list -v -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" -alias "$BROKER_ALIAS"
      echo "Signed certificate info:"
      openssl x509 -in "$BROKER_SIGNED" -text -noout
      echo "ERROR: Public keys still do not match after $MAX_ATTEMPTS attempts. Aborting." >&2
      exit 1
    fi
    
    echo "Regenerating keypair..."
    keytool -delete -alias "$BROKER_ALIAS" -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" || true
    keytool -genkeypair -keyalg RSA -keysize 2048 \
      -keystore "$BROKER_KEYSTORE" \
      -validity 3650 -storepass "$BROKER_STOREPASS" -keypass "$BROKER_STOREPASS" \
      -dname "CN=kafka-broker,OU=IT,O=Organization,L=City,ST=State,C=US" \
      -alias "$BROKER_ALIAS" \
      -ext SAN=dns:kafka-broker,dns:localhost,ip:127.0.0.1
  fi
done

# After loop, ensure we have a signed cert whose public key matches keystore
if [ ! -f "$BROKER_SIGNED" ]; then
  echo "ERROR: signed broker certificate not found" >&2
  exit 1
fi

# Final check: compare once more, fail if mismatch remains
keytool -exportcert -rfc -alias "$BROKER_ALIAS" -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" -file kafka-security/broker/tmp-final-keystore-cert.pem >/dev/null 2>&1 || true
openssl x509 -pubkey -noout -in kafka-security/broker/tmp-final-keystore-cert.pem  > kafka-security/broker/tmp-final-keystore-pub.pem 2>/dev/null || true
openssl x509 -pubkey -noout -in "$BROKER_SIGNED"                               > kafka-security/broker/tmp-final-signed-pub.pem    2>/dev/null || true

if ! cmp -s kafka-security/broker/tmp-final-keystore-pub.pem kafka-security/broker/tmp-final-signed-pub.pem; then
  echo "ERROR: Public keys still do not match after retries. Aborting." >&2
  rm -f kafka-security/broker/tmp-final-* || true
  exit 1
fi
rm -f kafka-security/broker/tmp-final-* || true

# Import CA into broker keystore (idempotent)
if keytool -list -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" -alias CARoot >/dev/null 2>&1; then
  keytool -delete -alias CARoot -keystore "$BROKER_KEYSTORE" -storepass "$BROKER_STOREPASS" || true
fi
keytool -keystore "$BROKER_KEYSTORE" -alias CARoot -import -file kafka-security/ca/ca-cert.pem -storepass "$BROKER_STOREPASS" -noprompt

# Import signed certificate into keystore (will link to existing private key)
keytool -keystore "$BROKER_KEYSTORE" -alias "$BROKER_ALIAS" -import -file "$BROKER_SIGNED" -storepass "$BROKER_STOREPASS" -noprompt

# Create broker truststore
# --- CHANGED: ensure CARoot is imported idempotently into broker truststore ---
BROKER_TRUSTSTORE=kafka-security/broker/kafka.server.truststore.jks
if [ -f "$BROKER_TRUSTSTORE" ]; then
  if keytool -list -keystore "$BROKER_TRUSTSTORE" -storepass "$BROKER_STOREPASS" -alias CARoot >/dev/null 2>&1; then
    echo "Alias CARoot already exists in $BROKER_TRUSTSTORE — deleting before import..."
    keytool -delete -alias CARoot -keystore "$BROKER_TRUSTSTORE" -storepass "$BROKER_STOREPASS" || true
  fi
fi
keytool -keystore "$BROKER_TRUSTSTORE" \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass "$BROKER_STOREPASS" -noprompt
# --- END CHANGED ---

echo -e "${GREEN}✓ Broker certificates generated${NC}"

# Client Certificates
echo -e "${YELLOW}Generating client certificates...${NC}"

# Client keystore variables and CSR/cert paths
CLIENT_KEYSTORE=kafka-security/client/kafka.client.keystore.jks
CLIENT_ALIAS=kafka-client
CLIENT_STOREPASS=changeit
CLIENT_CSR=kafka-security/client/kafka-client.csr
CLIENT_SIGNED=kafka-security/client/kafka-client-signed.pem

# Ensure client directory exists and clean up
mkdir -p "$(dirname "$CLIENT_KEYSTORE")"
rm -f "$CLIENT_CSR" "$CLIENT_SIGNED"

# Clean up existing keystore/alias
if [ -f "$CLIENT_KEYSTORE" ]; then
  echo "Client keystore already exists at $CLIENT_KEYSTORE"
  if keytool -list -keystore "$CLIENT_KEYSTORE" -storepass "$CLIENT_STOREPASS" -alias "$CLIENT_ALIAS" >/dev/null 2>&1; then
    keytool -delete -alias "$CLIENT_ALIAS" -keystore "$CLIENT_KEYSTORE" -storepass "$CLIENT_STOREPASS" || true
  else
    rm -f "$CLIENT_KEYSTORE"
  fi
fi

# Try multiple times to generate and verify client certificates
for attempt in $(seq 1 $MAX_ATTEMPTS); do
  echo -e "${YELLOW}Generating client certificate (attempt $attempt)...${NC}"
  
  # Generate fresh keypair
  keytool -genkeypair -keyalg RSA -keysize 2048 \
    -keystore "$CLIENT_KEYSTORE" \
    -validity 3650 -storepass "$CLIENT_STOREPASS" -keypass "$CLIENT_STOREPASS" \
    -dname "CN=kafka-client,OU=IT,O=Organization,L=City,ST=State,C=US" \
    -alias "$CLIENT_ALIAS"

  # Generate CSR
  keytool -keystore "$CLIENT_KEYSTORE" -certreq \
    -file "$CLIENT_CSR" \
    -alias "$CLIENT_ALIAS" \
    -storepass "$CLIENT_STOREPASS" -keypass "$CLIENT_STOREPASS"

  # Sign certificate
  openssl x509 -req -CA kafka-security/ca/ca-cert.pem \
    -CAkey kafka-security/ca/ca-key.pem \
    -in "$CLIENT_CSR" \
    -out "$CLIENT_SIGNED" \
    -days 3650 -CAcreateserial -passin pass:changeit

  # Compare public keys
  echo "Verifying client certificate public keys..."
  CLIENT_KEYSTORE_PUB=$(keytool -exportcert -rfc \
    -keystore "$CLIENT_KEYSTORE" \
    -alias "$CLIENT_ALIAS" \
    -storepass "$CLIENT_STOREPASS" | 
    openssl x509 -pubkey -noout 2>/dev/null)
  
  CLIENT_SIGNED_PUB=$(openssl x509 -in "$CLIENT_SIGNED" -pubkey -noout 2>/dev/null)

  if [ "$CLIENT_KEYSTORE_PUB" = "$CLIENT_SIGNED_PUB" ]; then
    echo -e "${GREEN}✓ Client certificate public keys match${NC}"
    break
  else
    echo -e "${YELLOW}Client certificate public keys don't match on attempt $attempt${NC}"
    if [ $attempt -eq $MAX_ATTEMPTS ]; then
      echo "ERROR: Client certificate public keys still don't match after $MAX_ATTEMPTS attempts" >&2
      exit 1
    fi
    # Clean up for next attempt
    keytool -delete -alias "$CLIENT_ALIAS" -keystore "$CLIENT_KEYSTORE" -storepass "$CLIENT_STOREPASS" || true
  fi
done

# Import CA into client keystore
if keytool -list -keystore "$CLIENT_KEYSTORE" -storepass "$CLIENT_STOREPASS" -alias CARoot >/dev/null 2>&1; then
  keytool -delete -alias CARoot -keystore "$CLIENT_KEYSTORE" -storepass "$CLIENT_STOREPASS" || true
fi
keytool -keystore "$CLIENT_KEYSTORE" \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass "$CLIENT_STOREPASS" -noprompt

# Import signed certificate
keytool -keystore "$CLIENT_KEYSTORE" \
  -alias "$CLIENT_ALIAS" -import \
  -file "$CLIENT_SIGNED" \
  -storepass "$CLIENT_STOREPASS" -noprompt

# Create client truststore
# --- CHANGED: ensure CARoot is imported idempotently into client truststore ---
CLIENT_TRUSTSTORE=kafka-security/client/kafka.client.truststore.jks
if [ -f "$CLIENT_TRUSTSTORE" ]; then
  if keytool -list -keystore "$CLIENT_TRUSTSTORE" -storepass "$CLIENT_STOREPASS" -alias CARoot >/dev/null 2>&1; then
    echo "Alias CARoot already exists in $CLIENT_TRUSTSTORE — deleting before import..."
    keytool -delete -alias CARoot -keystore "$CLIENT_TRUSTSTORE" -storepass "$CLIENT_STOREPASS" || true
  fi
fi
keytool -keystore "$CLIENT_TRUSTSTORE" \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass "$CLIENT_STOREPASS" -noprompt
# --- END CHANGED ---

echo -e "${GREEN}✓ Client certificates generated${NC}"

# Verify certificates
echo -e "${YELLOW}Verifying certificates...${NC}"

echo "Broker keystore:"
keytool -list -v -keystore kafka-security/broker/kafka.server.keystore.jks \
  -storepass changeit | grep -A2 "Alias name"

echo ""
echo "Certificate SAN:"
openssl x509 -in kafka-security/broker/kafka-broker-signed.pem -text -noout | \
  grep -A1 "Subject Alternative Name"

echo -e "${GREEN}✓ Certificate verification complete${NC}"
echo ""
echo -e "${GREEN}======================================"
echo "SSL certificates generated successfully!"
echo "======================================${NC}"
