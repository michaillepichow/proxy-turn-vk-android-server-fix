#!/bin/bash
set -euo pipefail

# !!! если служба называется не wdtt то скрипт спросит название службы и по Enter выберет wdtt !!!

# Определяем папку, откуда запущен скрипт
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLD_CONFIG_DIR="/etc/wdtt"
OLD_ACCESS_DB="passwords.json"
OLD_WG_KEYS_DB="wg-keys.dat"
DEFAULT_SERVICE_NAME="wdtt"
DEFAULT_DTLS_PORT="56000"
DEFAULT_WG_PORT="56001"
DEFAULT_CLIENT_CIDR="10.66.66.0/24"

escape_env_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

validate_env_file() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        echo "[Ошибка] Файл $env_file не найден." >&2
        return 1
    fi

    echo "Проверка содержимого $env_file..."
    local required_vars=(WDTT_DTLS_PORT WDTT_WG_PORT WDTT_ARGS WDTT_CLIENT_CIDR)
    local missing=0

    for var in "${required_vars[@]}"; do
        if ! grep -Eq "^${var}=" "$env_file"; then
            echo "[Ошибка] В $env_file отсутствует переменная $var." >&2
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        return 1
    fi

    echo "Содержимое $env_file:"
    cat "$env_file"
    echo "Проверка .env завершена."
}

echo "=== Запуск скрипта миграции WDTT в Docker ==="

echo -n "Введите имя systemd-службы для миграции [${DEFAULT_SERVICE_NAME}]: "
read -r SERVICE_NAME
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
OLD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo "[Ошибка] Скрипт должен быть запущен от имени root." >&2
    exit 1
fi

# Проверка наличия нужных файлов рядом со скриптом
for f in "Dockerfile" "entrypoint.sh" "docker-compose.yml"; do
    if [ ! -f "$WORK_DIR/$f" ]; then
        echo "[Ошибка] Файл $f не найден в папке $WORK_DIR!" >&2
        exit 1
    fi
done

# Чтение текущих настроек из systemd
echo "Чтение старой конфигурации из systemd..."
DTLS_PORT="$DEFAULT_DTLS_PORT"
WG_PORT="$DEFAULT_WG_PORT"
WDTT_ARGS=""
CLIENT_CIDR="${WDTT_CLIENT_CIDR:-$DEFAULT_CLIENT_CIDR}"

if [ -f "$OLD_SERVICE_FILE" ]; then
    DTLS_PORT=$(sed -nE 's/.*-listen[[:space:]]+[^:[:space:]]+:([0-9]+).*/\1/p' "$OLD_SERVICE_FILE" | head -n1)
    if [ -z "$DTLS_PORT" ]; then
        DTLS_PORT="$DEFAULT_DTLS_PORT"
    fi

    WG_PORT=$(sed -nE 's/.*-wg-port[[:space:]]+([0-9]+).*/\1/p' "$OLD_SERVICE_FILE" | head -n1)
    if [ -z "$WG_PORT" ]; then
        WG_PORT="$DEFAULT_WG_PORT"
    fi

    WDTT_ARGS=$(sed -nE "s/.*-config-dir[[:space:]]+[\"']?\/etc\/wdtt[\"']?[[:space:]]+(.*)/\\1/p" "$OLD_SERVICE_FILE" | head -n1)
    if [ -z "$WDTT_ARGS" ]; then
        WDTT_ARGS=""
    fi

    if [ -z "${WDTT_CLIENT_CIDR:-}" ]; then
        CLIENT_CIDR=$(sed -nE "s/.*--?client-cidr[[:space:]]+[\"']?([^\"'[:space:]]+)[\"']?.*/\\1/p" "$OLD_SERVICE_FILE" | head -n1)
        if [ -z "$CLIENT_CIDR" ]; then
            CLIENT_CIDR="$DEFAULT_CLIENT_CIDR"
        fi
    fi

    echo "  -> Найден порт DTLS: $DTLS_PORT"
    echo "  -> Найден порт WG: $WG_PORT"
    echo "  -> Найдены аргументы: $WDTT_ARGS"
    echo "  -> Используется клиентская подсеть: $CLIENT_CIDR"
else
    echo "  -> Служба не найдена, используем порты по умолчанию."
