# Apache Kafka 4.1.0 с аутентификацией Keycloak OAuth2

**Это форк репозитория [oriolrius/kafka-keycloak-oauth](https://github.com/oriolrius/kafka-keycloak-oauth), в котором исправлены ошибки при запуске скриптов инициализации.**

Production-ready Apache Kafka 4.1.0 (режим KRaft) с аутентификацией Keycloak 26.1.1 OAuth2/OIDC с использованием образа Strimzi Kafka.

## Почему этот проект vs [kafka-oauth-keycloak-tls-demo](https://github.com/oriolrius/kafka-oauth-keycloak-tls-demo)

Это **эволюция** предыдущего POC со значительными улучшениями:

- **Strimzi OAuth 0.17.0** (вместо 1.0.0) - стабильная production версия, встроенная в образ Strimzi Kafka 0.48.0
- **Не требуется кастомная сборка Docker** - использует официальный образ Strimzi с предустановленным OAuth, устраняет сложность Dockerfile
- **Учет CVE-2025-27817** - документирует ограничения URL allowlist и почему Strimzi OAuth их обходит
- **Упрощенная архитектура** - один комбинированный режим KRaft (broker+controller), не разделенная архитектура
- **Фокус на клиентах librdkafka** - протестировано с confluent-kafka-python (работает без проблем URL allowlist), не нативные Java клиенты
- **Комплексная техническая документация** - production чеклист, устранение неполадок, настройка производительности, детали маппинга principal
- **Упрощенное управление сертификатами** - включены примеры сертификатов для немедленного тестирования
- **Автоматизированная настройка Keycloak** - скриптовое создание realm/client/mapper с конфигурацией audience
- **Рабочий набор Python тестов** - проверяет OAuth end-to-end доставку сообщений
- **Явная обработка URL issuer** - документирует дуальность внутренних и внешних URL для token endpoint vs валидации issuer

## Архитектура

- **Дистрибутив Kafka**: Образ Strimzi Kafka 0.48.0 (включает Apache Kafka 4.1.0 + Strimzi OAuth 0.17.0 предустановленный)
- **Версия Kafka**: Apache Kafka 4.1.0 (KRaft комбинированный broker+controller)
- **Библиотека OAuth**: Strimzi Kafka OAuth 0.17.0 (встроена в образ, обходит ограничения URL allowlist CVE-2025-27817)
- **Провайдер OAuth**: Keycloak 26.1.1
- **Безопасность**: SASL_SSL (OAuth) для внешних клиентов, PLAINTEXT для inter-broker, SSL с самоподписанным CA

## Контекст CVE-2025-27817

Apache Kafka 4.0.0+ ввел URL allowlist (`org.apache.kafka.sasl.oauthbearer.allowed.urls`) как системное свойство JVM для исправления уязвимости SSRF/произвольного чтения файлов. Это нарушает стандартное использование OAuth в нативных клиентах Apache Kafka.

**Решение**: Библиотека Strimzi Kafka OAuth не реализует это ограничение, обеспечивая функциональность OAuth с Kafka 4.1.0.

## Предварительные требования

- Docker Compose
- Python 3.x с uv (для тестирования)
- OpenSSL (для генерации сертификатов)

## Быстрый старт

```bash
# Генерация SSL сертификатов
cd kafka-security
./generate-certs.sh
cd ..

# Запуск сервисов
docker compose up -d

# Проверка Keycloak
curl http://localhost:8080/health/ready

# Настройка realm и клиентов Keycloak
./scripts/setup-keycloak.sh

# Тестирование OAuth producer
source ~/.venv/bin/activate
uv pip install confluent-kafka
python tests/quick_test.py
```

## Сетевая топология

```
keycloak:8080 (HTTP) ←→ kafka-broker:9093 (SASL_SSL/OAuth)
                      ↔ kafka-broker:19092 (PLAINTEXT/inter-broker)
                      ↔ kafka-broker:29093 (PLAINTEXT/KRaft controller)
```

## Конфигурация SSL

### Структура CA
- **Root CA**: `kafka-security/ca-cert` + `ca-key`
- **Keystore брокера**: `kafka-security/broker/kafka.server.keystore.jks` (содержит серверный сертификат + приватный ключ)
- **Truststore брокера**: `kafka-security/broker/kafka.server.truststore.jks` (содержит сертификат CA)
- **Пароль**: `changeit` (все keystores/truststores)

### Детали сертификата
```bash
# Сертификат брокера
CN=kafka-broker
SAN=DNS:kafka-broker,DNS:localhost,IP:127.0.0.1

# Срок действия: 3650 дней
# Алгоритм ключа: RSA 2048-bit
# Алгоритм подписи: SHA256withRSA
```

## Конфигурация Keycloak OAuth

### Realm: kafka-realm

#### Клиенты

**kafka-broker** (конфиденциальный)
- Client ID: `kafka-broker`
- Client Secret: Автогенерируется `setup-keycloak.sh`
- Назначение: OAuth аутентификация broker inter-broker
- Mappers:
  - Audience mapper: добавляет `kafka-broker` в JWT claim `aud`
  - Username mapper: включает `preferred_username` в токен

**kafka-producer** (конфиденциальный)
- Client ID: `kafka-producer`
- Client Secret: Автогенерируется
- Назначение: Внешние producer клиенты
- Grant: `client_credentials`
- Mappers: То же что и kafka-broker

**kafka-consumer** (конфиденциальный)
- Client ID: `kafka-consumer`
- Client Secret: Автогенерируется
- Назначение: Внешние consumer клиенты
- Grant: `client_credentials`
- Mappers: То же что и kafka-broker

### Token Endpoint
```
POST http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=kafka-producer
&client_secret=<secret>
&scope=profile email
```

### Структура JWT токена
```json
{
  "aud": ["kafka-broker", "account"],
  "iss": "http://localhost:8080/realms/kafka-realm",
  "azp": "kafka-producer",
  "preferred_username": "service-account-kafka-producer",
  "scope": "profile email"
}
```

## Конфигурация Kafka

### Режим KRaft (kraft-config.properties)

```properties
# Node identity
node.id=1
process.roles=broker,controller
controller.quorum.voters=1@kafka-broker:29093

# Listeners
listeners=SASL_SSL://0.0.0.0:9093,PLAINTEXT://0.0.0.0:19092,CONTROLLER://0.0.0.0:29093
advertised.listeners=SASL_SSL://localhost:9093,PLAINTEXT://kafka-broker:19092
listener.security.protocol.map=SASL_SSL:SASL_SSL,PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER

# SASL mechanism
sasl.enabled.mechanisms=OAUTHBEARER

# Strimzi OAuth handlers (per-listener for SASL_SSL)
listener.name.sasl_ssl.oauthbearer.sasl.login.callback.handler.class=io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler
listener.name.sasl_ssl.oauthbearer.sasl.server.callback.handler.class=io.strimzi.kafka.oauth.server.JaasServerOauthValidatorCallbackHandler

# OAuth configuration via JAAS
listener.name.sasl_ssl.oauthbearer.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \
  oauth.client.id="kafka-broker" \
  oauth.client.secret="<secret>" \
  oauth.token.endpoint.uri="http://keycloak:8080/realms/kafka-realm/protocol/openid-connect/token" \
  oauth.valid.issuer.uri="http://localhost:8080/realms/kafka-realm" \
  oauth.jwks.endpoint.uri="http://keycloak:8080/realms/kafka-realm/protocol/openid-connect/certs" \
  oauth.username.claim="preferred_username";
```

### Ключевые параметры Strimzi OAuth

- `oauth.client.id`: Идентификатор клиента для получения токена
- `oauth.client.secret`: Секрет клиента для получения токена
- `oauth.token.endpoint.uri`: Token endpoint Keycloak (брокер использует внутреннее имя хоста `keycloak:8080`)
- `oauth.valid.issuer.uri`: Ожидаемый JWT issuer (должен соответствовать токену claim `iss`, использует внешний `localhost:8080`)
- `oauth.jwks.endpoint.uri`: JWKS endpoint для валидации подписи JWT
- `oauth.username.claim`: JWT claim для извлечения principal

### Авторизация

```properties
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
super.users=User:kafka-broker;User:ANONYMOUS
allow.everyone.if.no.acl.found=true
```

**Примечание**: Сейчас эта конфигурация допустима для тестирования, однако в production следует использовать ACL.

## Конфигурация клиентов

### Python Producer (confluent-kafka)

```python
from confluent_kafka import Producer

conf = {
    'bootstrap.servers': 'localhost:9093',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanisms': 'OAUTHBEARER',
    'sasl.oauthbearer.method': 'oidc',
    'sasl.oauthbearer.client.id': 'kafka-producer',
    'sasl.oauthbearer.client.secret': '<secret>',
    'sasl.oauthbearer.token.endpoint.url': 'http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token',
    'ssl.ca.location': 'kafka-security/ca-cert',
    'ssl.endpoint.identification.algorithm': 'none',
}

producer = Producer(conf)
producer.produce('topic', b'message')
producer.flush()
```

### Python Consumer (confluent-kafka)

```python
from confluent_kafka import Consumer

conf = {
    'bootstrap.servers': 'localhost:9093',
    'group.id': 'test-group',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanisms': 'OAUTHBEARER',
    'sasl.oauthbearer.method': 'oidc',
    'sasl.oauthbearer.client.id': 'kafka-consumer',
    'sasl.oauthbearer.client.secret': '<secret>',
    'sasl.oauthbearer.token.endpoint.url': 'http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token',
    'ssl.ca.location': 'kafka-security/ca-cert',
    'ssl.endpoint.identification.algorithm': 'none',
    'auto.offset.reset': 'earliest',
}

consumer = Consumer(conf)
consumer.subscribe(['topic'])
while True:
    msg = consumer.poll(1.0)
    if msg: print(msg.value())
```

### Почему работает librdkafka

confluent-kafka-python использует librdkafka (библиотека C), которая реализует OAuth через `sasl.oauthbearer.method=oidc`. Эта реализация не проверяет системное свойство `org.apache.kafka.sasl.oauthbearer.allowed.urls`, которое блокирует нативные клиенты Apache Kafka Java.

## Устранение неполадок

### Проверка OAuth токена

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/realms/kafka-realm/protocol/openid-connect/token \
  -d "grant_type=client_credentials" \
  -d "client_id=kafka-producer" \
  -d "client_secret=<secret>" | jq -r .access_token)

echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

Ожидаемые claims:
```json
{
  "aud": ["kafka-broker", "account"],
  "iss": "http://localhost:8080/realms/kafka-realm",
  "azp": "kafka-producer",
  "preferred_username": "service-account-kafka-producer"
}
```

### Проверка логов OAuth брокера

```bash
docker logs kafka-broker 2>&1 | grep -E "Strimzi|JWTSignatureValidator|OAUTHBEARER"
```

Expected:
```
[io.strimzi.kafka.oauth.validator.JWTSignatureValidator] JWKS keys change detected
```

### Проверка клиентов брокера

```bash
docker exec kafka-broker netstat -tlnp | grep java
```

Ожидаемое:
```
tcp6  0.0.0.0:9093   LISTEN  (SASL_SSL)
tcp6  0.0.0.0:19092  LISTEN  (PLAINTEXT)
tcp6  0.0.0.0:29093  LISTEN  (CONTROLLER)
```

### Проверка метаданных KRaft

```bash
docker exec kafka-broker cat /var/lib/kafka/data/meta.properties
```

Ожидаемое:
```
version=1
cluster.id=kafka-cluster-01
node.id=1
```

### Частые проблемы

**Проблема**: `{"status":"invalid_token"}`
- **Причина**: Ошибка валидации подписи JWT
- **Решение**: Проверьте, что `oauth.jwks.endpoint.uri` доступен из контейнера брокера
- **Проверка**: `docker exec kafka-broker curl http://keycloak:8080/realms/kafka-realm/protocol/openid-connect/certs`

