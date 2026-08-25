# Развёртывание инфраструктуры: Terraform + VLESS-прокси (mihomo)

Этот файл описывает шаги 1–3 деплоя NORA в Kubernetes на Yandex Cloud:
разворот инфраструктуры через Terraform, настройку VLESS-прокси (mihomo) для
обхода гео-блокировки HashiCorp и установку cert-manager для автоматического
выпуска TLS-сертификатов. Сама статья про NORA — в [README.md](README.md).

## Шаг 1. Развёртывание инфраструктуры через Terraform

Перед установкой cert-manager и NORA нужно развернуть инфраструктуру. Terraform создаёт кластер Kubernetes, статический публичный IP, S3-бакет и устанавливает ingress-контроллер Traefik, а также генерирует из шаблонов файлы `helm-values.yaml` (с подставленным доменом) и `secret_for_bucket.yaml` (с ключами доступа к S3).

### Требования

- [yc CLI](https://yandex.cloud/ru/docs/cli/), настроенный и аутентифицированный (`yc init`)
- [Terraform](https://www.terraform.io/) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/) и [Helm](https://helm.sh/)

### Запуск

```bash
# Клонируем репозиторий
git clone https://github.com/patsevanton/nora-yandex-k8s-deploy
cd nora-yandex-k8s-deploy

# При необходимости укажите ID каталога (по умолчанию берётся из конфигурации yc):
# cp terraform.tfvars.example terraform.tfvars

terraform init
terraform apply
```

После успешного `terraform apply` получаем доступ к кластеру:

```bash
yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --external --force
kubectl get nodes
```

Готовый домен и IP доступны в outputs:

```bash
terraform output nora_fqdn
# nora.84.201.172.10.sslip.io
```

Для удобства один раз экспортируем домен в переменную — тогда все команды из этой статьи будут работать без правок:

```bash
export NORA_FQDN=$(terraform output -raw nora_fqdn)
echo $NORA_FQDN
```

Далее в примерах используется `$NORA_FQDN`. Домен формируется автоматически через [sslip.io](https://sslip.io) — бесплатный wildcard-DNS, который не требует регистрации и токенов: домен резолвится в IP ingress-контроллера без какой-либо настройки, а Let's Encrypt выдаёт для него валидный TLS-сертификат через HTTP-01 challenge.

## Шаг 2. VLESS-прокси для исходящего трафика NORA (Terraform upstream)

Upstream-реестр Terraform (`registry.terraform.io`, `releases.hashicorp.com`) **гео-блокирован HashiCorp** для IP Yandex Cloud — при прямом обращении возвращается `HTTP 404` со страницей «Content not available in your region». Остальные upstream-реестры (npmjs.org, pypi.org, github.com, storage.yandexcloud.net и т.д.) с IP кластера доступны напрямую. Поэтому исходящий трафик NORA пускается через VLESS-прокси **только для доменов terraform.io / hashicorp.com** — остальные идут напрямую, экономя VLESS-трафик.

Этот шаг нужно выполнить **сразу после `terraform apply`**, чтобы NORA с первого старта ходила к HashiCorp через прокси.

Готовый файл [nora-vless-proxy.yaml](nora-vless-proxy.yaml) поднимает [mihomo](https://github.com/MetaCubeX/mihomo) (ядро Clash.Meta, ест VLESS-подписку напрямую) как отдельный Deployment + Service в кластере:

```
                          ┌── terraform.io / hashicorp.com ──► VLESS ──► upstream
NORA pod ──HTTPS_PROXY──► mihomo-proxy:1080
                          └── всё остальное ──► DIRECT (напрямую)
```

Правила маршрутизации в `nora-vless-proxy.yaml` (секция `rules`) отправляют в VLESS только `DOMAIN-SUFFIX,terraform.io` и `DOMAIN-SUFFIX,hashicorp.com`; всё остальное идёт через `DIRECT`. Плюс: не нужен sidecar/kustomize/форк чарта NORA — всё голыми манифестами.

### Шаг 2.1. Заполнить Secret

Отредактируйте в `nora-vless-proxy.yaml` (секция `kind: Secret`):

1. URL подписки в `proxy-providers.sub.url` — ваша VLESS-подписка.

> Аутентификация на mixed-порту в этом манифесте **не включена** — прокси ходит только по доменам terraform/hashicorp, доступ ограничен NetworkPolicy, а пароль в `HTTPS_PROXY` не нужен (см. `helm-values.yaml`).

**Важно: фильтр зарубежных серверов.** HashiCorp гео-блокирует `registry.terraform.io` для IP России, поэтому VLESS-сервер тоже должен находиться вне РФ. В `proxy-groups.auto` уже заданы `filter` / `exclude-filter`, оставляющие только зарубежные серверы (Нидерланды, Германия, Франция, Финляндия и т.д.) и исключающие РФ-серверы. Если ваша подписка использует другие названия стран — отрегулируйте regex под них, иначе mihomo выберет РФ-сервер и terraform upstream останется заблокированным:

```yaml
proxy-groups:
  - name: auto
    type: url-test
    use: [sub]
    filter: "(?i)(Нидерланды|Германия|Франция|Великобритания|Финляндия|Швеция|Польша|Литва|Румыния|Австрия|Швейцария|Норвегия|США|USA|Англия|Европа|EU)"
    exclude-filter: "(?i)Россия|Russia|Москва|СПб|Москва"
    tolerance: 50
    url: https://www.gstatic.com/generate_204
```

### Шаг 2.2. Применить манифест

```bash
kubectl create namespace nora        # если ещё нет
kubectl apply -f nora-vless-proxy.yaml
```

Проверяем, что подписка скачалась:

```bash
kubectl -n nora logs deploy/mihomo-proxy
```

### Шаг 2.3. Переменные прокси уже в helm-values.yaml

Terraform генерирует `helm-values.yaml` из шаблона `helm-values.yaml.tpl` **уже с переменными прокси** (без пароля — аутентификация не используется), поэтому дописывать ничего руками не нужно. Секция `extraEnv` в сгенерированном файле выглядит так:

```yaml
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
  - name: HTTPS_PROXY
    value: "http://mihomo-proxy.nora.svc.cluster.local:1080"
  - name: https_proxy
    value: "http://mihomo-proxy.nora.svc.cluster.local:1080"
  - name: NO_PROXY
    value: "127.0.0.1,localhost,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  - name: no_proxy
    value: "127.0.0.1,localhost,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
```

Так как NORA в этой статье ставится в namespace `default`, а прокси — в `nora`, используется FQDN сервиса `mihomo-proxy.nora.svc.cluster.local`. mihomo сам маршрутизирует: `terraform.io`/`hashicorp.com` → VLESS, остальное → DIRECT.

NORA (reqwest) подхватит env-прокси без изменений кода; в логе при старте появится `Outbound proxy detected from environment` (креды замаскируются).

### Проверка (после установки NORA на шаге 2 в README.md)

```bash
# Запрос к Terraform registry через NORA (reqwest внутри NORA использует HTTPS_PROXY) — должен вернуть 200
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  https://$NORA_FQDN/terraform/v1/providers/hashicorp/aws/versions

# Проверка прокси напрямую из пода NORA: BusyBox wget НЕ читает env-прокси,
# поэтому используем curl из debug-пода (curlimages/curl) с явным -x:
kubectl -n nora run curl-debug --rm -i --restart=Never \
  --image=curlimages/curl:8.10.0 --restart=Never -- \
  curl -sS -x http://mihomo-proxy:1080 -o /dev/null -w "HTTP %{http_code}\n" \
  https://registry.terraform.io/.well-known/terraform.json
# HTTP 200 — прокси пробрасывает terraform.io через VLESS
```

Или просто смотрим, что метрика `nora_upstream_policy_blocked_total {registry="terraform",reason="geo"}` перестала расти.

### Замечания по безопасности

- Аутентификация на mixed-порту mihomo **не включена** — прокси маршрутизирует только terraform/hashicorp домены, остальное идёт напрямую, а доступ к Service ограничен NetworkPolicy.
- NetworkPolicy ограничивает доступ только подами NORA — работает, если CNI поддерживает NetworkPolicy (Calico/Cilium); flannel его игнорирует. Обратите внимание: NetworkPolicy в `nora-vless-proxy.yaml` разрешает доступ только подам из namespace `nora` — так как NORA в этой статье ставится в `default`, политика её не пропустит; при необходимости добавьте `namespaceSelector`.
- Если URL подписки сам заблокирован провайдером: скачайте подписку вручную, вставьте серверы в `proxies:` (формат clash) вместо `proxy-providers` и замените `use: [sub]` на имена/фильтр этих серверов в `proxy-groups`.

## Шаг 3. cert-manager: автоматические TLS-сертификаты

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
    email: admin@sslip.io
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF

kubectl apply -f cluster-issuer.yaml
```

Проверяем:

```bash
kubectl get clusterissuer letsencrypt-prod
# NAME               READY   AGE
# letsencrypt-prod   True    10s
```
