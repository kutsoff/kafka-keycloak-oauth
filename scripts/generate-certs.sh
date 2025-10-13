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

# Generate broker keystore
keytool -genkey -keyalg RSA -keysize 2048 \
  -keystore kafka-security/broker/kafka.server.keystore.jks \
  -validity 3650 -storepass changeit -keypass changeit \
  -dname "CN=kafka-broker,OU=IT,O=Organization,L=City,ST=State,C=US" \
  -ext SAN=dns:kafka-broker,dns:localhost,ip:127.0.0.1

# Create CSR
keytool -keystore kafka-security/broker/kafka.server.keystore.jks -certreq \
  -file kafka-security/broker/kafka-broker.csr \
  -storepass changeit -keypass changeit

# Create v3 extension file (FIXED: no process substitution)
cat > kafka-security/broker/v3.ext <<EOF
[v3_req]
subjectAltName = DNS:kafka-broker,DNS:localhost,IP:127.0.0.1
EOF

# Sign certificate
openssl x509 -req -CA kafka-security/ca/ca-cert.pem \
  -CAkey kafka-security/ca/ca-key.pem \
  -in kafka-security/broker/kafka-broker.csr \
  -out kafka-security/broker/kafka-broker-signed.pem \
  -days 3650 -CAcreateserial -passin pass:changeit \
  -extensions v3_req -extfile kafka-security/broker/v3.ext

# Import CA into broker keystore
keytool -keystore kafka-security/broker/kafka.server.keystore.jks \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass changeit -noprompt

# Import signed certificate
keytool -keystore kafka-security/broker/kafka.server.keystore.jks \
  -alias kafka-broker -import \
  -file kafka-security/broker/kafka-broker-signed.pem \
  -storepass changeit -noprompt

# Create broker truststore
keytool -keystore kafka-security/broker/kafka.server.truststore.jks \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass changeit -noprompt

echo -e "${GREEN}✓ Broker certificates generated${NC}"

# Client Certificates
echo -e "${YELLOW}Generating client certificates...${NC}"

# Generate client keystore
keytool -genkey -keyalg RSA -keysize 2048 \
  -keystore kafka-security/client/kafka.client.keystore.jks \
  -validity 3650 -storepass changeit -keypass changeit \
  -dname "CN=kafka-client,OU=IT,O=Organization,L=City,ST=State,C=US"

# Create CSR
keytool -keystore kafka-security/client/kafka.client.keystore.jks -certreq \
  -file kafka-security/client/kafka-client.csr \
  -storepass changeit -keypass changeit

# Sign certificate
openssl x509 -req -CA kafka-security/ca/ca-cert.pem \
  -CAkey kafka-security/ca/ca-key.pem \
  -in kafka-security/client/kafka-client.csr \
  -out kafka-security/client/kafka-client-signed.pem \
  -days 3650 -CAcreateserial -passin pass:changeit

# Import CA into client keystore
keytool -keystore kafka-security/client/kafka.client.keystore.jks \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass changeit -noprompt

# Import signed certificate
keytool -keystore kafka-security/client/kafka.client.keystore.jks \
  -alias kafka-client -import \
  -file kafka-security/client/kafka-client-signed.pem \
  -storepass changeit -noprompt

# Create client truststore
keytool -keystore kafka-security/client/kafka.client.truststore.jks \
  -alias CARoot -import -file kafka-security/ca/ca-cert.pem \
  -storepass changeit -noprompt

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