**Проблема**: `Token audience mismatch`
- **Причина**: JWT claim `aud` не содержит `kafka-broker`
- **Решение**: Запустите `./scripts/setup-keycloak.sh` для добавления audience mapper
- **Проверка**: Декодируйте токен и проверьте, что claim `aud` включает `kafka-broker`

**Проблема**: `Token issuer mismatch`
- **Причина**: JWT `iss` не совпадает с `oauth.valid.issuer.uri`
- **Решение**: Убедитесь, что `oauth.valid.issuer.uri=http://localhost:8080/realms/kafka-realm` (внешнее имя хоста)
- **Примечание**: Брокер использует `http://keycloak:8080` для token endpoint, но валидирует против `http://localhost:8080` issuer

**Проблема**: Нативные Java клиенты Kafka падают с ошибкой URL allowlist
- **Причина**: Исправление CVE-2025-27817 в Apache Kafka 4.1.0
- **Решение**: Используйте клиенты на основе librdkafka (confluent-kafka-python) или Strimzi OAuth на стороне брокера (уже настроено)

## Настройка производительности

### Обновление токенов

JWT токены от Keycloak имеют срок действия 5 минут. Strimzi OAuth автоматически обрабатывает обновление:
- `oauth.refresh.token`: Не используется (grant client_credentials)
- Токен кэшируется и обновляется за 30 секунд до истечения

### Кэширование JWKS

```properties
sasl.oauthbearer.jwks.endpoint.refresh.ms=3600000  # 1 hour
sasl.oauthbearer.jwks.endpoint.retry.backoff.ms=100
sasl.oauthbearer.jwks.endpoint.retry.backoff.max.ms=10000
```

### Настройки соединения

```properties
connections.max.idle.ms=600000
connection.failed.authentication.delay.ms=1000
```

## Production чеклист

