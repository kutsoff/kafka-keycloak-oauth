#!/bin/bash
# Fix audience mapper for Keycloak OAuth clients

set -e

KEYCLOAK_URL="http://localhost:8080"
REALM_NAME="kafka-realm"

echo "Getting admin token..."
ADMIN_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin123" \
    -d "grant_type=password" | jq -r '.access_token')

echo "Token acquired"

# Function to add audience mapper
add_audience_mapper() {
    local CLIENT_ID=$1
    echo "Processing client: ${CLIENT_ID}"

    # Get client internal ID
    CLIENT_UUID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" | \
        jq -r ".[] | select(.clientId==\"${CLIENT_ID}\") | .id")

    echo "Client UUID: ${CLIENT_UUID}"

    # Add audience mapper to client
    echo "Adding audience mapper..."
    curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/protocol-mappers/models" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"kafka-broker-audience\",
            \"protocol\": \"openid-connect\",
            \"protocolMapper\": \"oidc-audience-mapper\",
            \"consentRequired\": false,
            \"config\": {
                \"included.client.audience\": \"kafka-broker\",
                \"id.token.claim\": \"false\",
                \"access.token.claim\": \"true\"
            }
        }"

    echo "✓ Audience mapper added for ${CLIENT_ID}"
    echo
}

# Add for all clients
add_audience_mapper "kafka-producer"
add_audience_mapper "kafka-consumer"
add_audience_mapper "kafka-broker"

echo "Done! Test with:"
echo "curl -X POST http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token \\"
echo "  -d 'grant_type=client_credentials' \\"
echo "  -d 'client_id=kafka-producer' \\"
echo "  -d 'client_secret=JcR4yefw4xJ8es02jIWtdzTHVb98PFU0'"
