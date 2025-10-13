#!/bin/bash
set -e

echo "======================================"
echo "Keycloak Setup & Configuration"
echo "======================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cd "$(dirname "$0")/.."

KEYCLOAK_URL="http://localhost:8080"
ADMIN_USER="admin"
ADMIN_PASS="admin123"
REALM_NAME="kafka-realm"

echo -e "${YELLOW}Waiting for Keycloak to be ready...${NC}"
for i in {1..30}; do
    if curl -sf "${KEYCLOAK_URL}/health/ready" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Keycloak is ready${NC}"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Get admin access token
echo -e "${YELLOW}Getting admin access token...${NC}"
ADMIN_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" | jq -r '.access_token')

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" == "null" ]; then
    echo -e "${RED}✗ Failed to get admin token${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Got admin token${NC}"

# Create realm
echo -e "${YELLOW}Creating realm: ${REALM_NAME}...${NC}"
curl -s -X POST "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"realm\": \"${REALM_NAME}\",
        \"enabled\": true
    }" || echo "Realm might already exist"

echo -e "${GREEN}✓ Realm created/verified${NC}"

# Function to create client and get secret
create_client() {
    local CLIENT_ID=$1
    local CLIENT_NAME=$2

    echo -e "${YELLOW}Creating client: ${CLIENT_ID}...${NC}"

    # Create client
    curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"clientId\": \"${CLIENT_ID}\",
            \"name\": \"${CLIENT_NAME}\",
            \"enabled\": true,
            \"clientAuthenticatorType\": \"client-secret\",
            \"serviceAccountsEnabled\": true,
            \"standardFlowEnabled\": false,
            \"directAccessGrantsEnabled\": false,
            \"publicClient\": false
        }" || echo "Client might already exist"

    # Get client UUID
    CLIENT_UUID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${CLIENT_ID}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')

    if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" == "null" ]; then
        echo -e "${RED}✗ Failed to get client UUID for ${CLIENT_ID}${NC}"
        return 1
    fi

    # Get client secret
    CLIENT_SECRET=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/client-secret" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.value')

    echo -e "${GREEN}✓ Client ${CLIENT_ID} created${NC}"
    echo -e "  Secret: ${CLIENT_SECRET}"

    # Add audience mapper
    echo -e "${YELLOW}Adding audience mapper for ${CLIENT_ID}...${NC}"

    # Get dedicated scope ID
    SCOPE_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/client-scopes" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r ".[] | select(.name==\"${CLIENT_ID}-dedicated\") | .id")

    if [ -n "$SCOPE_ID" ] && [ "$SCOPE_ID" != "null" ]; then
        curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/client-scopes/${SCOPE_ID}/protocol-mappers/models" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"audience-mapper\",
                \"protocol\": \"openid-connect\",
                \"protocolMapper\": \"oidc-audience-mapper\",
                \"config\": {
                    \"included.client.audience\": \"kafka-broker\",
                    \"access.token.claim\": \"true\"
                }
            }" || echo "Mapper might already exist"

        echo -e "${GREEN}✓ Audience mapper added${NC}"
    fi

    echo "$CLIENT_SECRET"
}

# Create clients
BROKER_SECRET=$(create_client "kafka-broker" "Kafka Broker")
PRODUCER_SECRET=$(create_client "kafka-producer" "Kafka Producer")
CONSUMER_SECRET=$(create_client "kafka-consumer" "Kafka Consumer")

# Generate .env file
echo -e "${YELLOW}Generating .env file...${NC}"
cat > .env <<EOF
# Kafka Version
KAFKA_VERSION=4.1.0

# Keycloak Configuration
KEYCLOAK_REALM=kafka-realm
KEYCLOAK_URL=http://keycloak:8080
KEYCLOAK_TOKEN_ENDPOINT=http://keycloak:8080/realms/kafka-realm/protocol/openid-connect/token
KEYCLOAK_JWKS_ENDPOINT=http://keycloak:8080/realms/kafka-realm/protocol/openid-connect/certs
KEYCLOAK_ISSUER=http://keycloak:8080/realms/kafka-realm

# Kafka Broker OAuth Credentials
KAFKA_BROKER_CLIENT_ID=kafka-broker
KAFKA_BROKER_CLIENT_SECRET=${BROKER_SECRET}

