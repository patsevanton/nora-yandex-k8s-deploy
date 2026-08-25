# NORA: Artifact registry с карантином свежих пакетов и блокировкой CVE

## Введение

Каждый разработчик сталкивался с проблемой хранения артефактов: Docker-образы, npm-пакеты, Maven-артефакты, Python wheels. Вариантов обычно два — использовать публичные реестры (Docker Hub, npmjs.org, PyPI) или поднимать Nexus / Artifactory / Harbor. Публичные реестры ненадёжны из-за rate limit и блокировок. А Nexus и Artifactory — это тяжёлая Java-платформа: JVM, отдельная СУБД (OrientDB/PostgreSQL), 2–4 ГБ RAM уже в простое и десятки минут на старт.

[NORA](https://github.com/getnora-io/nora) — open-source реестр артефактов на Rust, созданный как прямая альтернатива этим гигантам. Вместо Java-стека — один бинарник < 27 МБ. Вместо 2–4 ГБ RAM — < 50 МБ в простое, т.е. на порядок меньше. Вместо десятков минут на старт — 3 секунды. Внешних зависимостей нет вообще: ни Java 11+, ни отдельной СУБД — метаданные хранятся на файловой системе, а артефакты сразу можно отправлять в S3, чего бесплатные версии Nexus и Artifactory не умеют. При этом поддерживается 15 форматов: Docker, Maven, npm, PyPI, Cargo, Go, Raw, RubyGems, Terraform, Ansible Galaxy, NuGet, Pub (Dart/Flutter), Conan (C/C++), RPM (yum/dnf), Debian/APT. Плюс Helm-чарты через OCI, карантин свежих пакетов (Min Release Age), блокировка уязвимых версий (CVE Blocking) и лицензия MIT.

В этой статье мы развернём NORA в Kubernetes на Yandex Managed Kubernetes, а затем попробуем все основные сценарии использования.

## NORA vs Nexus vs Artifactory vs Harbor

Сравниваются только бесплатные/свободные версии: NORA (MIT), Nexus Repository OSS, Artifactory OSS и Harbor (Apache 2.0).

| Метрика | NORA | Nexus | JFrog Artifactory | Harbor |
|---------|------|-------|-------------------|--------|
| RAM (простой) | < 50 МБ | 2–4 ГБ | 2–4 ГБ | 2–4 ГБ |
| Время старта | < 3 сек | 30–60 сек | 30–60 сек | 30–60 сек |
| Зависимости | Нет | Java 11+ | Java 11+ | PostgreSQL, Redis |
| База данных | Файловая система | OrientDB/PostgreSQL | OrientDB/PostgreSQL | PostgreSQL |
| Количество форматов | 15 | 30+ | 30+ | Docker, OCI, Helm, CNAB |
| S3-хранилище | Да | Нет | Нет | Да |
| Лицензия | MIT | OSS | OSS | Apache 2.0 |
| Ключевые особенности (бесплатные версии) | Один бинарник на Rust, S3, карантин свежих пакетов, блокировка уязвимых пакетов по версиям | hosted/proxy/group-репозитории | Conan — в редакции CE для C/C++ | Cканирование CVE image используя trivy после загрузки image|

NORA уступает Nexus/Artifactory/Harbor по количеству поддерживаемых форматов. Но для команд, которым нужен быстрый, лёгкий и бесплатный registry с основными форматами — это отличный выбор.

Отличительная особенность Nora это:
- **Min Release Age** — карантин свежих пакетов
- **CVE Blocking** — блокировка уязвимых пакетов по версии

> Предварительно требуется работающий кластер Kubernetes с установленным ingress-контроллером, cert-manager, настроенным доступом к S3-хранилищу и прокси-сервером для скачивания пакетов и образов из реестров, подверженных гео-ограничениям (например, Terraform Registry). Установите эти компоненты перед переходом к шагам 1–2 ниже.

## Шаг 1. Аутентификация

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

### Шаг 3. Применяем Kubernetes Secret для S3-хранилища

Нужно создать S3-бакет и создать файл `secret_for_bucket.yaml`. Файл выглядит примерно так:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: nora-s3-credentials
type: Opaque
stringData:
  S3_ACCESS_KEY: YCAJE...
  S3_SECRET_KEY: YCNL9...
```

Просто применяем его в кластер:

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

## Шаг 2. Деплой NORA через Helm

### Добавляем Helm-репозиторий

```bash
helm repo add nora https://getnora-io.github.io/helm-charts
helm repo update
```

В этой статье используется чарт версии **0.4.4** (она уже указана в команде установки ниже через `--version 0.4.4`) с пином образа **NORA v1.2.0** через `image.tag` в values. Посмотреть все доступные версии можно так:

```bash
helm search repo nora/nora --versions
```

> Когда выйдет чарт `0.4.5` (appVersion 1.2.0), пин `image.tag: "1.2.0"` из `helm-values.yaml.tpl` можно удалить — чарт начнёт использовать appVersion по умолчанию.

### values-файл генерируется автоматически

Примерное содержимое `helm-values.yaml`:

```yaml
image:
  # NORA v1.2.0; чарт 0.4.4 ещё имеет appVersion 1.1.0, поэтому пиним тег вручную.
  # Когда выйдет чарт 0.4.5 (appVersion 1.2.0), строку можно удалить.
  tag: "1.2.0"

ingress:
  enabled: true
  className: traefik
  hosts:
    - host: ${fqdn}
      paths:
        - path: /
          pathType: Prefix
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: nora-tls
      hosts:
        - ${fqdn}

# Если используется S3, то выключаем локальный диск.
persistence:
  enabled: false

config:
  server:
    public_url: "https://${fqdn}"
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
```

### Устанавливаем

```bash
helm upgrade --install nora nora/nora --version 0.4.4 -f helm-values.yaml
```

### Проверяем

```bash
# Ждём готовности пода
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nora --timeout=120s

# Проверяем health
curl https://$NORA_FQDN/health

# Открываем Web UI
open https://$NORA_FQDN/ui/
```

После этого NORA доступна по адресу `https://$NORA_FQDN`. Web UI покажет dashboard с 15 реестрами.

![NORA Dashboard](dashboard.png)

### Создание и использование токенов

NORA использует API-токены с префиксом `nra_` вместо эндпоинта `/auth/token` (который есть в Docker Hub / GHCR, но отсутствует в NORA).

NORA поддерживает три роли: `read` (чтение), `write` (чтение + запись), `admin` (всё + управление токенами).

```bash
# Создать токен
curl -X POST https://$NORA_FQDN/api/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "username": "admin",
    "password": "your-password",
    "role": "write",
    "ttl_days": 90,
    "description": "CI/CD pipeline token"
  }'
# {"token": "nra_13ef0a4c309d4750907648409f57a65c...", "expires_in_days": 90}

# проверка токена
curl -H "Authorization: Bearer nra_13ef0a4c309d4750907648409f57a65c" \
  https://$NORA_FQDN/v2/_catalog

```

## Использование: примеры для каждого формата

NORA v1.2.0 поддерживает 15 форматов, но не для всех реализована публикация (push/publish). Часть реестров на данный момент поддерживает только проксирование запросов и кеширование пакетов — **proxy/cache** (зеркало апстрима с кэшированием). Сводная таблица:

| Формат | Pull (proxy/cache) | Push/Publish | Примечание |
|---|:---:|:---:|---|
| Docker / OCI | ✅ | ✅ | hosted + proxy |
| Helm OCI | ✅ | ✅ | через Docker/OCI endpoint |
| npm | ✅ | ✅ | hosted + proxy |
| PyPI | ✅ | ✅ | hosted + proxy |
| Maven | ✅ | ✅ | hosted + proxy |
| Cargo | ✅ | ✅ | hosted + proxy (sparse index) |
| Go | ✅ | — | только proxy (модули immutable, push не предусмотрен протоколом) |
| Terraform | ✅ | — | только proxy (провайдеры скачиваются из апстрима) |
| Raw | ✅ | ✅ | hosted only, условные PUT (ETag/If-Match — только на local-бэкенде, см. раздел Raw) |
| RPM | ✅ | ✅ | hosted + proxy, авто-генерация repodata |
| Debian/APT | ✅ | ✅ | hosted + proxy, авто-генерация Packages/Release |
| RubyGems | ✅ | ❌ | **только proxy/cache** (`gem push`) |
| NuGet | ✅ | ❌ | **только proxy/cache** (`dotnet nuget push`) |
| Ansible Galaxy | ✅ | ❌ | **только proxy/cache** (`ansible-galaxy collection publish`) |
| Pub (Dart) | ✅ | ❌ | **только proxy/cache** (`dart pub publish`) |
| Conan | ✅ | ❌ | **только proxy/cache** (`conan upload`) |

Для форматов, помеченных ❌ в колонке Push, разделы ниже содержат примеры команд публикации — они оставлены для справки и будут актуальны, когда NORA добавит соответствующие эндпоинты. Сейчас эти форматы используйте только как pull-through кэш.

### Кэширование 15 форматов

Из 15 форматов только Raw не имеет апстрима — это hosted-only реестр (только локальные пакеты). Остальные 14 работают как **proxy/cache**: кэшируют пакеты/метаданные из апстрима. Сводка по умолчанию (без явной настройки `proxies` в `helm-values.yaml`):

| Формат | Кэширует апстрим | Апстрим по умолчанию | Тип кэша | Примечание |
|---|:---:|---|---|---|
| Docker / OCI | ✅ | `registry-1.docker.io` | immutable blobs + TTL manifest | hosted + proxy; кэш включён, когда `docker.upstreams` непустой (по умолчанию Docker Hub) |
| Helm OCI | ✅ | через Docker/OCI endpoint | — | hosted + proxy (через Docker endpoint) |
| npm | ✅ | `registry.npmjs.org` | packuments (TTL) + tarball (immutable) | hosted + proxy |
| PyPI | ✅ | `pypi.org/simple/` | index (TTL) + файлы (immutable) | hosted + proxy |
| Maven | ✅ | `repo1.maven.org/maven2` | metadata (TTL) + артефакты (immutable) | hosted + proxy |
| Cargo | ✅ | `crates.io` (sparse index) | index (TTL) + .crate (immutable) | hosted + proxy |
| Go | ✅ | `proxy.golang.org` | @v/list,@latest (TTL) + .info/.mod/.zip (immutable) | только proxy |
| Terraform | ✅ | `registry.terraform.io` | discovery (TTL) + провайдеры (immutable) | только proxy; требует `anonymous_read: true` |
| RubyGems | ✅ | `rubygems.org` | specs/latest_specs/info (TTL) + gem/gemspec (immutable) | только proxy |
| NuGet | ✅ | `api.nuget.org` | registration/query (TTL) + .nupkg/.nuspec (immutable) | только proxy |
| Ansible Galaxy | ✅ | `galaxy.ansible.com` | collection list/detail (TTL) + tarball (immutable) | только proxy |
| Pub (Dart) | ✅ | `pub.dev` | package metadata (TTL) + archive (immutable) | только proxy |
| Conan | ✅* | `center2.conan.io` | revisions (TTL) + recipe/package files (immutable) | только proxy; v2 API + v1/ping (совместимость с клиентом Conan 2.x с NORA v1.2.0) |
| RPM | ✅* | — (нет по умолчанию) | пакеты (immutable) + repodata (регенерируется) | hosted; pull-through проксирование доступно через `config.registries.rpm.proxies` (например, `fedora: https://download.fedoraproject.org/...`), по умолчанию **выключено** |
| Debian/APT | ✅* | — (нет по умолчанию) | пакеты (immutable) + Packages/Release (регенерируется) | hosted; pull-through через `config.registries.deb.proxies` (например, `debian: https://deb.debian.org/debian`), по умолчанию **выключено** |
| Raw | ❌ | — (нет апстрима) | — | **hosted only** — апстрим-проксирования нет по дизайну (любой файл по любому пути); кэшировать нечего |

**Итого: только Raw не имеет апстрима** — остальные 14 форматов поддерживают кэширование апстрима (Docker, Helm OCI, npm, PyPI, Maven, Cargo, Go, Terraform, RubyGems, NuGet, Ansible, Pub, Conan кэшируют из коробки; RPM и Debian/APT — через pull-through, который по умолчанию выключен и включается явно через `config.registries.rpm.proxies` / `config.registries.deb.proxies` в `helm-values.yaml`).

Типы кэша:
- **immutable** — пакет/артефакт кэшируется навсегда после первого скачивания (content-addressed, не меняется). Это основная защита от rate-limit и блокировок апстрима.
- **TTL** — метаданные (index, search, version list) кэшируются с TTL (по умолчанию 300с для большинства, настраивается через `<registry>.metadata_ttl`); при истечении TTL NORA ревалидирует у апстрима (`If-None-Match`/`If-Modified-Since`), при недоступности апстрима — отдаёт stale.

С v1.2.0 все форматы поддерживают **докачку прерванных загрузок** (HTTP `Range` / `206 Partial Content`): `curl -C -`, `pip`, `apt` продолжат передачу с места обрыва вместо повторного скачивания целиком. Мутабельный контент (индексы, packuments, repodata) исключён — докачка диапазона поверх перезаписанных данных склеила бы два поколения файла.

### Включение pull-through для RPM/Debian

По умолчанию RPM и Debian/APT в NORA — hosted-репозитории (вы публикуете свои пакеты). Чтобы они ещё и проксировали апстрим, добавьте маппинг в `helm-values.yaml`:

```yaml
config:
  registries:
    rpm:
      proxies:
        fedora: "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Everything/x86_64/os"
    deb:
      proxies:
        debian: "https://deb.debian.org/debian"
```

После этого `dnf install --enablerepo=nora-fedora vim` / `apt install vim` пойдёт через NORA (pull-through, immutable кэш).

### Docker

```bash
# Docker login с токеном (токен в качестве пароля, любое имя пользователя)
docker login $NORA_FQDN -u token -p nra_13ef0a4c309d4750907648409f57a65c

# Берём готовый публичный образ (или собираем свой из Dockerfile)
docker pull nginx:alpine

# Пушим образ
docker tag nginx:alpine $NORA_FQDN/myapp:1.0
docker push $NORA_FQDN/myapp:1.0

# Пуллим образ из NORA
docker pull $NORA_FQDN/myapp:1.0
```

NORA полностью совместима с Docker Registry v2 API, поэтому все стандартные команды `docker` работают без изменений. Начиная с v1.2.0 поддерживается cross-repo blob mount (`POST /v2/{name}/blobs/uploads/?mount={digest}&from={repo}`) — blob копируется из другого репозитория того же реестра без повторной загрузки; при превышении лимита загрузок NORA возвращает OCI-совместимый `429` с заголовком `Retry-After`.

### npm

```bash
# Использовать токен для npm
npm config set //$NORA_FQDN:_authToken nra_13ef0a4c309d4750907648409f57a65c

# Настройка реестра для проекта
npm config set registry https://$NORA_FQDN/npm/

# Установка пакета (NORA проксирует запрос в npmjs.org и кэширует)
npm install lodash

```

#### Тестирование npm publish

Чтобы проверить публикацию, можно создать минимальный тестовый пакет:

```bash
mkdir -p test-npm-pkg

cat <<EOF >  test-npm-pkg/package.json
{
  "name": "@test/hello-world",
  "version": "1.0.0",
  "description": "Test package for Nora registry",
  "main": "index.js"
}
EOF

cat <<EOF >  test-npm-pkg/index.js
module.exports = function hello() {
  return "Hello from Nora registry!";
};
EOF

cd test-npm-pkg

npm config set //$NORA_FQDN/npm/:_authToken nra_13ef0a4c309d4750907648409f57a65c

# Публикуем (запускается из директории test-npm-pkg)
npm publish --registry https://$NORA_FQDN/npm/

# Проверяем установку
cd .. && mkdir test-install && cd test-install
npm init -y
npm install @test/hello-world --registry https://$NORA_FQDN/npm/
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
registry=https://$NORA_FQDN/npm/
```

Scoped-пакеты тоже работают:

```bash
npm install @babel/core --registry https://$NORA_FQDN/npm/
```

### PyPI

```bash
# Создаём и активируем виртуальное окружение
python3 -m venv .venv
source .venv/bin/activate

# Установка pip (на некоторых системах не устанавливается автоматически)
python3 -m ensurepip --upgrade

# Установка пакета через NORA (с токеном)
python3 -m pip install --index-url https://token:nra_13ef0a4c309d4750907648409f57a65c@$NORA_FQDN/simple/ flask
```

Пример минимального Python-пакета для публикации:

```
test-python-pkg/
├── pyproject.toml
├── src/
│   └── test_python_pkg/
│       └── __init__.py
└── dist/
```

```bash
cd test-python-pkg
python3 -m venv .venv
source .venv/bin/activate
pip install build twine
python -m build
twine upload --repository-url https://token:nra_13ef0a4c309d4750907648409f57a65c@$NORA_FQDN/simple/ dist/*
```

Для постоянной настройки создайте `~/.pip/pip.conf`:

```ini
[global]
index-url = https://$NORA_FQDN/simple/
```

NORA поддерживает PEP 503 (HTML) и PEP 691 (JSON) — современные клиенты pip автоматически выбирают JSON API.

### Maven

Пример минимального Maven-пакета для публикации:

```
test-maven-pkg/
├── pom.xml
├── settings.xml
└── src/main/java/com/example/HelloNora.java
```

Создайте `pom.xml` с описанием артефакта и адресом репозитория:

```bash
cat <<EOF >  test-maven-pkg/pom.xml
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
            <url>https://$NORA_FQDN/maven2</url>
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
cat <<EOF >  test-maven-pkg/src/main/java/com/example/HelloNora.java
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

Helm-чарты хранятся через Docker/OCI endpoint. Для тестирования создайте и запакуйте чарт:

```bash
mkdir -p test-helm-pkg

# Авторизация в реестре
helm registry login $NORA_FQDN -u admin -p your-password

# Создаём чарт
cd test-helm-pkg
helm create mychart

# Запаковываем в .tgz
helm package mychart

# Публикация чарта
helm push mychart-0.1.0.tgz oci://$NORA_FQDN/helm

# Скачивание чарта
helm pull oci://$NORA_FQDN/helm/mychart --version 0.1.0

# Установка чарта из NORA
helm install myrelease oci://$NORA_FQDN/helm/mychart --version 0.1.0
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
go env -w GOPROXY=https://token:nra_13ef0a4c309d4750907648409f57a65c@$NORA_FQDN/go,direct

# Или через переменную окружения
export GOPROXY=https://token:nra_13ef0a4c309d4750907648409f57a65c@$NORA_FQDN/go,direct
```

**Вариант 2: Через .netrc (рекомендуется для CI/CD)**

```bash
echo "machine $NORA_FQDN login token password nra_13ef0a4c309d4750907648409f57a65c" >> ~/.netrc
chmod 600 ~/.netrc

go env -w GOPROXY=https://$NORA_FQDN/go,direct
```

Теперь go get работает через NORA:

```bash
go get golang.org/x/text@latest
```

Go-модули иммутабельны после первой загрузки — NORA кэширует `.info`, `.mod`, `.zip` навсегда.

### Cargo (Rust)

Пример минимального Rust-пакета для публикации:

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
cat <<EOF >  test-cargo-pkg/.cargo/config.toml
[registries.nora]
index = "sparse+https://$NORA_FQDN/cargo/index/"

[registry]
global-credential-providers = ["cargo:token"]

[source.crates-io]
replace-with = "nora"
EOF
```

Авторизация в реестре (токен должен содержать префикс `Bearer`):

```bash
# Вариант 1: через stdin (рекомендуется для CI/CD)
echo "Bearer nra_13ef0a4c309d4750907648409f57a65c" | cargo login --registry nora

# Вариант 2: через переменную окружения
export CARGO_REGISTRIES_NORA_TOKEN="Bearer nra_13ef0a4c309d4750907648409f57a65c"
```

> **Важно:** префикс `Bearer ` обязателен — без него Cargo выдаст ошибку `the token does not include an authentication scheme`.
> `cargo login --registry nora` требует, чтобы реестр `nora` был определён в глобальном конфиге `~/.cargo/config.toml`. Если реестр определён только в проектном `.cargo/config.toml`, используйте переменную окружения `CARGO_REGISTRIES_NORA_TOKEN`.

Создайте `Cargo.toml` с описанием пакета:

```bash
cat <<EOF >  test-cargo-pkg/Cargo.toml
[package]
name = "test-cargo-pkg"
version = "0.1.0"
edition = "2021"
description = "Test Cargo package for Nora registry"
EOF
```

Создайте исходный файл `src/lib.rs`:

```bash
cat <<EOF >  test-cargo-pkg/src/lib.rs
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
    url = "https://$NORA_FQDN/terraform/"
  }
}
```

После этого все `terraform init` будут скачивать провайдеры через NORA:

```bash
terraform init
# Provider hashicorp/aws will be downloaded from $NORA_FQDN
```

### RubyGems

NORA поддерживает только proxy/cache для RubyGems — проксирует запросы к rubygems.org и кэширует гемы.

> Pull-through протестирован: `bundle install` успешно скачал `rake 13.4.2` через `https://$NORA_FQDN/gems/`. Подтверждено исходниками NORA (`nora-registry/src/registry/gems.rs`, `pub fn routes`): все роуты — только `get` (`specs_index`, `latest_specs_index`, `info`, `download_gem`, `download_gemspec`); POST/PUT-эндпоинтов для публикации нет.

#### Настройка зеркалирования

Настройте bundler на использование NORA как зеркала rubygems.org:

```bash
# Глобально (рекомендуется)
bundle config mirror.https://rubygems.org https://$NORA_FQDN/gems/

# Или через .bundle/config в проекте
mkdir -p .bundle
cat <<EOF >  .bundle/config
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "https://$NORA_FQDN/gems/"
EOF
```

#### Установка зависимостей

```bash
bundle install
```

### NuGet (.NET)

NORA только проксирует запросы к nuget.org и кэширует пакеты через NuGet V3 API.

> Pull-through протестирован: `dotnet restore --source nora` успешно скачал `Newtonsoft.Json 13.0.3` через NORA. Подтверждено исходниками NORA (`nora-registry/src/registry/nuget.rs`, `fn routes_with_prefix`): все роуты — только `get` (`service_index`, `search_query`, `autocomplete`, `registration_index`, `flatcontainer`); ресурс `PackagePublish/2.0.0` в service index отсутствует, PUT/POST-эндпоинтов нет.

#### Настройка источника пакетов

```bash
# Добавляем NORA как источник NuGet-пакетов
dotnet nuget add source https://$NORA_FQDN/nuget/v3/index.json \
  -n nora \
  -u token \
  -p nra_13ef0a4c309d4750907648409f57a65c \
  --store-password-in-clear-text

# Или через nuget CLI
nuget source add -Name nora \
  -Source https://$NORA_FQDN/nuget/v3/index.json \
  -UserName token \
  -Password nra_13ef0a4c309d4750907648409f57a65c
```

Или через файл `nuget.config` в проекте:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nora" value="https://$NORA_FQDN/nuget/v3/index.json" />
  </packageSources>
  <packageSourceCredentials>
    <nora>
      <add key="Username" value="token" />
      <add key="ClearTextPassword" value="nra_13ef0a4c309d4750907648409f57a65c" />
    </nora>
  </packageSourceCredentials>
</configuration>
```

#### Установка зависимостей

```bash
dotnet restore
```

#### Установка из NORA

```bash
dotnet add package TestNugetPkg --source https://$NORA_FQDN/nuget/v3/index.json
```

### Ansible Galaxy

NORA только проксирует запросы к galaxy.ansible.com и кэширует коллекции и роли.

> Pull-through протестирован: `ansible-galaxy collection install community.general` через NORA успешно скачал `community.general:13.2.0`. Подтверждено исходниками NORA (`nora-registry/src/registry/ansible.rs`, `pub fn routes`): все роуты — только `get` (`api_discovery`, `collection_list`, `collection_detail`, `version_list`, `version_detail`, `download_tarball`); POST-эндпоинта `/api/v3/artifacts/imports/` нет.

#### Установка коллекций

```bash
# Установка коллекции из NORA (с аутентификацией)
ansible-galaxy collection install community.general \
  -s https://$NORA_FQDN/ansible/ \
  --token nra_13ef0a4c309d4750907648409f57a65c
```

Для постоянной настройки добавьте сервер в `ansible.cfg`:

```ini
[galaxy]
server_list = nora

[galaxy_server.nora]
url = https://$NORA_FQDN/ansible/
token = nra_13ef0a4c309d4750907648409f57a65c
```

После этого все команды `ansible-galaxy` будут использовать NORA:

```bash
ansible-galaxy collection install community.general
ansible-galaxy role install geerlingguy.docker
```

### Conan (C/C++)

NORA только проксирует запросы и кэширует пакеты к к ConanCenter (`center2.conan.io`)  используя Conan V2 API.

#### Настройка через conan remote (работает с NORA v1.2.0)

```bash
# Добавляем NORA как удалённый репозиторий Conan
conan remote add nora https://$NORA_FQDN/conan

# Авторизация (токен как пароль, любое имя пользователя)
conan remote login nora token -p nra_13ef0a4c309d4750907648409f57a65c

# Поиск и установка пакетов через NORA (pull-through кэш ConanCenter)
conan list "zlib/*" -r nora
conan install . -r nora --build=missing
```

#### Проверка v2-эндпоинтов вручную (curl)

v2-эндпоинты NORA полностью функциональны (proxy/cache ConanCenter `center2.conan.io`). Подтверждено исходниками NORA (`nora-registry/src/registry/conan.rs`, `pub fn routes`): все роуты — только `get` (ping, search, recipe/package file download, revisions, latest); v1-эндпоинт один — `GET /conan/v1/ping` (для совместимости с клиентом Conan 2.x), PUT/POST для публикации отсутствуют. Тесты через curl (Basic auth `token:nra_...`, все вернули HTTP 200):
- `GET /conan/v1/ping` → 200 + `X-Conan-Server-Capabilities: revisions` (с v1.2.0)
- `GET /conan/v2/ping` → 200
- `GET /conan/v2/conans/search?q=zlib` → 200 (список версий zlib: 1.2.11, 1.2.12, 1.2.13, 1.3, 1.3.1, 1.3.2)
- `GET /conan/v2/conans/zlib/1.3.1/_/_/latest` → 200 (revision `cac0f6daea041b0ccf42934163defb20`)
- `GET /conan/v2/conans/zlib/1.3.1/_/_/revisions` → 200 (4 revision)
- `GET /conan/v2/conans/zlib/1.3.1/_/_/revisions/{rrev}/files` → 200 (conanfile.py, conanmanifest.txt, conan_export.tgz, conan_sources.tgz)
- `GET /conan/v2/conans/zlib/1.3.1/_/_/revisions/{rrev}/files/conanfile.py` → 200 (4160 байт, реальный conanfile.py)

```bash
# Ping (v1 — то, что отправляет клиент Conan 2.x первым запросом)
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" https://$NORA_FQDN/conan/v1/ping
# HTTP 200, заголовок X-Conan-Server-Capabilities: revisions

# Ping (v2)
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" https://$NORA_FQDN/conan/v2/ping
# HTTP 200

# Поиск
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  "https://$NORA_FQDN/conan/v2/conans/search?q=zlib"
# {"results":["zlib/1.2.11@_/_","zlib/1.3.1@_/_", ...]}

# Последняя revision рецепта
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  https://$NORA_FQDN/conan/v2/conans/zlib/1.3.1/_/_/latest
# {"revision":"cac0f6daea041b0ccf42934163defb20","time":"..."}

# Список файлов рецепта
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  https://$NORA_FQDN/conan/v2/conans/zlib/1.3.1/_/_/revisions/cac0f6daea041b0ccf42934163defb20/files
# {"files":{"conanfile.py":{},"conanmanifest.txt":{}, ...}}

# Скачать conanfile.py
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" -o conanfile.py \
  https://$NORA_FQDN/conan/v2/conans/zlib/1.3.1/_/_/revisions/cac0f6daea041b0ccf42934163defb20/files/conanfile.py
# HTTP 200, 4160 байт
```

### Pub (Dart/Flutter)

NORA только проксирует запросы к pub.dev и кэширует пакеты.

> Pull-through протестирован: `dart pub get` через `PUB_HOSTED_URL=https://$NORA_FQDN/pub` успешно скачал `meta 1.19.0`. Подтверждено исходниками NORA (`nora-registry/src/registry/pub_dart.rs`, `pub fn routes`): все роуты — только `get` (`search_packages`, `package_advisories`, `version_metadata`, `package_listing`, `download_archive`); GET-эндпоинта `/api/packages/versions/new` (upload-URL) нет, POST/PUT отсутствуют.

#### Настройка

```bash
# Указываем NORA как хост для pub
export PUB_HOSTED_URL=https://$NORA_FQDN/pub

# Для Flutter
export FLUTTER_STORAGE_BASE_URL=https://$NORA_FQDN/pub
```

Для постоянной настройки добавьте в `~/.bashrc` или `~/.zshrc`:

```bash
echo 'export PUB_HOSTED_URL=https://$NORA_FQDN/pub' >> ~/.bashrc
```

#### Установка зависимостей

```bash
dart pub get

# Или для Flutter
flutter pub get
```

### Raw (произвольные файлы)

NORA поддерживает хранение произвольных файлов — бинарников, архивов, конфигов, release-артефактов. Это hosted-only реестр: апстрим-проксирования нет, версионирования пакетов тоже нет — любой файл по любому пути.

> Тестирование: PUT → 201, GET, HEAD, DELETE → 204, 409 на дубликат, `If-None-Match: *` → 412 create-only — всё работает. На S3-бэкене ETag не возвращается (см. ниже).

#### Загрузка файла

```bash
# Анонимная загрузка (если anonymous_read включён — для чтения; для записи нужен токен)
curl -X PUT --data-binary @release.tar.gz \
  https://$NORA_FQDN/raw/builds/release-1.0.tar.gz

# С аутентификацией (токен как пароль, любое имя пользователя)
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  -T release.tar.gz \
  https://$NORA_FQDN/raw/builds/release-1.0.tar.gz

# Или через Bearer
curl -H "Authorization: Bearer nra_13ef0a4c309d4750907648409f57a65c" \
  -X PUT --data-binary @release.tar.gz \
  https://$NORA_FQDN/raw/builds/release-1.0.tar.gz
```

#### Скачивание

```bash
curl -O https://$NORA_FQDN/raw/builds/release-1.0.tar.gz
```

#### Условная перезапись (RFC 9110)

Raw — единственный формат NORA с условными `PUT`: по умолчанию повторная загрузка в существующий путь возвращает **409 Conflict**. Для запрета перезаписи (create-only) используйте `If-None-Match: *` — упадёт **412 Precondition Failed**, если файл уже есть.


```bash
# Create-only: упадёт 412, если файл уже есть
curl -X PUT -H 'If-None-Match: *' \
  --data-binary @release.tar.gz \
  https://$NORA_FQDN/raw/builds/release-1.0.tar.gz

# Когда NORA начнёт отдавать ETag — условная перезапись будет выглядеть так:
# curl -I https://$NORA_FQDN/raw/builds/release-1.0.tar.gz   # получить etag
# curl -X PUT -H 'If-Match: "<etag>"' --data-binary @release-1.1.tar.gz \
#   https://$NORA_FQDN/raw/builds/release-1.0.tar.gz
```

#### Удаление и проверка существования

```bash
# Удаление
curl -X DELETE https://$NORA_FQDN/raw/builds/release-1.0.tar.gz

# HEAD — возвращает размер и Content-Type
curl -I https://$NORA_FQDN/raw/builds/release-1.0.tar.gz
```

#### Замечания

- Лимит размера файла — `raw.max_file_size` (по умолчанию 100 МБ), проверяется инкрементально в момент стриминга (ограничение `server.body_limit_mb` на Raw **не действует**).
- Path traversal отсекается (`/raw/../etc/passwd` → 400/404).
- Directory listing не поддерживается.

### RPM (yum/dnf)

NORA поддерживает hosted RPM-репозитории с автоматической генерацией `repodata/` (как `createrepo`, но на стороне сервера) и pull-through проксирование апстрим yum-репозиториев.

#### Загрузка RPM-пакета

```bash
# Публикуем .rpm в репозиторий myrepo (имя репо — любой путь /rpm/<name>/)
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  -T myapp-1.0-1.x86_64.rpm \
  https://$NORA_FQDN/rpm/myrepo/myapp-1.0-1.x86_64.rpm
```

При публикации NORA парсит и валидирует RPM-заголовок; невалидные пакеты отвергаются. После publish/delete `repodata/` (`repomd.xml`, `primary/filelists/other.xml.gz`) регенерируется автоматически.

#### Настройка клиента yum/dnf

```bash
sudo tee /etc/yum.repos.d/nora-myrepo.repo <<EOF
[nora-myrepo]
name=NORA myrepo
baseurl=https://$NORA_FQDN/rpm/myrepo
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF
```

> `gpgcheck=0` — NORA не подписывает сами пакеты, только метаданные. На S3-бэкенде без `signing.key_path` подпись метаданных отключена, поэтому `repo_gpgcheck=0`. Если вы включите `signing.enabled` + `signing.key_path`, поставьте `repo_gpgcheck=1` и `gpgkey=https://$NORA_FQDN/rpm/myrepo/repodata/repomd.xml.key`.

#### Установка пакетов

```bash
sudo dnf clean all
sudo dnf install myapp
```

#### Pull-through проксирование апстрим-репозитория

В `helm-values.yaml` можно настроить маппинг имени репо на апстрим:

```yaml
config:
  registries:
    rpm:
      proxies:
        fedora: "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Everything/x86_64/os"
```

```bash
sudo dnf install --enablerepo=nora-fedora vim
```

#### Reindex (лечение out-of-band изменений)

```bash
curl -X POST https://$NORA_FQDN/rpm/myrepo/-/reindex
```

#### Зеркалирование для air-gapped

```bash
nora mirror rpm --repo myrepo --arch x86_64,noarch \
  --registry https://$NORA_FQDN
```

#### Замечания

- RPM отключён по умолчанию, но включается через `registries.enable: "all"`.
- SQLite-метаданные (`*_db`), delta-RPM и module metadata (`modules.yaml`) не генерируются — только XML.
- Каждый `/rpm/{repo}/` — независимый репозиторий.

### Debian/APT

NORA поддерживает hosted APT-репозитории с серверной генерацией `Packages`/`Release`/`InRelease` (без `dpkg-scanpackages`) и pull-through проксирование `deb.debian.org` и других зеркал. Поддерживаются два layout: **flat** (индексы в корне репо) и **structured** (dists/suites с компонентами).

#### Загрузка .deb

```bash
# Flat — индексы в корне репо
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  -T myapp_1.0_amd64.deb \
  https://$NORA_FQDN/deb/myrepo/myapp_1.0_amd64.deb

# Structured —指定 distribution и component через query-параметры
curl -u "token:nra_13ef0a4c309d4750907648409f57a65c" \
  -T myapp_1.0_amd64.deb \
  "https://$NORA_FQDN/deb/myrepo/pool/main/m/myapp/myapp_1.0_amd64.deb?distribution=jammy&component=main"
```

NORA парсит control-параграф из `.deb` (без `dpkg-scanpackages`), валидирует и регенерирует все затронутые индексы (`Packages`, `Packages.gz`, `Release`, `InRelease`, `Release.gpg`).

#### Настройка клиента apt

```bash
# Ключ репозитория (на S3 без signing.key_path — используйте [trusted=yes] вместо signed-by)
curl -fsSL https://$NORA_FQDN/deb/myrepo/pubkey.gpg \
  -o /etc/apt/keyrings/nora.asc

# Flat
echo "deb [signed-by=/etc/apt/keyrings/nora.asc] https://$NORA_FQDN/deb/myrepo ./" \
  > /etc/apt/sources.list.d/nora.list

# Structured
echo "deb [signed-by=/etc/apt/keyrings/nora.asc] https://$NORA_FQDN/deb/myrepo jammy main" \
  > /etc/apt/sources.list.d/nora.list
```

> Если подпись индексов отключена (на S3-бэкенде без `signing.key_path`), замените `[signed-by=...]` на `[trusted=yes]`:
> ```bash
> echo "deb [trusted=yes] https://$NORA_FQDN/deb/myrepo ./" > /etc/apt/sources.list.d/nora.list
> ```

#### Установка пакетов

```bash
sudo apt update
sudo apt install myapp
```

#### Pull-through проксирование апстрим

```yaml
config:
  registries:
    deb:
      proxies:
        debian: "https://deb.debian.org/debian"
```

```bash
sudo apt install --no-install-recommends vim
```

#### Reindex и air-gapped mirror

```bash
# Лечение out-of-band изменений
curl -X POST https://$NORA_FQDN/deb/myrepo/-/reindex

# Зеркалирование для air-gapped
nora mirror deb --repo myrepo --dist jammy --component main --arch amd64 \
  --registry https://$NORA_FQDN
```

#### Замечания

- Debian отключён по умолчанию, включается через `registries.enable: "all"` (уже в `helm-values.yaml.tpl`).
- `by-hash` индексы и `Translations`/`Contents` не генерируются — только `Packages{,.gz}` + `Release` + `InRelease`/`Release.gpg`.
- В structured layout arch-`all` пакеты автоматически попадают во все индексы конкретных архитектур.
- Upload path free-form: `Filename` в индексе считается от корня репо; структура `pool/...` не обязательна.

## Защита от supply chain атак

NORA включает многоуровневую защиту от атак на цепочку поставок — ситуаций, когда скомпрометированный пакет из публичного реестра попадает в production через ваш приватный registry. Яркий пример — 31 марта 2026 года группа DPRK Sapphire Sleet перехватила контроль над npm-пакетом axios (100 млн загрузок в неделю), опубликовав вредоносную версию 1.14.1. Окно атаки составило всего 3 часа, но могло затронуть миллионы проектов.

### Min Release Age — блокировка свежих пакетов

Одна строка в конфиге блокирует пакеты, опубликованные менее N дней назад. Большинство вредоносных пакетов обнаруживаются в течение 1–3 дней, поэтому 7 дней — безопасный буфер. Аналогичная функция есть в `.npmrc` (`min-release-age=7`) и `uv.toml` (`exclude-newer = "7 days"`), но NORA поддерживает все 15 форматов реестров и per-registry переопределения.

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

Правила поддерживают glob-паттерны (`*`, `foo*`, `*foo`, `foo.**` для Maven groupId, `foo/**` для Go модулей) и работают со всеми 15 форматами реестров.

**Включение в `helm-values.yaml`:**

Сначала создаём ConfigMap с blocklist и (опционально) Secret с allowlist:

```bash
cat <<EOF >  blocklist.json
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
cat <<EOF >  allowlist.json
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

Правила поддерживают glob-паттерны (`*`, `foo*`, `*foo`, `foo.**` для Maven groupId, `foo/**` для Go модулей) и работают со всеми 15 форматами реестров.

В режиме `audit` совпадения логируются, но не блокируются — удобно для dry-run перед включением в production.

### Дополнительные уровни защиты

- **Allowlist** — режим default-deny: только явно перечисленные `(registry, name, version)` проходят, с опциональным SHA-256 пиннингом целостности.
- **Изоляция пространств имён** — работает всегда, даже в режиме `off`. Предотвращает dependency confusion — внутренние имена пакетов никогда не проксируются в upstream реестры.
- **Проверка целостности** — SHA-256/SHA-512 checksums проверяются при каждой загрузке, compile-time typestate гарантирует целостность отдаваемых байтов.
- **Bypass token** — заголовок `X-Nora-Bypass-Token` с constant-time сравнением для экстренного обхода curation.

Все эти механизмы настраиваются через переменные окружения, TOML-конфиг или YAML в Helm values, и работают поверх существующей proxy/cache архитектуры NORA без дополнительных зависимостей.

Полный пример `helm-values.yaml.tpl` с включённой защитой от supply chain атак (домен подставит Terraform):

```yaml
ingress:
  enabled: true
  className: traefik
  hosts:
    - host: ${fqdn}
      paths:
        - path: /
          pathType: Prefix
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: nora-tls
      hosts:
        - ${fqdn}

persistence:
  enabled: false

config:
  server:
    public_url: "https://${fqdn}"
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
```

## Air-gapped: работа в изолированных средах

NORA имеет встроенную утилиту `nora mirror` для предварительного кэширования зависимостей. Это критично для сред без доступа в интернет.

### Кэширование по lockfile

```bash
# npm — по package-lock.json
nora mirror npm --lockfile package-lock.json \
  --registry https://$NORA_FQDN

# pip — по requirements.txt
nora mirror pip --requirement requirements.txt \
  --registry https://$NORA_FQDN

# Cargo — по Cargo.lock
nora mirror cargo --lockfile Cargo.lock \
  --registry https://$NORA_FQDN

# Maven — по pom.xml
nora mirror maven --pom pom.xml \
  --registry https://$NORA_FQDN
```

### Кэширование Docker-образов

```bash
nora mirror docker \
  --images "nginx:latest,redis:7,node:20-alpine,python:3.12" \
  --registry https://$NORA_FQDN
```

### Работа в air-gapped среде

После зеркалирования NORA работает полностью автономно — все зависимости отдаются из локального кэша, обращений к внешним реестрам нет.

## Мониторинг

NORA отдаёт метрики в формате Prometheus по эндпоинту `/metrics`.

### Проверка здоровья

```bash
# Общий health check
curl https://$NORA_FQDN/health

# Readiness probe
curl https://$NORA_FQDN/ready
```

### Prometheus

Добавьте NORA в `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'nora'
    scrape_interval: 15s
    static_configs:
      - targets: ['$NORA_FQDN:443']
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

## Заключение

NORA — это современная альтернатива Nexus, Artifactory и Harbor для команд, которым не нужен enterprise-overhead. Ключевые преимущества:

- **Простота** — один бинарник, один конфиг, S3-бакет. Данные живут в Object Storage, stateless-поды.
- **Производительность** — < 3 секунды на старт, < 50 МБ RAM. Rust, Tokio, Axum.
- **15 форматов** — Docker, Maven, npm, PyPI, Cargo, Go, Raw, RubyGems, Terraform, Ansible, NuGet, Pub, Conan, RPM, Debian/APT.
- **Безопасность** — OpenSSF Scorecard, подписанные релизы, SBOM, 1200+ тестов, блокировка свежих пакетов (min-release-age), CVE blocklist, digest quarantine, namespace isolation.
- **Air-gapped ready** — встроенное зеркалирование для изолированных сред.

Репозиторий с Terraform-кодом для этой статьи: [github.com/patsevanton/nora-yandex-k8s-deploy](https://github.com/patsevanton/nora-yandex-k8s-deploy)

- GitHub: [github.com/getnora-io/nora](https://github.com/getnora-io/nora)
- Документация: [getnora.dev](https://getnora.dev)
- Telegram: [t.me/getnora](https://t.me/getnora)
- Artifact Hub: [artifacthub.io/packages/helm/nora/nora](https://artifacthub.io/packages/helm/nora/nora)

