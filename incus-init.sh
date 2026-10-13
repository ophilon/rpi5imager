#!/usr/bin/env bash

# Выходить немедленно, если какая-либо команда завершится с ошибкой
set -e

# ==============================================================================
# КОНФИГУРАЦИЯ КЛАСТЕРА ЧЕРЕЗ DNS (ИМЕНА ХОСТОВ)
# ==============================================================================
# FQDN или имя хоста лидера кластера (например, "lenold" или "lenold.local")
CLUSTER_LEADER_HOST="lenold"
CLUSTER_TARGET_PORT="8443"

# Токен присоединения, полученный на лидере кластера через: incus cluster add <имя_ноды>
CLUSTER_JOIN_TOKEN="ВАШ_ТОКЕН_ПРИСОЕДИНЕНИЯ_ЗДЕСЬ"

# Сетевой интерфейс моста
BRIDGE_NAME="br0"

# ==============================================================================
# ФУНКЦИЯ СПРАВКИ
# ==============================================================================
show_usage() {
  echo "Использование: sudo $0 [-n новое_имя_хоста] [--name новое_имя_хоста]"
  echo "  -n, --name    Изменить имя хоста системы (hostnamectl) перед вступлением в кластер"
  echo "  -h, --help    Показать эту справку"
  exit 0
}

# ==============================================================================
# ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ==============================================================================
NEW_HOSTNAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
  -n | --name)
    if [[ -n "$2" && "$2" != -* ]]; then
      NEW_HOSTNAME="$2"
      shift 2
    else
      echo "Ошибка: Опция $1 требует указания имени хоста." >&2
      exit 1
    fi
    ;;
  -h | --help)
    show_usage
    ;;
  *)
    echo "Ошибка: Неизвестный параметр $1" >&2
    show_usage
    ;;
  esac
done

# ==============================================================================
# ЛОГИКА АВТОМАТИЗАЦИИ
# ==============================================================================

# Проверка запуска от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Пожалуйста, запустите этот скрипт с sudo." >&2
  exit 1
fi

# Если передана опция смены имени хоста
if [ -n "$NEW_HOSTNAME" ]; then
  echo "=== 0. Изменение имени хоста на '$NEW_HOSTNAME' ==="
  hostnamectl set-hostname "$NEW_HOSTNAME"
  # Обновляем локальную сессию скрипта, чтобы использовать новое имя
  NODE_NAME="$NEW_HOSTNAME"
  echo "Имя хоста успешно изменено. dnsmasq обновит запись при следующем DHCP-запросе или перезапуске сети."
else
  # Автоматически определяем текущее локальное имя хоста
  NODE_NAME=$(hostname)
fi

echo "=== 1. Проверка разрешения имен в DNS ==="
if ! host "$CLUSTER_LEADER_HOST" &>/dev/null && ! ping -c 1 "$CLUSTER_LEADER_HOST" &>/dev/null; then
  echo "Ошибка: Имя лидера кластера '$CLUSTER_LEADER_HOST' не резолвится через DNS (dnsmasq)." >&2
  exit 1
fi
echo "Успешно: Лидер кластера '$CLUSTER_LEADER_HOST' доступен по сети."

echo "=== 2. Создание конфигурации Preseed (Hostname mode) ==="
PRESEED_FILE=$(mktemp /tmp/incus-preseed.XXXXXX.yaml)

cat <<EOF >"$PRESEED_FILE"
cluster:
  server_name: "${NODE_NAME}"
  # Указываем имя хоста текущей ноды вместо IP-адреса
  server_address: "${NODE_NAME}:${CLUSTER_TARGET_PORT}"
  cluster_password: ""
  # Указываем имя хоста лидера кластера для подключения
  cluster_endpoint: "${CLUSTER_LEADER_HOST}:${CLUSTER_TARGET_PORT}"
  enabled: true
  roles: []
  join_token: "${CLUSTER_JOIN_TOKEN}"
config:
  core.https_address: ":8443"
networks: []
storage_pools: []
profiles:
  - name: default
    devices:
      root:
        path: /
        pool: default
        type: disk
      eth0:
        name: eth0
        nictype: bridged
        parent: "${BRIDGE_NAME}"
        type: nic
EOF

echo "Конфигурация сгенерирована во временном файле: $PRESEED_FILE"

echo "=== 3. Инициализация и присоединение к кластеру ==="
cat "$PRESEED_FILE" | incus admin init --preseed

echo "=== 4. Очистка временных файлов ==="
rm -f "$PRESEED_FILE"

echo "=============================================================================="
echo " Нода '${NODE_NAME}' успешно подключена к кластеру по имени хоста! "
echo "=============================================================================="
