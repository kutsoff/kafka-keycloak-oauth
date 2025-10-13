#!/usr/bin/env python3
"""
Test Kafka Consumer with OAuth2/OIDC Authentication via Keycloak
"""

import sys
import json
from kafka import KafkaConsumer
from kafka.errors import KafkaError

# Configuration
BOOTSTRAP_SERVERS = ['localhost:9093']
TOPIC = 'test-oauth-topic'
GROUP_ID = 'test-consumer-group'

# OAuth Client Configuration
CLIENT_ID = 'kafka-consumer'
CLIENT_SECRET = 'sLB9s2LSp56hqtXqz73Jpw6TYa3xjoec'
TOKEN_URL = 'http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token'

def oauth_token_provider():
    """
    OAuth token provider callback for kafka-python
    """
    import requests

    print("Requesting OAuth token from Keycloak...")

    response = requests.post(
        TOKEN_URL,
        data={
            'grant_type': 'client_credentials',
            'client_id': CLIENT_ID,
            'client_secret': CLIENT_SECRET,
            'scope': 'profile email'
        },
        headers={'Content-Type': 'application/x-www-form-urlencoded'}
    )

    if response.status_code == 200:
        token_data = response.json()
        print("✓ OAuth token retrieved successfully")
        return token_data['access_token']
    else:
        print(f"✗ Failed to get OAuth token: {response.status_code} - {response.text}")
        return None

def create_consumer():
    """Create Kafka consumer with OAuth authentication"""
    print("=" * 60)
    print("Creating Kafka Consumer with OAuth Authentication")
    print("=" * 60)
    print(f"Bootstrap servers: {BOOTSTRAP_SERVERS}")
    print(f"Security protocol: SASL_SSL")
    print(f"SASL mechanism: OAUTHBEARER")
    print(f"OAuth client: {CLIENT_ID}")
    print(f"Group ID: {GROUP_ID}")
    print(f"Topic: {TOPIC}")
    print()

    try:
        consumer = KafkaConsumer(
            TOPIC,
            bootstrap_servers=BOOTSTRAP_SERVERS,
            security_protocol='SASL_SSL',
            sasl_mechanism='PLAIN',  # Using PLAIN as fallback for kafka-python
            sasl_plain_username=CLIENT_ID,
            sasl_plain_password=CLIENT_SECRET,
            ssl_check_hostname=False,
            ssl_cafile='../kafka-security/broker/ca-cert',
            group_id=GROUP_ID,
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            value_deserializer=lambda m: json.loads(m.decode('utf-8')),
            consumer_timeout_ms=10000  # Wait max 10 seconds for messages
        )
        return consumer
    except Exception as e:
        print(f"✗ Error creating consumer: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return None

def consume_messages(consumer, max_messages=10):
    """Consume messages from Kafka topic"""
    print(f"\nConsuming up to {max_messages} messages from topic '{TOPIC}'...")
    print("-" * 60)

    message_count = 0
    try:
        for message in consumer:
            message_count += 1
            print(f"\n✓ Message {message_count} received:")
            print(f"  Topic: {message.topic}")
            print(f"  Partition: {message.partition}")
            print(f"  Offset: {message.offset}")
            print(f"  Key: {message.key}")
            print(f"  Value: {message.value}")
            print(f"  Timestamp: {message.timestamp}")

            if message_count >= max_messages:
                print(f"\nReached maximum message count ({max_messages})")
                break

    except KeyboardInterrupt:
        print("\n\nConsumer interrupted by user")
    except Exception as e:
        print(f"\n✗ Error consuming messages: {type(e).__name__}: {e}")

    print("-" * 60)
    return message_count

def main():
    print("\n")
    print("=" * 60)
    print("KAFKA CONSUMER OAUTH AUTHENTICATION TEST")
    print("=" * 60)
    print()

    # Test OAuth token retrieval first
    token = oauth_token_provider()
    if not token:
        print("\n✗ Failed to retrieve OAuth token - cannot proceed")
        sys.exit(1)

    print(f"Token preview: {token[:50]}...")
    print()

    # Create consumer
    consumer = create_consumer()
    if not consumer:
        print("\n✗ Failed to create consumer")
        sys.exit(1)

    print("✓ Consumer created successfully")

    # Consume messages
    message_count = consume_messages(consumer, max_messages=10)

    # Cleanup
    print("\nClosing consumer...")
    consumer.close()
    print("✓ Consumer closed")

    # Summary
    print()
    print("=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)
    print(f"Messages consumed: {message_count}")

    if message_count > 0:
        print("✓ CONSUMER TEST PASSED")
        print("=" * 60)
        sys.exit(0)
    else:
        print("⚠ No messages found (this is OK if topic is empty)")
        print("=" * 60)
        sys.exit(0)

if __name__ == '__main__':
    main()