- [ ] Заменить самоподписанные сертификаты на подписанные CA
- [ ] Обновить `ssl.endpoint.identification.algorithm=https` (убрать `none`)
- [ ] Настроить правильные ACL (убрать `allow.everyone.if.no.acl.found=true`)
- [ ] Настроить ACL:
  ```bash
  kafka-acls --bootstrap-server localhost:9093 \
    --command-config admin.properties \
    --add --allow-principal User:kafka-producer \
    --operation Write --topic '*'
  ```
- [ ] Ротация секретов клиентов Keycloak
- [ ] Включить HTTPS для Keycloak
- [ ] Обновить `oauth.token.endpoint.uri` и `oauth.jwks.endpoint.uri` на HTTPS URL
- [ ] Настроить мониторинг Kafka (JMX, Prometheus)
- [ ] Настроить агрегацию логов для аудита OAuth
- [ ] Протестировать сценарии отказоустойчивости
- [ ] Документировать процедуры ротации секретов
- [ ] Включить федерацию пользователей Keycloak (LDAP/AD) при необходимости

## Структура каталогов

```
.
├── docker-compose.yml              # Оркестрация
├── .env                            # Секреты (в gitignore)
├── kafka-config/
│   ├── kraft-config.properties     # Конфигурация брокера Kafka
│   ├── producer.properties         # Конфигурация OAuth для producer (для CLI инструментов)
│   └── consumer.properties         # Конфигурация OAuth для consumer (для CLI инструментов)
├── kafka-security/
│   ├── generate-certs.sh           # Генератор SSL сертификатов
│   ├── ca-cert                     # Сертификат корневого CA
│   ├── ca-key                      # Приватный ключ корневого CA
│   └── broker/
│       ├── kafka.server.keystore.jks
│       └── kafka.server.truststore.jks
├── scripts/
│   └── setup-keycloak.sh           # Настройка realm/client Keycloak
└── tests/
    └── quick_test.py               # Тест валидации OAuth

```

## Технические примечания

### Почему образ Strimzi Kafka вместо официального образа Apache Kafka

Образ Strimzi Kafka (`quay.io/strimzi/kafka:0.48.0-kafka-4.1.0`) используется вместо официального образа Apache Kafka потому что:

1. **Встроенная поддержка OAuth**: Включает предустановленную библиотеку Strimzi OAuth 0.17.0 (классы: `io.strimzi.kafka.oauth.*`)
2. **Обход CVE-2025-27817**: Библиотека Strimzi OAuth не реализует ограничение URL allowlist, которое нарушает нативный OAuth Kafka
3. **Готовность к production**: Проверена в боевых условиях в Kubernetes окружениях через Strimzi Operator
4. **Единый образ**: Не требуется вручную скачивать и монтировать JAR файлы OAuth

**Разбор образа**:
- Strimzi Kafka **0.48.0** = версия/релиз Docker образа
- Apache Kafka **4.1.0** = версия брокера Kafka внутри
- Strimzi OAuth **0.17.0** = версия библиотеки OAuth внутри

### URL Issuer

Конфигурация брокера содержит два URL:
- `oauth.token.endpoint.uri=http://keycloak:8080/...` (внутренняя Docker сеть)
- `oauth.valid.issuer.uri=http://localhost:8080/...` (внешний, соответствует JWT claim `iss`)

Это потому что:
- Брокер получает токены используя внутреннее DNS имя
- Keycloak выпускает токены с внешним issuer URL (настроено в настройках realm)
- Валидация JWT требует точного совпадения issuer

### Маппинг Principal

Брокер извлекает principal из JWT claim `preferred_username`:
```
service-account-kafka-producer → User:service-account-kafka-producer
```

ACL ссылаются на этот principal для авторизации.

## Совместимость версий

| Компонент | Версия | Примечания |
|-----------|--------|------------|
| Apache Kafka | 4.1.0 | Режим KRaft (без ZooKeeper) |
| Образ Strimzi Kafka | 0.48.0 | Docker образ: `quay.io/strimzi/kafka:0.48.0-kafka-4.1.0` |
| Библиотека Strimzi OAuth | 0.17.0 | Предустановлена в образе Strimzi Kafka 0.48.0 |
| Keycloak | 26.1.1 | Последняя LTS |
| librdkafka | 2.12.0+ | Поддержка OIDC OAuth |
| confluent-kafka-python | 2.12.0+ | Соответствует версии librdkafka |

## Ссылки

- [Strimzi Kafka OAuth](https://github.com/strimzi/strimzi-kafka-oauth)
- [Безопасность Apache Kafka](https://kafka.apache.org/documentation/#security)
- [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/#_oidc)
- [CVE-2025-27817](https://nvd.nist.gov/vuln/detail/CVE-2025-27817)
- [Режим KRaft](https://kafka.apache.org/documentation/#kraft)
