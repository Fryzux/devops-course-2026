#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

DRY_RUN=false
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--dry-run" ]]; then
        DRY_RUN=true
    else
        echo "Ошибка: неизвестный аргумент '$1'" >&2
        echo "Использование: $0 [--dry-run]" >&2
        exit 1
    fi
fi

# Требование 4: Если файл site/index.html отсутствует, доставка не выполняется; сообщение в stderr, код 1
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: обязательный файл '${LOCAL_DIR}index.html' не найден!" >&2
    exit 1
fi

# Требование 5: Если есть незафиксированные изменения (в т.ч. в индексе), доставка не выполняется; код 1
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Ошибка: в репозитории имеются незафиксированные изменения!" >&2
    exit 1
fi

# Требования 3, 8, 9: Синхронизация rsync через одну SSH-сессию, не более 1 соединения, BatchMode без пароля
RSYNC_OPTS=(-avz --delete --chmod=D755,F644 -e "ssh -o BatchMode=yes -o ConnectTimeout=5")

if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] План синхронизации содержимого:"
    rsync "${RSYNC_OPTS[@]}" --dry-run "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"
    echo "[DRY-RUN] План успешно выведен. Состояние сервера не изменено."
    exit 0
fi

echo "Запуск синхронизации каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}/..."
rsync "${RSYNC_OPTS[@]}" "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# Требование 6: Проверка доступности ресурса с верификацией сертификата (без -k)
echo "Проверка доступности ресурса ${SITE_URL}..."
if ! curl -f -s -o /dev/null --cacert "${CA_CERT}" "${SITE_URL}"; then
    echo "Ошибка: ресурс ${SITE_URL} недоступен или сертификат недействителен!" >&2
    exit 1
fi

# Требование 7: Успешное завершение — код 0 с выводом короткого хеша коммита
COMMIT_HASH="$(git rev-parse --short HEAD)"
echo "Деплой успешно завершён. Доставлен коммит: ${COMMIT_HASH}"
exit 0
