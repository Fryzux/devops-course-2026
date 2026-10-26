#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK] $desc"
        ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
        ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

# TODO 1: проверьте, что значение параметра port отлично от 22
ssh_port=$(sudo sshd -T | awk '/^port/{print $2}')
if [[ "$ssh_port" != "22" ]]; then
    check "Порт SSH отличен от 22 (текущий: $ssh_port)" "not 22" "not 22"
else
    check "Порт SSH отличен от 22" "not 22" "$ssh_port"
fi

# TODO 2: проверьте, что значение параметра maxauthtries равно 3
check "Лимит попыток аутентификации равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

# TODO 3: проверьте, что политика по умолчанию для входящего трафика равна deny
default_incoming=$(sudo ufw status verbose | awk '/Default:/{print $2}')
check "Политика по умолчанию для входящего трафика равна deny" "deny" "$default_incoming"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба Nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null || echo 'inactive')"

if sudo nginx -t >/dev/null 2>&1; then
    check "Конфигурация Nginx синтаксически корректна" "valid" "valid"
else
    check "Конфигурация Nginx синтаксически корректна" "valid" "syntax-error"
fi

CERT_FILE="/etc/ssl/certs/devops.crt"
if [[ -f "$CERT_FILE" ]] && openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
    check "Сертификат TLS действителен более 30 дней" "valid" "valid"
else
    check "Сертификат TLS действителен более 30 дней" "valid" "expired-or-missing"
fi

KEY_FILE="/etc/ssl/private/devops.key"
WORLD_WRITABLE=$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l)
KEY_PERMS=$(sudo stat -c '%a' "$KEY_FILE" 2>/dev/null || echo "000")

if [[ "$WORLD_WRITABLE" -eq 0 && "$KEY_PERMS" == "600" ]]; then
    check "Безопасность каталога (нет o+w) и права ключа 600" "secure" "secure"
else
    check "Безопасность каталога (нет o+w) и права ключа 600" "secure" "insecure (o+w: $WORLD_WRITABLE, key: $KEY_PERMS)"
fi

echo "[5] Контейнеризация"
# а) служба docker активна (systemctl is-active docker)
check "Служба Docker активна" "active" "$(systemctl is-active docker 2>/dev/null || echo 'inactive')"

# б) контейнер СУБД находится в состоянии healthy (docker inspect -f '{{.State.Health.Status}}' app-db-1)
db_status=$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo 'missing')
check "Контейнер СУБД в состоянии healthy" "healthy" "$db_status"

# в) порты 5000 и 5432 не прослушиваются ни на одном адресе, кроме 127.0.0.1 (ss -tln)
exposed_ports=$(ss -tln | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | wc -l)
if [[ "$exposed_ports" -eq 0 ]]; then
    check "Порты 5000 и 5432 доступны только на 127.0.0.1" "isolated" "isolated"
else
    check "Порты 5000 и 5432 доступны только на 127.0.0.1" "isolated" "exposed ($exposed_ports non-local sockets)"
fi

# г) права файла ~/app/.env равны 600 (stat -c '%a')
ENV_FILE="/home/devops/app/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$HOME/app/.env"
if [[ -f "$ENV_FILE" ]]; then
    env_perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "000")
    check "Права файла .env равны 600" "600" "$env_perms"
else
    check "Права файла .env равны 600" "600" "missing"
fi

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
