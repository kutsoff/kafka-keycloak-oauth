#!/bin/bash
set -e

echo "======================================"
echo "Kafka KRaft Storage Initialization"
echo "======================================"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cd "$(dirname "$0")/.."

# Load environment variables
if [ -f .env ]; then
    set -a  # automatically export all variables
    source <(grep -v '^#' .env | grep -v '^$' | grep '=' | sed 's/\x1b\[[0-9;]*m//g')
    set +a
    echo -e "${YELLOW}Loaded environment variables from .env${NC}"
else
    echo -e "${YELLOW}Warning: .env file not found, using defaults${NC}"
    export CLUSTER_ID="kafka-cluster-01"
fi

echo -e "${YELLOW}Initializing KRaft storage for controller...${NC}"

docker run --rm \
    -v $(pwd)/kafka-security/broker:/etc/kafka/secrets:ro \
    -v kafka-controller-metadata:/var/lib/kafka/metadata \
    apache/kafka:${KAFKA_VERSION:-4.1.0} \
    bash -c "
        if [ ! -f /var/lib/kafka/metadata/__cluster_metadata-0/00000000000000000000.log ]; then
            kafka-storage.sh format \
                -t ${CLUSTER_ID} \
                -c /opt/kafka/config/kraft/controller.properties \
                --standalone
            echo 'Controller storage formatted'
        else
            echo 'Controller storage already formatted'
        fi
    "

echo -e "${GREEN}✓ Controller storage initialized${NC}"

echo -e "${YELLOW}Initializing KRaft storage for broker...${NC}"

docker run --rm \
    -v $(pwd)/kafka-security/broker:/etc/kafka/secrets:ro \
    -v kafka-broker-metadata:/var/lib/kafka/metadata \
    apache/kafka:${KAFKA_VERSION:-4.1.0} \
    bash -c "
        if [ ! -f /var/lib/kafka/metadata/__cluster_metadata-0/00000000000000000000.log ]; then
            kafka-storage.sh format \
                -t ${CLUSTER_ID} \
                -c /opt/kafka/config/kraft/broker.properties \
                --standalone
            echo 'Broker storage formatted'
        else
            echo 'Broker storage already formatted'
        fi
    "

echo -e "${GREEN}✓ Broker storage initialized${NC}"

echo ""
echo -e "${GREEN}======================================"
echo "KRaft storage initialization complete!"
echo "======================================${NC}"
echo ""
echo -e "${YELLOW}Next step:${NC}"
echo "  Run: docker-compose up -d kafka-controller kafka-broker"
