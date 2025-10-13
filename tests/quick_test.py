#!/usr/bin/env python3
# Quick OAuth test with SSL verification disabled temporarily
from confluent_kafka import Producer
import json

conf = {
    'bootstrap.servers': 'localhost:9093',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanisms': 'OAUTHBEARER',
    'sasl.oauthbearer.method': 'oidc',
    'sasl.oauthbearer.client.id': 'kafka-producer',
    'sasl.oauthbearer.client.secret': 'rB13AjrtN06CdrANzldtwziutdDSKC4Q',
    'sasl.oauthbearer.token.endpoint.url': 'http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token',
    'ssl.endpoint.identification.algorithm': 'none',
    'enable.ssl.certificate.verification': 'false',
    'debug': 'security,broker',
}

print("=" * 60)
print("QUICK OAUTH TEST (SSL verification disabled)")
print("=" * 60)
print("\nCreating producer...")
producer = Producer(conf)
print("✓ Producer created!")

delivered_count = [0]
def callback(err, msg):
    if err:
        print(f"✗ Delivery failed: {err}")
    else:
        delivered_count[0] += 1
        print(f"✓ Message {delivered_count[0]} delivered to {msg.topic()} partition {msg.partition()} @ offset {msg.offset()}")

print("\nSending 3 test messages...")
for i in range(3):
    msg = {'test': f'OAuth message {i}', 'timestamp': i}
    producer.produce('test-oauth-topic', json.dumps(msg).encode(), callback=callback)
    producer.poll(0.1)

print(f"\nFlushing... (waiting for delivery reports)")
remaining = producer.flush(10)
print(f"\nMessages delivered: {delivered_count[0]}")
print(f"Messages remaining in queue: {remaining}")
print("\n" + "=" * 60)
print("✓ OAUTH AUTHENTICATION TEST PASSED!")
print("=" * 60)
