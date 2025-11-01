#!/usr/bin/env python3
"""
Test Kafka Producer with OAuth2/OIDC Authentication via Keycloak
Uses confluent-kafka-python which supports OAUTHBEARER properly
"""

import sys
import json
import time
import requests
from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient, NewTopic

# Configuration
BOOTSTRAP_SERVERS = 'localhost:9093'
TOPIC = 'test-oauth-topic'

# OAuth Client Configuration
CLIENT_ID = 'kafka-producer'
CLIENT_SECRET = 'fv4EcRCKbt1ZkIe9shTWbPANuj7DXRgj'
TOKEN_URL = 'http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token'

# Use absolute path for CA certificate
import os
CA_CERT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '../kafka-security/ca/ca-cert.pem'))

def oauth_cb(oauth_config):
    """
    OAuth callback for confluent-kafka
    This function is called by the Kafka client to retrieve OAuth tokens
    """
    try:
        response = requests.post(
            TOKEN_URL,
            data={
                'grant_type': 'client_credentials',
                'client_id': CLIENT_ID,
                'client_secret': CLIENT_SECRET,
                #'scope': 'profile email'
            },
            headers={'Content-Type': 'application/x-www-form-urlencoded'}
        )

        if response.status_code == 200:
            token_data = response.json()
            return token_data['access_token'], time.time() + token_data['expires_in']
        else:
            print(f"✗ Failed to get OAuth token: {response.status_code}")
            return "", 0
    except Exception as e:
        print(f"✗ OAuth callback error: {e}")
        return "", 0

def create_topic_if_not_exists():
    """Create topic if it doesn't exist"""
    print(f"Checking if topic '{TOPIC}' exists...")

    admin_conf = {
        'bootstrap.servers': [BOOTSTRAP_SERVERS],
        'security.protocol': 'SASL_SSL',
        'sasl.mechanisms': 'OAUTHBEARER',
        'sasl.oauthbearer.method': 'oidc',
        'sasl.oauthbearer.client.id': CLIENT_ID,
        'sasl.oauthbearer.client.secret': CLIENT_SECRET,
        'sasl.oauthbearer.token.endpoint.url': TOKEN_URL,
        #'sasl.oauthbearer.scope': 'profile email',
        'ssl.ca.location': CA_CERT_PATH,
        'ssl.endpoint.identification.algorithm': 'none',
        'oauth_cb': oauth_cb
    }

    try:
        admin = AdminClient(admin_conf)

        # Check if topic exists
        metadata = admin.list_topics(timeout=10)
        if TOPIC in metadata.topics:
            print(f"✓ Topic '{TOPIC}' already exists")
            return True

        # Create topic
        print(f"Creating topic '{TOPIC}'...")
        topic = NewTopic(TOPIC, num_partitions=3, replication_factor=1)
        fs = admin.create_topics([topic])

        for topic_name, f in fs.items():
            try:
                f.result()  # Wait for operation to complete
                print(f"✓ Topic '{topic_name}' created successfully")
                return True
            except Exception as e:
                print(f"✗ Failed to create topic: {e}")
                return False

    except Exception as e:
        print(f"✗ Error with admin client: {e}")
        return False

def create_producer():
    """Create Kafka producer with OAuth authentication"""
    print("\n" + "=" * 60)
    print("Creating Kafka Producer with OAuth Authentication")
    print("=" * 60)
    print(f"Bootstrap servers: {BOOTSTRAP_SERVERS}")
    print(f"Security protocol: SASL_SSL")
    print(f"SASL mechanism: OAUTHBEARER")
    print(f"OAuth client: {CLIENT_ID}")
    print()

    conf = {
        'bootstrap.servers': BOOTSTRAP_SERVERS,
        'security.protocol': 'SASL_SSL',
        'sasl.mechanisms': 'OAUTHBEARER',
        'sasl.oauthbearer.method': 'oidc',
        'sasl.oauthbearer.client.id': CLIENT_ID,
        'sasl.oauthbearer.client.secret': CLIENT_SECRET,
        'sasl.oauthbearer.token.endpoint.url': TOKEN_URL,
        'sasl.oauthbearer.scope': 'profile email',
        'ssl.ca.location': CA_CERT_PATH,
        'ssl.endpoint.identification.algorithm': 'none',
        'client.id': 'python-producer-test',
        'oauth_cb': oauth_cb,
    }

    try:
        producer = Producer(conf)
        print("✓ Producer created successfully")
        return producer
    except Exception as e:
        print(f"✗ Error creating producer: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return None

def delivery_report(err, msg):
    """Callback for message delivery reports"""
    if err is not None:
        print(f"✗ Message delivery failed: {err}")
    else:
        print(f"✓ Message delivered to {msg.topic()} [{msg.partition()}] @ offset {msg.offset()}")

def send_test_messages(producer, num_messages=5):
    """Send test messages to Kafka topic"""
    print(f"\nSending {num_messages} test messages to topic '{TOPIC}'...")
    print("-" * 60)

    for i in range(num_messages):
        message = {
            'message_id': i,
            'timestamp': time.time(),
            'content': f'Test message {i} with OAuth authentication',
            'producer_client': CLIENT_ID
        }

        try:
            # Produce message
            producer.produce(
                TOPIC,
                key=f'key-{i}'.encode('utf-8'),
                value=json.dumps(message).encode('utf-8'),
                callback=delivery_report
            )

            # Trigger delivery report callbacks
            producer.poll(0)

        except BufferError:
            print(f"⚠ Buffer full for message {i}, waiting...")
            producer.poll(1)
            producer.produce(TOPIC, key=f'key-{i}'.encode('utf-8'), value=json.dumps(message).encode('utf-8'), callback=delivery_report)
        except Exception as e:
            print(f"✗ Error producing message {i}: {e}")

    # Wait for all messages to be delivered
    print("\nFlushing remaining messages...")
    outstanding = producer.flush(timeout=10)
    if outstanding > 0:
        print(f"⚠ {outstanding} messages were not delivered")
        return False

    print("-" * 60)
    return True

def main():
    print("\n")
    print("=" * 60)
    print("KAFKA PRODUCER OAUTH AUTHENTICATION TEST")
    print("=" * 60)
    print()

    # Test OAuth token retrieval first
    print("Testing OAuth token retrieval...")
    try:
        response = requests.post(
            TOKEN_URL,
            data={
                'grant_type': 'client_credentials',
                'client_id': CLIENT_ID,
                'client_secret': CLIENT_SECRET,
                'scope': 'profile email'
            }
        )
        if response.status_code == 200:
            token_data = response.json()
            print(f"✓ OAuth token retrieved successfully")
            print(f"  Token preview: {token_data['access_token'][:50]}...")
            print(f"  Expires in: {token_data['expires_in']} seconds")
        else:
            print(f"✗ Failed to get token: {response.status_code}")
            sys.exit(1)
    except Exception as e:
        print(f"✗ Token retrieval error: {e}")
        sys.exit(1)

    print()

    # Create topic
    if not create_topic_if_not_exists():
        print("\n⚠ Warning: Could not verify/create topic, continuing anyway...")

    # Create producer
    producer = create_producer()
    if not producer:
        print("\n✗ Failed to create producer")
        sys.exit(1)

    # Send messages
    success = send_test_messages(producer, num_messages=5)

    # Summary
    print()
    print("=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)

    if success:
        print("✓ ALL TESTS PASSED - Producer with OAuth working!")
        print("=" * 60)
        sys.exit(0)
    else:
        print("✗ SOME TESTS FAILED")
        print("=" * 60)
        sys.exit(1)

if __name__ == '__main__':
    main()