fi

# Запрос портов у пользователя; пустой ввод сохраняет автоматически найденное значение.
echo -n "Введите DTLS-порт [$DTLS_PORT]: "
read -r INPUT_DTLS_PORT
DTLS_PORT="${INPUT_DTLS_PORT:-$DTLS_PORT}"

echo -n "Введите WG-порт [$WG_PORT]: "
read -r INPUT_WG_PORT
WG_PORT="${INPUT_WG_PORT:-$WG_PORT}"

# Создание файла .env для Docker Compose
echo "Создание файла .env с переменными окружения..."
cat > "$WORK_DIR/.env" <<EOF
WDTT_DTLS_PORT="$(escape_env_value "$DTLS_PORT")"
WDTT_WG_PORT="$(escape_env_value "$WG_PORT")"
WDTT_ARGS="$(escape_env_value "$WDTT_ARGS")"
WDTT_CLIENT_CIDR="$(escape_env_value "${WDTT_CLIENT_CIDR:-$CLIENT_CIDR}")"
EOF

validate_env_file "$WORK_DIR/.env" || exit 1

# Перенос базы данных
echo "Перенос конфигурации в $WORK_DIR/config..."
mkdir -p "$WORK_DIR/config"
for cfg_file in "$OLD_ACCESS_DB" "$OLD_WG_KEYS_DB"; do
    if [ -f "${OLD_CONFIG_DIR}/${cfg_file}" ]; then
        cp "${OLD_CONFIG_DIR}/${cfg_file}" "$WORK_DIR/config/"
        chmod 600 "$WORK_DIR/config/${cfg_file}"
        echo "  -> Файл ${cfg_file} успешно скопирован."
    else
        echo "  -> Файл ${cfg_file} не найден."
    fi
done

# Проверяем доступность Docker
if ! command -v docker &>/dev/null; then
    echo "[Ошибка] Docker не найден в PATH. Установите Docker вручную и повторите миграцию." >&2
    exit 1
fi

# Запуск Docker
# Сначала собираем образ при работающей старой службе, чтобы избежать конфликта портов.
echo "Сборка контейнера из $WORK_DIR..."
cd "$WORK_DIR"
if ! docker compose build; then
    echo "[Ошибка] Не удалось собрать контейнер. Старый сервис не был остановлен." >&2
    exit 1
fi

# Сначала останавливаем старую службу, затем выполняем очистку хоста
# и только после этого запускаем новый контейнер.
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Остановка старой службы $SERVICE_NAME (освобождение портов)..."
    systemctl stop "$SERVICE_NAME" || true
fi

# Удаление старых системных файлов
# Эти шаги должны быть завершены до запуска контейнера, чтобы исключить гонку.
echo "Очистка системных файлов (systemd, бинарник, сетевой интерфейс)..."
if systemctl is-enabled --quiet "$SERVICE_NAME"; then
    systemctl disable "$SERVICE_NAME" || true
fi
mv "$OLD_SERVICE_FILE" "${OLD_SERVICE_FILE}.bak" 2>/dev/null || true
systemctl daemon-reload
mv /usr/local/bin/wdtt-server /usr/local/bin/wdtt-server.bak 2>/dev/null || true

if ip link show wdtt0 &>/dev/null; then
    ip link del wdtt0 || true
fi

# Защита от случайной потери правил хоста: по умолчанию пропускаем очистку iptables.
if [ "${WDTT_CLEAN_IPTABLES:-0}" = "1" ]; then
    if command -v iptables-save &>/dev/null && command -v iptables-restore &>/dev/null; then
        echo "Очистка правил iptables на хосте..."
        iptables-save | grep -vE "WDTT_(MANAGED|MIRRORED)" | iptables-restore || true
    fi
else
    echo "Пропускаем очистку iptables на хосте, чтобы не удалить посторонние правила."
fi

echo "Запуск контейнера..."
if ! docker compose up -d; then
    echo "[Ошибка] Не удалось запустить контейнер." >&2
    exit 1
fi

echo ""
echo "МИГРАЦИЯ ЗАВЕРШЕНА!"
echo "Контейнер запущен, логи можно посмотреть командой:"
echo "cd $WORK_DIR && docker compose logs -f"