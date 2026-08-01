# Инструкция для AI-агента / LLM

## Контекст проекта

Этот репозиторий разворачивает NORA (artifact registry на Rust) в Kubernetes на Yandex Cloud через Terraform + Helm. Подробное описание всех шагов и команд — в [README.md](README.md).

## Развёртывание (шаги 1–5)

После `terraform init && terraform apply` выполни шаги 2–5 из README.md по порядку:
1. Получи доступ к кластеру: `yc managed-kubernetes cluster get-credentials --id $(terraform output -raw k8s_cluster_id) --external --force`
2. Запроси подписку для VLESS-прокси (mihomo) для обхода гео-блокировки HashiCorp — манифест `nora-vless-proxy.yaml`
3. cert-manager + ClusterIssuer `letsencrypt-prod`
4. Аутентификация: `users.htpasswd` → Secret `nora-htpasswd`, плюс `secret_for_bucket.yaml` → Secret `nora-s3-credentials`
5. Деплой NORA через Helm: `helm upgrade --install nora nora/nora --version 0.4.4 -f helm-values.yaml`

После каждого шага проверяй статус подов, логи, ClusterIssuer/Certificate.

## Тестирование 15 форматов

После выполнения шагов 1–5 и получения доступа к кластеру переходи к тестированию всех 15 форматов из раздела «Использование: примеры для каждого формата» в README.md. Порядок действий:

1. **Пароль `your-password` — литерал.** В команде `htpasswd -Bbc users.htpasswd admin your-password` (шаг 4) и в запросе на создание токена пароль равен строке `your-password`. Воспринимай его буквально, не запрашивай у пользователя.
2. **Создай токен** командой из README:
   ```bash
   curl -X POST https://$NORA_FQDN/api/tokens \
     -H "Content-Type: application/json" \
     -d '{
       "username": "admin",
       "password": "your-password",
       "role": "write",
       "ttl_days": 90,
       "description": "CI/CD pipeline token"
     }'
   ```
   Извлеки значение `token` из JSON-ответа (вид `nra_...`).
3. **Замени плейсхолдер** `nra_91cf14d4a7994f97891f61653214fb05` во всём README на полученный токен (используй replaceAll). Если токен уже совпадает с плейсхолдером — пропускай шаг.
4. **Тестируй форматы по очереди** в порядке разделов: Docker, npm, PyPI, Maven, Helm OCI, Go, Cargo, Terraform, RubyGems, NuGet, Ansible Galaxy, Conan, Pub, Raw, RPM, Debian/APT. Для каждого:
   - выполни команды из раздела (login → push/publish → pull/install);
   - проверяй статус выхода команд и вывод;
   - при ошибке — запиши её в файл `nora-test-errors.log` в корне репозитория, посмотри логи `kubectl logs deploy/nora` и `kubectl -n nora logs deploy/mihomo-proxy`, попробуй исправить;
   - если инструмент не установлен (например, `dotnet`, `conan`, `dart`, `gem`) — пропусти формат с пометкой в `nora-test-errors.log`, не останавливай тестирование остальных. В конце тестирования опиши ошибки согласно файлу `nora-test-errors.log`.

## Важно

- **Не коммить** изменения, если явно не просят. Файл `nora-test-errors.log` тоже не коммить.
- **VLESS-прокси**: URL подписки в `nora-vless-proxy.yaml` не коммитить — вставлять локально только при применении манифеста.
- Перед завершением работы проверяй `git status` / `git diff --cached` на отсутствие секретов (подписки, токенов) в staging.
