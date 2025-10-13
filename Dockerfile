FROM apache/kafka:4.1.0

USER root

# Fix the configure script to disable set -u which causes issues with indirect variable expansion
RUN sed -i '1a set +u' /etc/kafka/docker/configure && \
    chmod +x /etc/kafka/docker/configure

# Install Strimzi OAuth library for proper OIDC/JWT token validation
# Apache Kafka 4.1's native OAuth doesn't properly validate external OIDC tokens
COPY strimzi-oauth/*.jar /opt/kafka/libs/

USER appuser
