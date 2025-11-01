#!/usr/bin/env python3
"""
Test Kafka Consumer with OAuth2/OIDC Authentication via Keycloak
"""

import sys
import json
from confluent_kafka import Consumer, KafkaError

# Configuration
BOOTSTRAP_SERVERS = ['localhost:9093']
TOPIC = 'test-oauth-topic'
GROUP_ID = 'oauth-cb-test-group'

# OAuth Client Configuration
CLIENT_ID = 'kafka-consumer'
CLIENT_SECRET = 'b3NfEwx8a477nTmqh9kJQ9SODgAlGQuc'
TOKEN_URL = 'http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token'
import os
CA_CERT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '../kafka-security/ca/ca-cert.pem'))


def oauth_token_provider():
    """
    OAuth token provider callback for confluent-kafka
    """
    import requests

    print("🔑 oauth_token_provider() called - requesting OAuth token from Keycloak...")

    response = requests.post(
        TOKEN_URL,
        data={
            'grant_type': 'client_credentials',
            'client_id': CLIENT_ID,
            'client_secret': CLIENT_SECRET,
        },
        headers={'Content-Type': 'application/x-www-form-urlencoded'}
    )

    if response.status_code == 200:
        token_data = response.json()
        print("✓ OAuth token retrieved successfully in callback")
        print(f"Token preview: {token_data['access_token'][:50]}...")
        return token_data['access_token']
    else:
        error_msg = f"Failed to get OAuth token: {response.status_code} - {response.text}"
        print(f"✗ {error_msg}")
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
        conf = {
            'bootstrap.servers': ','.join(BOOTSTRAP_SERVERS),
            'group.id': GROUP_ID,
            'security.protocol': 'SASL_SSL',
            'sasl.mechanisms': 'OAUTHBEARER',
            'sasl.oauthbearer.method': 'oidc',
            'sasl.oauthbearer.client.id': CLIENT_ID,
            'sasl.oauthbearer.client.secret': CLIENT_SECRET,
            'sasl.oauthbearer.token.endpoint.url': TOKEN_URL,
            'ssl.ca.location': CA_CERT_PATH,
            'ssl.endpoint.identification.algorithm': 'none',
            'auto.offset.reset': 'earliest',
            'enable.auto.commit': True,
            'session.timeout.ms': 60000,
        }

        return Consumer(conf)
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
    poll_count = 0
    try:
        consumer.subscribe([TOPIC])
        print(f"✓ Subscribed to topic: {TOPIC}")
        while message_count < max_messages:
            poll_count += 1
            print(f"🔍 Polling attempt #{poll_count}...")
            msg = consumer.poll(1.0)
            if msg is None:
                print(f"⏱️ Poll #{poll_count}: No message received (timeout)")
                if poll_count >= 10:  # Прекращаем после 10 попыток
                    print("❌ Too many empty polls, stopping...")
                    break
                continue
                
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    print(f"📍 Конец раздела {msg.partition()}")
                    continue
                else:
                    print(f"❌ Ошибка: {msg.error()}")
                    continue

            message_count += 1
            message = msg.value().decode('utf-8') if msg.value() else None
            key = msg.key().decode('utf-8') if msg.key() else None
            
            print(f"\n✓ Message {message_count} received:")
            print(f"  Topic: {msg.topic()}")
            print(f"  Partition: {msg.partition()}")
            print(f"  Offset: {msg.offset()}")
            print(f"  Key: {key}")
            print(f"  Value: {message}")

        print(f"\nReached maximum message count ({max_messages})")

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
