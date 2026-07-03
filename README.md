# NORA: Разворачиваем свой artifact registry в Kubernetes на Yandex Cloud за 15 минут

## Введение

Каждый разработчик сталкивался с проблемой хранения артефактов: Docker-образы, npm-пакеты, Maven-артефакты, Python-колёсики. Вариантов обычно два — использовать публичные реестры (Docker Hub, npmjs.org, PyPI) или поднимать Nexus / Artifactory / Harbor. Публичные реестры ненадёжны из-за rate limit и блокировок, Nexus и Artifactory тяжёлые: Java, PostgreSQL, гигабайты RAM, десятки минут на старт.

[NORA](https://github.com/getnora-io/nora) — open-source реестр артефактов на Rust. Один бинарник < 27 МБ, < 50 МБ RAM в простое, старт за 3 секунды. Поддерживает 13 форматов: Docker, Maven, npm, PyPI, Cargo, Go, Raw, RubyGems, Terraform, Ansible Galaxy, NuGet, Pub (Dart/Flutter), Conan (C/C++). Плюс Helm-чарты через OCI.

В этой статье мы развернём NORA в Kubernetes на Yandex Managed Kubernetes с помощью Terraform и Helm, настроим ingress-nginx, выпустим TLS-сертификат через cert-manager, а затем попробуем все основные сценарии использования.

## NORA vs Nexus vs Artifactory vs Harbor

| Метрика | NORA | Nexus | JFrog Artifactory | Harbor |
|---------|------|-------|-------------------|--------|
| RAM (простой) | < 50 МБ | 2–4 ГБ | 2–4 ГБ | 2–4 ГБ |
| Время старта | < 3 сек | 30–60 сек | 30–60 сек | 30–60 сек |
| Зависимости | Нет | Java 11+ | Java 11+ | Go, PostgreSQL, Redis |
| База данных | Файловая система | OrientDB/PostgreSQL | OrientDB/PostgreSQL | PostgreSQL |
| Количество форматов | 13 | 30+ | 30+ | Docker, OCI, Helm, CNAB |
| S3-хранилище | Да | Платная версия | Платная версия | Да |
| Цена | MIT, бесплатно | Community бесплатно | Community бесплатно | Apache 2.0, бесплатно |
| Ключевые особенности | Бинарник на Rust, S3, карантин свежих пакетов, блокировка уязвимых пакетов по версиям | 30+ форматов, LDAP, репликация, плагины, Web UI, REST API | 30+ форматов, LDAP, репликация, плагины, Web UI, REST API, Xray (сканирование CVE) | Docker/OCI репестр, Helm charts, сканирование CVE, репликация, RBAC, Web UI |

NORA уступает Nexus/Artifactory/Harbor по количеству поддерживаемых форматов и enterprise-фичам (LDAP, репликация, встроенное сканирование CVE). Но для команд, которым нужен быстрый, лёгкий и бесплатный registry с основными форматами — это отличный выбор.

Отличительная особенность Nora это:

- **Min Release Age** — карантин свежих пакетов
- **CVE Blocking** — блокировка уязвимых пакетов по версии

## cert-manager: автоматические TLS-сертификаты

Для работы HTTPS с валидным TLS-сертификатом от Let's Encrypt нужен [cert-manager](https://cert-manager.io/). Он автоматически выпускает и обновляет сертификаты для Ingress-ресурсов.

### Установка cert-manager

```bash
# Добавляем Helm-репозиторий
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Устанавливаем cert-manager с CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Проверяем, что поды cert-manager запустились:

```bash
kubectl get pods -n cert-manager
# cert-manager-xxx            1/1     Running
# cert-manager-cainjector-xxx 1/1     Running
# cert-manager-webhook-xxx    1/1     Running
```

### Создаём ClusterIssuer

```bash
cat <<EOF > cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: noreply@duckdns.org
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

kubectl apply -f cluster-issuer.yaml
```

Проверяем:

```bash
kubectl get clusterissuer letsencrypt-prod
# NAME               READY   AGE
# letsencrypt-prod   True    10s
```

## Аутентификация

По умолчанию NORA работает без аутентификации (анонимный доступ на чтение). Для включения авторизации выполните следующие шаги:

### Шаг 1. Создаём htpasswd-файл

```bash
htpasswd -Bbc users.htpasswd admin your-password
# -B = bcrypt (обязательно для NORA), -b = пароль из аргумента, -c = создать файл
```

### Шаг 2. Создаём Kubernetes Secret

```bash
kubectl create secret generic nora-htpasswd \
  --from-file=users.htpasswd=./users.htpasswd
```

NORA поддерживает три роли: `read` (чтение), `write` (чтение + запись), `admin` (всё + управление токенами). Роли назначаются через токены (см. ниже).

### Шаг 3. Создаём S3-бакет и Kubernetes Secret для хранилища

Terraform создаёт S3-бакет в Yandex Object Storage, сервисный аккаунт с правами `storage.admin` и генерирует файл `secret_for_bucket.yaml` из шаблона `secret_for_bucket.yaml.tpl`. Если вы разворачиваете инфраструктуру не через Terraform, создайте файл `secret_for_bucket.yaml` вручную:

```bash
cat <<EOF > secret_for_bucket.yaml
apiVersion: v1
kind: Secret
metadata:
  name: nora-s3-credentials
type: Opaque
stringData:
  S3_ACCESS_KEY: <ваш_access_key>
  S3_SECRET_KEY: <ваш_secret_key>
EOF
```

Замените `<ваш_access_key>` и `<ваш_secret_key>` на реальные ключи сервисного аккаунта с правами `storage.admin` (можно создать в Yandex Cloud через `yc iam access-key create --service-account-name <sa-name>`).

Затем применяем его в кластер:

```bash
kubectl apply -f secret_for_bucket.yaml
```

Проверяем:

```bash
# Проверяем, что Secret создан
kubectl get secret nora-s3-credentials

# Проверяем наличие ключей
kubectl get secret nora-s3-credentials -o jsonpath='{.data.S3_ACCESS_KEY}' | base64 -d && echo
kubectl get secret nora-s3-credentials -o jsonpath='{.data.S3_SECRET_KEY}' | base64 -d && echo
```

## Деплой NORA через Helm

Инфраструктура готова — кластер работает, ingress-nginx слушает на публичном IP, cert-manager выпустит TLS-сертификат автоматически. Теперь ставим NORA.

### Добавляем Helm-репозиторий

```bash
helm repo add nora https://getnora-io.github.io/helm-charts
helm repo update
```

### Создаём values-файл

```bash
cat <<EOF > helm-values.yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: nora-apatsev.duckdns.org
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: nora-tls
      hosts:
        - nora-apatsev.duckdns.org

persistence:
  enabled: false

config:
  server:
    public_url: "https://nora-apatsev.duckdns.org"
  storage:
    mode: s3
    path: /data/storage
    s3_url: https://storage.yandexcloud.net
    bucket: nora-storage-anton-patsev
    s3_region: ru-central1
  registries:
    enable: "all"
  auth:
    enabled: true
    anonymous_read: true # Для terraform
    htpasswd:
      existingSecret: nora-htpasswd
      secretKey: users.htpasswd

extraEnv:
  - name: NORA_STORAGE_S3_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: nora-s3-credentials
        key: S3_ACCESS_KEY
  - name: NORA_STORAGE_S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: nora-s3-credentials
        key: S3_SECRET_KEY

resources:
  limits:
    memory: 512Mi
    cpu: "1"
  requests:
    memory: 128Mi
    cpu: "0.25"
EOF
```

Указываем только то, что отличается от дефолтов Nora:
- `config.server.public_url` — внешний URL, который NORA будет вставлять в download-ссылки (обязательно за reverse proxy)
- `config.storage.mode` — режим хранения `s3` вместо `local`
- `config.storage.s3_url` — эндпоинт Yandex Object Storage
- `config.storage.bucket` — имя S3-бакета
- `config.storage.s3_region` — регион Yandex Cloud
- `persistence.enabled: false` — PVC не нужен, данные хранятся в S3
- `extraEnv` — credentials для S3 берутся из Kubernetes Secret `nora-s3-credentials` (создан на шаге 3)
- `config.auth.enabled` — включает аутентификацию по htpasswd
- `config.auth.htpasswd.existingSecret` — ссылка на Kubernetes Secret с htpasswd-файлом (chart сам монтирует его в контейнер)
- `proxy-body-size: "0"` — снимает ограничение на размер тела запроса (нужно для больших Docker-образов)
- `proxy-read-timeout: "600"` — увеличенный таймаут для больших загрузок
- `cert-manager.io/cluster-issuer` — аннотация для автоматического выпуска TLS-сертификата через cert-manager
- `tls` — конфигурация TLS с указанием Secret для сертификата

### Устанавливаем

```bash
helm upgrade --install nora nora/nora --version 0.4.0 -f helm-values.yaml
```

### Проверяем

```bash
# Ждём готовности пода
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nora --timeout=120s

# Проверяем health
curl https://nora-apatsev.duckdns.org/health

# Открываем Web UI
open https://nora-apatsev.duckdns.org/ui/
```

После этого NORA доступна по адресу `https://nora-apatsev.duckdns.org`. Web UI покажет dashboard с 13 реестрами.

### Создание и использование токенов

NORA использует API-токены с префиксом `nra_` вместо эндпоинта `/auth/token` (который есть в Docker Hub / GHCR, но отсутствует в NORA).

NORA поддерживает три роли: `read` (чтение), `write` (чтение + запись), `admin` (всё + управление токенами).

```bash
# Создать токен
curl -X POST https://nora-apatsev.duckdns.org/api/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "username": "admin",
    "password": "your-password",
    "role": "write",
    "ttl_days": 90,
    "description": "CI/CD pipeline token"
  }'
# {"token": "nra_82ff3b514d6944a88278aa200da6ca0c...", "expires_in_days": 90}

# проверка токена
curl -H "Authorization: Bearer nra_82ff3b514d6944a88278aa200da6ca0c" \
  https://nora-apatsev.duckdns.org/v2/_catalog

# Использовать токен для npm
npm config set //nora-apatsev.duckdns.org:_authToken nra_82ff3b514d6944a88278aa200da6ca0c

# Docker login с токеном (токен в качестве пароля, любое имя пользователя)
docker login nora-apatsev.duckdns.org -u token -p nra_82ff3b514d6944a88278aa200da6ca0c
```

## Использование: примеры для каждого формата

### Docker

```bash
# Берём готовый публичный образ (или собираем свой из Dockerfile)
docker pull nginx:alpine

# Пушим образ
docker tag nginx:alpine nora-apatsev.duckdns.org/myapp:1.0
docker push nora-apatsev.duckdns.org/myapp:1.0

# Пуллим образ из NORA
docker pull nora-apatsev.duckdns.org/myapp:1.0
```

NORA полностью совместима с Docker Registry v2 API, поэтому все стандартные команды `docker` работают без изменений.

### npm

```bash
# Настройка реестра для проекта
npm config set registry https://nora-apatsev.duckdns.org/npm/

# Установка пакета (NORA проксирует запрос в npmjs.org и кэширует)
npm install lodash

```

#### Тестирование npm publish

Чтобы проверить публикацию, можно создать минимальный тестовый пакет:

```bash
mkdir -p test-npm-pkg

cat <<'EOF' > test-npm-pkg/package.json
{
  "name": "@test/hello-world",
  "version": "1.0.0",
  "description": "Test package for Nora registry",
  "main": "index.js"
}
EOF

cat <<'EOF' > test-npm-pkg/index.js
module.exports = function hello() {
  return "Hello from Nora registry!";
};
EOF

cd test-npm-pkg

npm config set //nora-apatsev.duckdns.org/npm/:_authToken nra_82ff3b514d6944a88278aa200da6ca0c

# Публикуем (запускается из директории test-npm-pkg)
npm publish --registry https://nora-apatsev.duckdns.org/npm/

# Проверяем установку
cd .. && mkdir test-install && cd test-install
npm init -y
npm install @test/hello-world --registry https://nora-apatsev.duckdns.org/npm/
node -e "const hello = require('@test/hello-world'); console.log(hello());"
```

Структура тестового пакета:

```
test-npm-pkg/
├── package.json   # имя: @test/hello-world, версия: 1.0.0
└── index.js       # module.exports = function hello() { return "Hello from Nora registry!"; }
```

Или через `.npmrc` в проекте:

```
registry=https://nora-apatsev.duckdns.org/npm/
```

Scoped-пакеты тоже работают:

```bash
npm install @babel/core --registry https://nora-apatsev.duckdns.org/npm/
```

### PyPI

```bash
# Создаём и активируем виртуальное окружение
python3 -m venv .venv
source .venv/bin/activate

# Установка пакета через NORA (с токеном)
pip install --index-url https://token:nra_82ff3b514d6944a88278aa200da6ca0c@nora-apatsev.duckdns.org/simple/ flask
```

Пример минимального Python-пакета для публикации (директория `python-pkg-example` уже есть в репозитории):

```
python-pkg-example/
├── pyproject.toml
├── src/
│   └── python_pkg_example/
│       └── __init__.py
└── dist/                # создаётся автоматически при python -m build
```

```bash
cd python-pkg-example
python3 -m venv .venv
source .venv/bin/activate
pip install build twine
python -m build
twine upload --repository-url https://token:nra_82ff3b514d6944a88278aa200da6ca0c@nora-apatsev.duckdns.org/simple/ dist/*
```

Для постоянной настройки создайте `~/.pip/pip.conf`:

```ini
[global]
index-url = https://nora-apatsev.duckdns.org/simple/
```

NORA поддерживает PEP 503 (HTML) и PEP 691 (JSON) — современные клиенты pip автоматически выбирают JSON API.

### Maven

Пример минимального Maven-пакета для публикации (директория `test-maven-pkg` уже есть в репозитории):

```
test-maven-pkg/
├── pom.xml
├── settings.xml
└── src/main/java/com/example/HelloNora.java
```

Создайте `pom.xml` с описанием артефакта и адресом репозитория:

```bash
cat <<'EOF' > test-maven-pkg/pom.xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>com.example</groupId>
    <artifactId>hello-nora</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>

    <name>hello-nora</name>
    <description>Minimal Maven package for NORA registry test</description>

    <properties>
        <maven.compiler.source>11</maven.compiler.source>
        <maven.compiler.target>11</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>

    <distributionManagement>
        <repository>
            <id>nora</id>
            <name>NORA Maven Repository</name>
            <url>https://nora-apatsev.duckdns.org/maven2</url>
        </repository>
    </distributionManagement>
</project>
EOF
```

Создайте `settings.xml` с учётными данными для аутентификации:

```bash
cat <<EOF > test-maven-pkg/settings.xml
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
    <servers>
        <server>
            <id>nora</id>
            <username>admin</username>
            <password>your-password</password>
        </server>
    </servers>
</settings>
EOF
```

Создайте исходный файл:

```bash
mkdir -p test-maven-pkg/src/main/java/com/example
cat <<'EOF' > test-maven-pkg/src/main/java/com/example/HelloNora.java
package com.example;

public class HelloNora {
    public static String greet() {
        return "Hello from NORA!";
    }

    public static void main(String[] args) {
        System.out.println(greet());
    }
}
EOF
```

Публикация артефакта:

```bash
cd test-maven-pkg
mvn deploy -s settings.xml
```

### Helm OCI

Helm-чарты хранятся через Docker/OCI endpoint. Для тестирования создайте и запакуйте чарт (директория `test-helm-pkg` уже есть в репозитории):

```bash
# Авторизация в реестре
helm registry login nora-apatsev.duckdns.org -u admin -p your-password

# Создаём чарт (если ещё нет)
cd test-helm-pkg
helm create mychart

# Запаковываем в .tgz
helm package mychart

# Публикация чарта
helm push mychart-0.1.0.tgz oci://nora-apatsev.duckdns.org/helm

# Скачивание чарта
helm pull oci://nora-apatsev.duckdns.org/helm/mychart --version 0.1.0

# Установка чарта из NORA
helm install myrelease oci://nora-apatsev.duckdns.org/helm/mychart --version 0.1.0
```

### Go modules

Для использования `go get` необходимо находиться внутри Go-модуля (директории с `go.mod`):

```bash
# Если модуль ещё не создан — инициализируем
mkdir test-go-pkg && cd test-go-pkg
go mod init test-go-pkg
```

Настройте Go proxy с аутентификацией.

**Вариант 1: Токен в URL (проще)**

```bash
# Глобально через go env (рекомендуется)
go env -w GOPROXY=https://token:nra_82ff3b514d6944a88278aa200da6ca0c@nora-apatsev.duckdns.org/go,direct

# Или через переменную окружения
export GOPROXY=https://token:nra_82ff3b514d6944a88278aa200da6ca0c@nora-apatsev.duckdns.org/go,direct
```

**Вариант 2: Через .netrc (рекомендуется для CI/CD)**

```bash
echo "machine nora-apatsev.duckdns.org login token password nra_82ff3b514d6944a88278aa200da6ca0c" >> ~/.netrc
chmod 600 ~/.netrc

go env -w GOPROXY=https://nora-apatsev.duckdns.org/go,direct
```

Теперь go get работает через NORA:

```bash
go get golang.org/x/text@latest
```

Go-модули иммутабельны после первой загрузки — NORA кэширует `.info`, `.mod`, `.zip` навсегда.

### Cargo (Rust)

Пример минимального Rust-пакета для публикации (директория `test-cargo-pkg` уже есть в репозитории):

```
test-cargo-pkg/
├── .cargo/config.toml   # конфигурация реестра
├── Cargo.toml           # описание пакета
└── src/lib.rs           # исходный код
```

Создайте структуру проекта:

```bash
mkdir -p test-cargo-pkg/.cargo test-cargo-pkg/src
```

Создайте `.cargo/config.toml` с настройками реестра:

```bash
cat <<'EOF' > test-cargo-pkg/.cargo/config.toml
[registries.nora]
index = "sparse+https://nora-apatsev.duckdns.org/cargo/"

[registry]
global-credential-providers = ["cargo:token"]

[source.crates-io]
replace-with = "nora"
EOF
```

Авторизация в реестре (токен должен содержать префикс `Bearer`):

```bash
# Вариант 1: через stdin (рекомендуется для CI/CD)
echo "Bearer nra_82ff3b514d6944a88278aa200da6ca0c" | cargo login --registry nora

# Вариант 2: через переменную окружения
export CARGO_REGISTRIES_NORA_TOKEN="Bearer nra_82ff3b514d6944a88278aa200da6ca0c"
```

> **Важно:** префикс `Bearer ` обязателен — без него Cargo выдаст ошибку `the token does not include an authentication scheme`.
> `cargo login --registry nora` требует, чтобы реестр `nora` был определён в глобальном конфиге `~/.cargo/config.toml`. Если реестр определён только в проектном `.cargo/config.toml`, используйте переменную окружения `CARGO_REGISTRIES_NORA_TOKEN`.

Создайте `Cargo.toml` с описанием пакета:

```bash
cat <<'EOF' > test-cargo-pkg/Cargo.toml
[package]
name = "test-cargo-pkg"
version = "0.1.0"
edition = "2021"
description = "Test Cargo package for Nora registry"
EOF
```

Создайте исходный файл `src/lib.rs`:

```bash
cat <<'EOF' > test-cargo-pkg/src/lib.rs
pub fn hello() -> &'static str {
    "Hello from Nora!"
}
EOF
```

Публикация:

```bash
cd test-cargo-pkg
cargo build  # зависимости теперь тянутся через NORA
cargo publish --registry nora
```

NORA реализует Cargo sparse index (RFC 2789) — не нужно хранить git-репозиторий индекса.

### Terraform

Так как Terraform не отправляет заголовок Authorization, поэтому для скачивания провайдеров необходим анонимный доступ на чтение. 
Для этого в helm-values.yaml выставляем `anonymous_read: true`.

В файле `~/.terraformrc`:

```hcl
provider_installation {
  network_mirror {
    url = "https://nora-apatsev.duckdns.org/terraform/"
  }
}
```

После этого все `terraform init` будут скачивать провайдеры через NORA:

```bash
terraform init
# Provider hashicorp/aws will be downloaded from nora-apatsev.duckdns.org
```

### RubyGems

NORA поддерживает proxy/cache для RubyGems — проксирует запросы к rubygems.org и кэширует гемы.

#### Настройка зеркалирования

Настройте bundler на использование NORA как зеркала rubygems.org:

```bash
# Глобально (рекомендуется)
bundle config mirror.https://rubygems.org https://nora-apatsev.duckdns.org/gems/

# Или через .bundle/config в проекте
mkdir -p .bundle
cat <<'EOF' > .bundle/config
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "https://nora-apatsev.duckdns.org/gems/"
EOF
```

#### Установка зависимостей

```bash
bundle install
```

#### Публикация гема

Для публикации гема в NORA используйте `gem push` с указанием реестра:

```bash
# Авторизация (токен используется как пароль, любое имя пользователя)
curl -u "token:nra_82ff3b514d6944a88278aa200da6ca0c" \
  https://nora-apatsev.duckdns.org/api/v1/gems

# Собираем гем из .gemspec
gem build mygem.gemspec

# Публикуем
gem push mygem-0.1.0.gem \
  --host https://nora-apatsev.duckdns.org/gems/ \
  --key nra_82ff3b514d6944a88278aa200da6ca0c
```

Пример минимального тестового гема:

```
test-ruby-pkg/
├── test-ruby-pkg.gemspec
├── Gemfile
└── lib/
    └── test_ruby_pkg.rb
```

```bash
mkdir -p test-ruby-pkg/lib
cat <<'EOF' > test-ruby-pkg/test-ruby-pkg.gemspec
Gem::Specification.new do |s|
  s.name        = "test-ruby-pkg"
  s.version     = "0.1.0"
  s.summary     = "Test gem for NORA registry"
  s.description = "Minimal Ruby gem for testing NORA registry"
  s.authors     = ["Test"]
  s.email       = "test@example.com"
  s.files       = ["lib/test_ruby_pkg.rb"]
  s.homepage    = "https://nora-apatsev.duckdns.org"
  s.license     = "MIT"
end
EOF

cat <<'EOF' > test-ruby-pkg/lib/test_ruby_pkg.rb
module TestRubyPkg
  def self.hello
    "Hello from NORA!"
  end
end
EOF

cat <<'EOF' > test-ruby-pkg/Gemfile
source "https://nora-apatsev.duckdns.org/gems/"
gemspec
EOF
```

```bash
cd test-ruby-pkg
gem build test-ruby-pkg.gemspec
gem push test-ruby-pkg-0.1.0.gem --host https://nora-apatsev.duckdns.org/gems/
```

#### Установка из NORA

```bash
# Через Gemfile
echo 'source "https://nora-apatsev.duckdns.org/gems/"' > Gemfile
echo 'gem "test-ruby-pkg"' >> Gemfile
bundle install

# Или через gem install
gem install test-ruby-pkg --source https://nora-apatsev.duckdns.org/gems/
```

### NuGet (.NET)

NORA поддерживает NuGet V3 API — проксирует запросы к nuget.org и кэширует пакеты.

#### Настройка источника пакетов

```bash
# Добавляем NORA как источник NuGet-пакетов
dotnet nuget add source https://nora-apatsev.duckdns.org/nuget/v3/index.json \
  -n nora \
  -u token \
  -p nra_82ff3b514d6944a88278aa200da6ca0c \
  --store-password-in-clear-text

# Или через nuget CLI
nuget source add -Name nora \
  -Source https://nora-apatsev.duckdns.org/nuget/v3/index.json \
  -UserName token \
  -Password nra_82ff3b514d6944a88278aa200da6ca0c
```

Или через файл `nuget.config` в проекте:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nora" value="https://nora-apatsev.duckdns.org/nuget/v3/index.json" />
  </packageSources>
  <packageSourceCredentials>
    <nora>
      <add key="Username" value="token" />
      <add key="ClearTextPassword" value="nra_82ff3b514d6944a88278aa200da6ca0c" />
    </nora>
  </packageSourceCredentials>
</configuration>
```

#### Установка зависимостей

```bash
dotnet restore
```

#### Публикация пакета

Пример минимального тестового NuGet-пакета:

```
test-nuget-pkg/
├── TestNugetPkg.csproj
└── Class1.cs
```

```bash
mkdir -p test-nuget-pkg
cat <<'EOF' > test-nuget-pkg/TestNugetPkg.csproj
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <PackageId>TestNugetPkg</PackageId>
    <Version>0.1.0</Version>
    <Authors>Test</Authors>
    <Description>Test NuGet package for NORA registry</Description>
  </PropertyGroup>
</Project>
EOF

cat <<'EOF' > test-nuget-pkg/Class1.cs
namespace TestNugetPkg;

public static class Hello
{
    public static string Greet() => "Hello from NORA!";
}
EOF
```

```bash
cd test-nuget-pkg

# Собираем пакет
dotnet pack -c Release

# Публикуем в NORA
dotnet nuget push bin/Release/TestNugetPkg.0.1.0.nupkg \
  --source https://nora-apatsev.duckdns.org/nuget/v3/index.json \
  --api-key nra_82ff3b514d6944a88278aa200da6ca0c
```

#### Установка из NORA

```bash
dotnet add package TestNugetPkg --source https://nora-apatsev.duckdns.org/nuget/v3/index.json
```

### Ansible Galaxy

NORA поддерживает Ansible Galaxy API — проксирует запросы к galaxy.ansible.com и кэширует коллекции и роли.

#### Установка коллекций

```bash
# Установка коллекции из NORA (с аутентификацией)
ansible-galaxy collection install community.general \
  -s https://nora-apatsev.duckdns.org/ansible/ \
  --token nra_82ff3b514d6944a88278aa200da6ca0c
```

Для постоянной настройки добавьте сервер в `ansible.cfg`:

```ini
[galaxy]
server_list = nora

[galaxy_server.nora]
url = https://nora-apatsev.duckdns.org/ansible/
token = nra_82ff3b514d6944a88278aa200da6ca0c
```

После этого все команды `ansible-galaxy` будут использовать NORA:

```bash
ansible-galaxy collection install community.general
ansible-galaxy role install geerlingguy.docker
```

#### Публикация коллекции

Пример минимальной тестовой коллекции:

```
test-ansible-pkg/
├── galaxy.yml
├── README.md
├── meta/
│   └── runtime.yml
└── plugins/
    └── modules/
        └── hello_nora.py
```

```bash
mkdir -p test-ansible-pkg/meta test-ansible-pkg/plugins/modules

cat <<'EOF' > test-ansible-pkg/galaxy.yml
namespace: test
name: hello_nora
version: 0.1.0
description: Test Ansible collection for NORA registry
authors:
  - Test
license:
  - MIT
readme: README.md
EOF

cat <<'EOF' > test-ansible-pkg/meta/runtime.yml
requires_ansible: ">=2.14"
EOF

cat <<'EOF' > test-ansible-pkg/plugins/modules/hello_nora.py
#!/usr/bin/python
from ansible.module_utils.basic import AnsibleModule

def main():
    module = AnsibleModule(argument_spec={})
    module.exit_json(changed=False, msg="Hello from NORA!")

if __name__ == '__main__':
    main()
EOF
```

Сборка и публикация:

```bash
cd test-ansible-pkg

# Собираем коллекцию в tar.gz
ansible-galaxy collection build

# Публикуем в NORA
ansible-galaxy collection publish test-hello_nora-0.1.0.tar.gz \
  --server https://nora-apatsev.duckdns.org/ansible/ \
  --token nra_82ff3b514d6944a88278aa200da6ca0c
```

#### Публикация роли

```bash
# Инициализируем роль
ansible-galaxy role init test-hello-nora
cd test-hello-nora

# Публикуем роль в NORA
ansible-galaxy role import \
  --server https://nora-apatsev.duckdns.org/ansible/ \
  --token nra_82ff3b514d6944a88278aa200da6ca0c
```

### Conan (C/C++)

NORA поддерживает Conan V2 API — проксирует запросы к conan.io (ConanCenter) и кэширует пакеты.

#### Настройка удалённого репозитория

```bash
# Добавляем NORA как удалённый репозиторий Conan
conan remote add nora https://nora-apatsev.duckdns.org/conan

# Авторизация
conan remote login nora -p nra_82ff3b514d6944a88278aa200da6ca0c
```

Для постоянной настройки используйте `global.conf`:

```ini
# ~/.conan2/global.conf
core.sources:download_cache=~/.conan2/download_cache
```

Или файл `remotes.json`:

```json
{
  "remotes": [
    {
      "name": "nora",
      "url": "https://nora-apatsev.duckdns.org/conan",
      "verify_ssl": true
    }
  ]
}
```

#### Установка пакетов

```bash
# Установка пакета из NORA
conan install zlib/1.3.1@ --remote=nora

# Установка с зависимостями
conan install . --remote=nora --output-folder=build

# Установка с профилем
conan install . --remote=nora -pr:h default -pr:b default
```

#### Публикация пакета

Пример минимального тестового Conan-пакета:

```
test-conan-pkg/
├── conanfile.py
├── src/
│   └── hello.cpp
└── CMakeLists.txt
```

```bash
mkdir -p test-conan-pkg/src

cat <<'EOF' > test-conan-pkg/conanfile.py
from conan import ConanFile
from conan.tools.cmake import CMake, cmake_layout
from conan.tools.files import copy
import os

class TestConanPkg(ConanFile):
    name = "test-conan-pkg"
    version = "0.1.0"
    license = "MIT"
    description = "Test Conan package for NORA registry"
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeToolchain", "CMakeDeps"
    exports_sources = "src/*", "CMakeLists.txt"

    def layout(self):
        cmake_layout(self)

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["test-conan-pkg"]
EOF

cat <<'EOF' > test-conan-pkg/CMakeLists.txt
cmake_minimum_required(VERSION 3.15)
project(test-conan-pkg CXX)

add_library(test-conan-pkg src/hello.cpp)
target_include_directories(test-conan-pkg PUBLIC include)

install(TARGETS test-conan-pkg DESTINATION lib)
install(FILES include/hello.h DESTINATION include)
EOF

mkdir -p test-conan-pkg/include
cat <<'EOF' > test-conan-pkg/include/hello.h
#pragma once
const char* hello_nora();
EOF

cat <<'EOF' > test-conan-pkg/src/hello.cpp
#include "hello.h"

const char* hello_nora() {
    return "Hello from NORA!";
}
EOF
```

Сборка и публикация:

```bash
cd test-conan-pkg

# Собираем пакет
conan create . --remote=nora

# Публикуем в NORA
conan upload test-conan-pkg/0.1.0 -r nora --confirm
```

#### Использование в проекте

```bash
# В conanfile.txt
cat <<'EOF' > conanfile.txt
[requires]
zlib/1.3.1
test-conan-pkg/0.1.0

[generators]
CMakeToolchain
CMakeDeps
EOF

conan install . --remote=nora --output-folder=build
cmake --preset conan-release
cmake --build build
```

### Pub (Dart/Flutter)

NORA поддерживает pub.dev API — проксирует запросы к pub.dev и кэширует пакеты.

#### Настройка

```bash
# Указываем NORA как хост для pub
export PUB_HOSTED_URL=https://nora-apatsev.duckdns.org/pub

# Для Flutter
export FLUTTER_STORAGE_BASE_URL=https://nora-apatsev.duckdns.org/pub
```

Для постоянной настройки добавьте в `~/.bashrc` или `~/.zshrc`:

```bash
echo 'export PUB_HOSTED_URL=https://nora-apatsev.duckdns.org/pub' >> ~/.bashrc
```

#### Установка зависимостей

```bash
dart pub get

# Или для Flutter
flutter pub get
```

#### Публикация пакета

Пример минимального тестового Dart-пакета:

```
test-pub-pkg/
├── pubspec.yaml
├── lib/
│   └── test_pub_pkg.dart
├��─ example/
│   └── test_pub_pkg_example.dart
└── README.md
```

```bash
mkdir -p test-pub-pkg/lib test-pub-pkg/example

cat <<'EOF' > test-pub-pkg/pubspec.yaml
name: test_pub_pkg
description: Test Dart package for NORA registry
version: 0.1.0
homepage: https://nora-apatsev.duckdns.org

environment:
  sdk: ">=3.0.0 <4.0.0"
EOF

cat <<'EOF' > test-pub-pkg/lib/test_pub_pkg.dart
library test_pub_pkg;

String hello() {
  return "Hello from NORA!";
}
EOF

cat <<'EOF' > test-pub-pkg/example/test_pub_pkg_example.dart
import 'package:test_pub_pkg/test_pub_pkg.dart';

void main() {
  print(hello());
}
EOF
```

Публикация:

```bash
cd test-pub-pkg

# Авторизация через токен (создаётся на pub.dev)
export PUB_TOKEN=nra_82ff3b514d6944a88278aa200da6ca0c

# Публикуем в NORA
dart pub publish --server=https://nora-apatsev.duckdns.org/pub

# Или для Flutter
flutter pub publish --server=https://nora-apatsev.duckdns.org/pub
```

#### Использование в проекте

```yaml
# pubspec.yaml
name: my_app
environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  test_pub_pkg: ^0.1.0
```

```bash
# С PUB_HOSTED_URL зависимости тянутся из NORA
dart pub get
```

## Защита от supply chain атак

NORA включает многоуровневую защиту от атак на цепочку поставок — ситуаций, когда скомпрометированный пакет из публичного реестра попадает в production через ваш приватный registry. Яркий пример — 31 марта 2026 года группа DPRK Sapphire Sleet перехватила контроль над npm-пакетом axios (100 млн загрузок в неделю), опубликовав вредоносную версию 1.14.1. Окно атаки составило всего 3 часа, но могло затронуть миллионы проектов.

### Min Release Age — блокировка свежих пакетов

Одна строка в конфиге блокирует пакеты, опубликованные менее N дней назад. Большинство вредоносных пакетов обнаруживаются в течение 1–3 дней, поэтому 7 дней — безопасный буфер. Аналогичная функция есть в `.npmrc` (`min-release-age=7`) и `uv.toml` (`exclude-newer = "7 days"`), но NORA поддерживает все 13 форматов реестров и per-registry переопределения.

**Настройка в `helm-values.yaml` (секция `config.curation`):**

```yaml
config:
  curation:
    mode: "enforce"
    min_release_age: "7d"
    npm:
      min_release_age: "3d"
    pypi:
      min_release_age: "5d"
```

Поддерживаемые форматы длительности: `7d` (дни), `24h` (часы), `1w` (недели), `1w2d` (комбинации).

**Как это работает:**

- **Извлечение даты публикации** — реальные даты из кэшированных метаданных: npm `time`, PyPI `upload-time`, Cargo, Go, NuGet, Conan, pub.dev, Maven Central, RubyGems, Ansible Galaxy, Terraform. NORA проверяет дату публикации пакета при каждом запросе на скачивание и сравнивает её с текущим временем.
- **Digest quarantine** — для реестров без дат публикации (Docker/OCI) NORA отслеживает первый момент появления каждого content digest. Новые digest удерживаются в карантине до истечения порога. Это невозможно подменить — используется часы самой NORA, а не unsigned upstream дата.
- **Fail-closed** — если дата публикации неизвестна и карантин активен, пакет блокируется (не пропускается).
- **Bypass token** — заголовок `X-Nora-Bypass-Token` для экстренных случаев (сравнение в constant-time).

### CVE Blocking — блокировка известно-уязвимых пакетов

NORA позволяет блокировать пакеты с известными CVE через механизм blocklist. Это не автоматическое сканирование CVE (как Trivy или Snyk), а управляемый список запрещённых пакетов, который можно заполнять вручную или экспортировать из баз уязвимостей:

```json
{
  "version": 1,
  "rules": [
    {
      "registry": "npm",
      "name": "event-stream",
      "version": "3.3.6",
      "reason": "CVE-2018-16396 — malicious flatmap-stream dependency"
    },
    {
      "registry": "*",
      "name": "log4j*",
      "version": "2.*",
      "reason": "CVE-2021-44228 — Log4Shell RCE"
    }
  ]
}
```

Правила поддерживают glob-паттерны (`*`, `foo*`, `*foo`, `foo.**` для Maven groupId, `foo/**` для Go модулей) и работают со всеми 13 форматами реестров.

**Включение в `helm-values.yaml`:**

Сначала создаём ConfigMap с blocklist и (опционально) Secret с allowlist:

```bash
cat <<'EOF' > blocklist.json
{
  "version": 1,
  "rules": [
    {
      "registry": "npm",
      "name": "event-stream",
      "version": "3.3.6",
      "reason": "CVE-2018-16396 — malicious flatmap-stream dependency"
    },
    {
      "registry": "*",
      "name": "log4j*",
      "version": "2.*",
      "reason": "CVE-2021-44228 — Log4Shell RCE"
    }
  ]
}
EOF
```

Создаём ConfigMap для blocklist:

```bash
kubectl create configmap nora-blocklist \
  --from-file=blocklist.json=blocklist.json
```

Пример `allowlist.json`:

```bash
cat <<'EOF' > allowlist.json
{
  "version": 1,
  "mode": "default-deny",
  "rules": [
    {
      "registry": "npm",
      "name": "lodash",
      "version": "4.17.21",
      "sha256": "e3c89c3d2e05c3e0f0b7c1c3e1d2a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1"
    },
    {
      "registry": "pypi",
      "name": "flask",
      "version": "3.*"
    }
  ]
}
EOF
```

Поле `mode` определяет стратегию фильтрации:

| Значение | Поведение |
|----------|-----------|
| `default-deny` | Всё запрещено, разрешены **только** пакеты из `rules` |
| `default-allow` | Всё разрешено, запрещены только пакеты из `rules` |

Поле `sha256` (опционально) — пиннинг целостности: пакет пропускается только если его хеш совпадает с указанным.

Создаём ConfigMap для allowlist (опционально):

```bash
kubectl create configmap nora-allowlist \
  --from-file=allowlist.json=allowlist.json
```

Helm-чарт (начиная с версии 0.4.0) монтирует файлы автоматически — достаточно указать `existingConfigMap` или `existingSecret`:

```yaml
config:
  curation:
    mode: "enforce"
    blocklist:
      existingConfigMap: nora-blocklist
      # key: blocklist.json          # по умолчанию; файл монтируется в <mountPath>/<key>
      # mountPath: /etc/nora         # по умолчанию
    allowlist:
      existingConfigMap: nora-allowlist
```

Chart сам создаёт volume и volumeMount, а также выставляет `curation.blocklist_path` / `curation.allowlist_path` в конфиге NORA. Не нужно вручную патчить Deployment — ни `kubectl patch`, ни `kubectl cp` не нужны.

Правила поддерживают glob-паттерны (`*`, `foo*`, `*foo`, `foo.**` для Maven groupId, `foo/**` для Go модулей) и работают со всеми 13 форматами реестров.

В режиме `audit` совпадения логируются, но не блокируются — удобно для dry-run перед включением в production.

### Дополнительные уровни защиты

- **Allowlist** — режим default-deny: только явно перечисленные `(registry, name, version)` проходят, с опциональным SHA-256 пиннингом целостности.
- **Изоляция пространств имён** — работает всегда, даже в режиме `off`. Предотвращает dependency confusion — внутренние имена пакетов никогда не проксируются в upstream реестры.
- **Проверка целостности** — SHA-256/SHA-512 checksums проверяются при каждой загрузке, compile-time typestate гарантирует целостность отдаваемых байтов.
- **Bypass token** — заголовок `X-Nora-Bypass-Token` с constant-time сравнением для экстренного обхода curation.

Все эти механизмы настраиваются через переменные окружения, TOML-конфиг или YAML в Helm values, и работают поверх существующей proxy/cache архитектуры NORA без дополнительных зависимостей.

Полный пример `helm-values.yaml` с включённой защитой от supply chain атак:

```yaml
cat <<EOF > helm-values.yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: nora-apatsev.duckdns.org
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: nora-tls
      hosts:
        - nora-apatsev.duckdns.org

persistence:
  enabled: false

config:
  server:
    public_url: "https://nora-apatsev.duckdns.org"
  storage:
    mode: s3
    path: /data/storage
    s3_url: https://storage.yandexcloud.net
    bucket: nora-storage-anton-patsev
    s3_region: ru-central1
  registries:
    enable: "all"
  curation:
    mode: "enforce"
    min_release_age: "7d"
    blocklist:
      existingConfigMap: nora-blocklist
    allowlist:
      existingConfigMap: nora-allowlist
    npm:
      min_release_age: "3d"
    pypi:
      min_release_age: "5d"
  auth:
    enabled: true
    # Нужно для Terraform network_mirror: клиент Terraform не отправляет
    # заголовок Authorization, поэтому для скачивания провайдеров необходим
    # анонимный доступ на чтение. Запись (push) по-прежнему требует авторизации.
    anonymous_read: true
    htpasswd:
      existingSecret: nora-htpasswd
      secretKey: users.htpasswd

extraEnv:
  - name: NORA_STORAGE_S3_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: nora-s3-credentials
        key: S3_ACCESS_KEY
  - name: NORA_STORAGE_S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: nora-s3-credentials
        key: S3_SECRET_KEY

resources:
  limits:
    memory: 512Mi
    cpu: "1"
  requests:
    memory: 128Mi
    cpu: "0.25"
EOF
```

## Air-gapped: работа в изолированных средах

NORA имеет встроенную утилиту `nora mirror` для предварительного кэширования зависимостей. Это критично для сред без доступа в интернет.

### Кэширование по lockfile

```bash
# npm — по package-lock.json
nora mirror npm --lockfile package-lock.json \
  --registry https://nora-apatsev.duckdns.org

# pip — по requirements.txt
nora mirror pip --requirement requirements.txt \
  --registry https://nora-apatsev.duckdns.org

# Cargo — по Cargo.lock
nora mirror cargo --lockfile Cargo.lock \
  --registry https://nora-apatsev.duckdns.org

# Maven — по pom.xml
nora mirror maven --pom pom.xml \
  --registry https://nora-apatsev.duckdns.org
```

### Кэширование Docker-образов

```bash
nora mirror docker \
  --images "nginx:latest,redis:7,node:20-alpine,python:3.12" \
  --registry https://nora-apatsev.duckdns.org
```

### Работа в air-gapped среде

После зеркалирования NORA работает полностью автономно — все зависимости отдаются из локального кэша, обращений к внешним реестрам нет.

## Мониторинг

NORA отдаёт метрики в формате Prometheus по эндпоинту `/metrics`.

### Проверка здоровья

```bash
# Общий health check
curl https://nora-apatsev.duckdns.org/health

# Readiness probe
curl https://nora-apatsev.duckdns.org/ready
```

### Prometheus

Добавьте NORA в `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'nora'
    scrape_interval: 15s
    static_configs:
      - targets: ['nora-apatsev.duckdns.org:443']
    scheme: https
    metrics_path: /metrics
```

### Grafana

NORA предоставляет метрики:
- `nora_requests_total` — количество запросов по реестрам
- `nora_request_duration_seconds` — latency
- `nora_storage_bytes` — объём хранилища
- `nora_artifacts_total` — количество артефактов

### Эндпоинты

| URL | Описание |
|-----|----------|
| `/ui/` | Web UI (dashboard, поиск, просмотр) |
| `/health` | Проверка здоровья |
| `/ready` | Readiness probe |
| `/metrics` | Метрики Prometheus |
| `/api-docs` | Swagger/OpenAPI |

## Бэкап и восстановление

NORA хранит все данные в S3-бакете (Yandex Object Storage). Бэкап — это копирование данных из бакета.

### Через CLI NORA

```bash
# Бэкап
nora backup --output /data/nora-backup.tar.gz

# Восстановление
nora restore --input /data/nora-backup.tar.gz
```

### Через S3 lifecycle / версионирование

Yandex Object Storage поддерживает версионирование и lifecycle-правила. Рекомендуется включить версионирование на бакете `nora-storage-anton-patsev` для защиты от случайного удаления:

```bash
yc storage bucket update nora-storage-anton-patsev --versioning enabled
```

### Через yc CLI (копирование бакета)

```bash
# Бэкап в другой бакет
yc storage s3 cp s3://nora-storage-anton-patsev s3://nora-backup-$(date +%Y%m%d) --recursive
```

## Trouleshooting

### 1. NORA не стартует / под в CrashLoopBackOff

```bash
kubectl logs deploy/nora
kubectl describe pod -l app.kubernetes.io/name=nora
```

Проверьте, что Secret `nora-s3-credentials` существует: `kubectl get secret nora-s3-credentials`.
Проверьте, что S3-бакет доступен: `yc storage bucket list`.

### 2. TLS-сертификат не выпускается (NET::ERR_CERT_AUTHORITY_INVALID)

**Симптом:** браузер показывает «Ваше подключение не защищено» / `NET::ERR_CERT_AUTHORITY_INVALID`.

**Причина:** cert-manager ещё не выпустил сертификат или Challenge не прошёл.

```bash
kubectl get certificates
kubectl describe certificate nora-tls
kubectl get challenges
kubectl describe challenge
kubectl get orders
kubectl describe order
```

**Решения:**
- Подождать 1–5 минут — Let's Encrypt ACME HTTP-01 challenge требует времени
- Проверить, что ClusterIssuer в статусе Ready: `kubectl get clusterissuer letsencrypt-prod`
- Проверить логи cert-manager: `kubectl logs -n cert-manager deploy/cert-manager`
- Убедиться, что DNS-запись `nora-apatsev.duckdns.org` резолвится на правильный IP ingress-контроллера:
  ```bash
  dig nora-apatsev.duckdns.org +short
  kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
  ```
- Если cert-manager не может достучаться до `/.well-known/acme-challenge/` — проверить, что ingress-nginx работает и нет конфликтов Ingress-правил

### 3. Docker push / pull не работает

```bash
# Проверяем, что NORA отвечает
curl https://nora-apatsev.duckdns.org/v2/

# Проверяем ingress
kubectl get ingress
kubectl describe ingress nora
```

Убедитесь, что `proxy-body-size` не ограничивает размер образа (в values стоит `"0"` — без ограничения).

### 4. cert-manager: как это работает

1. Ingress-nginx создаётся с аннотацией `cert-manager.io/cluster-issuer`
2. cert-manager видит аннотацию и создаёт Certificate-ресурс
3. Certificate → CertificateRequest → Order → Challenge
4. Let's Encrypt проверяет доступ к `/.well-known/acme-challenge/` через ingress-nginx
5. cert-manager получает сертификат и сохраняет его в Secret `nora-tls`
6. ingress-nginx использует этот Secret для TLS-терминации

## Заключение

NORA — это современная альтернатива Nexus, Artifactory и Harbor для команд, которым не нужен enterprise-overhead. Ключевые преимущества:

- **Простота** — один бинарник, один конфиг, S3-бакет. Данные живут в Object Storage, stateless-поды.
- **Производительность** — < 3 секунды на старт, < 50 МБ RAM. Rust, Tokio, Axum.
- **13 форматов** — Docker, Maven, npm, PyPI, Cargo, Go, Raw, RubyGems, Terraform, Ansible, NuGet, Pub, Conan.
- **Безопасность** — OpenSSF Scorecard, подписанные релизы, SBOM, 1200+ тестов, блокировка свежих пакетов (min-release-age), CVE blocklist, digest quarantine, namespace isolation.
- **Air-gapped ready** — встроенное зеркалирование для изолированных сред.

Репозиторий с Terraform-кодом для этой статьи: [github.com/patsevanton/nora-habr](https://github.com/patsevanton/nora-habr)

- GitHub: [github.com/getnora-io/nora](https://github.com/getnora-io/nora)
- Документация: [getnora.dev](https://getnora.dev)
- Telegram: [t.me/getnora](https://t.me/getnora)
- Artifact Hub: [artifacthub.io/packages/helm/nora/nora](https://artifacthub.io/packages/helm/nora/nora)