# Kafka Producer OAuth Credentials
KAFKA_PRODUCER_CLIENT_ID=kafka-producer
KAFKA_PRODUCER_CLIENT_SECRET=${PRODUCER_SECRET}

# Kafka Consumer OAuth Credentials
KAFKA_CONSUMER_CLIENT_ID=kafka-consumer
KAFKA_CONSUMER_CLIENT_SECRET=${CONSUMER_SECRET}

# SSL Configuration
SSL_KEYSTORE_PASSWORD=changeit
SSL_KEY_PASSWORD=changeit
SSL_TRUSTSTORE_PASSWORD=changeit

# Cluster Configuration
CLUSTER_ID=kafka-cluster-01
KAFKA_BROKER_HOST=kafka-broker
KAFKA_BROKER_PORT=9093
EOF

echo -e "${GREEN}✓ .env file generated${NC}"

# Generate Kafka client property files
echo -e "${YELLOW}Generating Kafka client property files...${NC}"

cat > kafka-config/admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.oauthbearer.token.endpoint.url=http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token

ssl.truststore.location=/etc/kafka/secrets/kafka.server.truststore.jks
ssl.truststore.password=changeit
ssl.endpoint.identification.algorithm=

sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler

sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \\
  clientId='kafka-broker' \\
  clientSecret='${BROKER_SECRET}' \\
  scope='profile email';
EOF

cat > kafka-config/producer.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.oauthbearer.token.endpoint.url=http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token

ssl.truststore.location=/etc/kafka/secrets/kafka.server.truststore.jks
ssl.truststore.password=changeit
ssl.endpoint.identification.algorithm=

sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler

sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \\
  clientId='kafka-producer' \\
  clientSecret='${PRODUCER_SECRET}' \\
  scope='profile email';
EOF

cat > kafka-config/consumer.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.oauthbearer.token.endpoint.url=http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token

ssl.truststore.location=/etc/kafka/secrets/kafka.server.truststore.jks
ssl.truststore.password=changeit
ssl.endpoint.identification.algorithm=

sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler

sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \\
  clientId='kafka-consumer' \\
  clientSecret='${CONSUMER_SECRET}' \\
  scope='profile email';
EOF

echo -e "${GREEN}✓ Client property files generated${NC}"

# Test token retrieval
echo -e "${YELLOW}Testing token retrieval...${NC}"

for CLIENT_ID in "kafka-broker" "kafka-producer" "kafka-consumer"; do
    if [ "$CLIENT_ID" == "kafka-broker" ]; then
        SECRET=$BROKER_SECRET
    elif [ "$CLIENT_ID" == "kafka-producer" ]; then
        SECRET=$PRODUCER_SECRET
    else
        SECRET=$CONSUMER_SECRET
    fi

    TOKEN=$(curl -s -X POST "http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials" \
        -d "client_id=${CLIENT_ID}" \
        -d "client_secret=${SECRET}" | jq -r '.access_token')

    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        echo -e "${GREEN}✓ Token retrieved for ${CLIENT_ID}${NC}"

        # Decode and verify token (optional but helpful)
        PAYLOAD=$(echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq . || echo "Could not decode")
        echo "  Token claims: azp=$(echo $PAYLOAD | jq -r '.azp 2>/dev/null || echo "N/A"')"
    else
        echo -e "${RED}✗ Failed to get token for ${CLIENT_ID}${NC}"
    fi
done

echo ""
echo -e "${GREEN}======================================"
echo "Keycloak setup completed!"
echo "======================================${NC}"
echo ""
echo "Client Secrets:"
echo "  kafka-broker:   ${BROKER_SECRET}"
echo "  kafka-producer: ${PRODUCER_SECRET}"
echo "  kafka-consumer: ${CONSUMER_SECRET}"
echo ""
echo "Configuration files generated:"
echo "  - .env"
echo "  - kafka-config/admin.properties"
echo "  - kafka-config/producer.properties"
echo "  - kafka-config/consumer.properties"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Run: ./scripts/init-kafka.sh"
echo "  2. Run: docker-compose up -d kafka-controller kafka-broker"
