# ==============================================================================
# КОНФИГУРАЦИЯ (Можно переопределять при вызове, например: make imager DISK=/dev/nvme1n1)
# ==============================================================================
DISK ?= /dev/nvme0n1
NODE_NAME ?= $(shell hostname)

.PHONY: all help network imager incus clean

# Цель по умолчанию — выводит справку
help:
	@echo "Автоматизация развертывания ноды кластера Incus на Raspberry Pi 5"
	@echo "================================================================="
	@echo "Доступные команды (targets):"
	@echo "  make network   - Настройка сетевого моста br0 через NetworkManager"
	@echo "  make imager    - Авторазметка NVMe (Btrfs) и перенос ОС с MicroSD"
	@echo "  make incus     - Инициализация Incus и добавление ноды в кластер"
	@echo "  make all       - Запуск всех этапов по очереди (полный цикл)"
	@echo ""
	@echo "Переменные окружения (опционально):"
	@echo "  DISK           - Целевой NVMe диск (текущий: $(DISK))"
	@echo "  NODE_NAME      - Имя хоста для кластера Incus (текущее: $(NODE_NAME))"
	@echo ""
	@echo "Примеры использования:"
	@echo "  sudo make network"
	@echo "  sudo make imager DISK=/dev/nvme1n1"
	@echo "  sudo make incus NODE_NAME=rpi5-node3"
	@echo "  sudo make all"

# Полный цикл автоматизации
all: network imager incus
	@echo "================================================================="
	@echo " Все этапы успешно завершены! Перезагрузите Raspberry Pi 5. "
	@echo "================================================================="

# Шаг 1: Настройка сети
network:
	@echo "=== [Makefile] Запуск настройки сетевого моста br0 ==="
	@chmod +x ./nmcli-br0.sh
	./nmcli-br0.sh

# Шаг 2: Разметка диска и миграция ОС на NVMe
imager:
	@echo "=== [Makefile] Запуск разметки диска $(DISK) и миграции системы ==="
	@chmod +x ./rpi5imager.sh
	DISK=$(DISK) ./rpi5imager.sh

# Шаг 3: Переименование (при необходимости) и вступление в кластер Incus
incus:
	@echo "=== [Makefile] Запуск инициализации Incus (Имя хоста: $(NODE_NAME)) ==="
	@chmod +x ./incus-init.sh
	./incus-init.sh --name $(NODE_NAME)

# Очистка (если внутри скриптов создаются временные файлы)
clean:
	@echo "=== [Makefile] Очистка временных файлов ==="
	rm -f /tmp/incus-preseed.*.yaml

