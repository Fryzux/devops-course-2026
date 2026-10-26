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
# источник данных: sudo ufw status verbose | grep Default
default_incoming=$(sudo ufw status verbose | awk '/Default:/{print $2}')
check "Политика по умолчанию для входящего трафика равна deny" "deny" "$default_incoming"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
# а) служба nginx активна (systemctl is-active nginx)
check "Служба Nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null || echo 'inactive')"

# б) конфигурация nginx синтаксически корректна (код возврата sudo nginx -t)
if sudo nginx -t >/dev/null 2>&1; then
    check "Конфигурация Nginx синтаксически корректна" "valid" "valid"
else
    check "Конфигурация Nginx синтаксически корректна" "valid" "syntax-error"
fi

# в) сертификат /etc/ssl/certs/devops.crt истекает не ранее чем через 30 дней (30 дней = 2592000 сек)
CERT_FILE="/etc/ssl/certs/devops.crt"
if [[ -f "$CERT_FILE" ]] && openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
    check "Сертификат TLS действителен более 30 дней" "valid" "valid"
else
    check "Сертификат TLS действителен более 30 дней" "valid" "expired-or-missing"
fi

# г) в каталоге ресурса нет файлов с правами записи для всех (find -perm -o+w) и права ключа равны 600
KEY_FILE="/etc/ssl/private/devops.key"
WORLD_WRITABLE=$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l)
KEY_PERMS=$(sudo stat -c '%a' "$KEY_FILE" 2>/dev/null || echo "000")

if [[ "$WORLD_WRITABLE" -eq 0 && "$KEY_PERMS" == "600" ]]; then
    check "Безопасность каталога (нет o+w) и права ключа 600" "secure" "secure"
else
    check "Безопасность каталога (нет o+w) и права ключа 600" "secure" "insecure (o+w: $WORLD_WRITABLE, key: $KEY_PERMS)"
fi

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
