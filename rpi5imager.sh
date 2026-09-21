#!/usr/bin/env bash
#
# rpi5imager.sh — перенос ОС Raspberry Pi 5 с SSD на NVMe.
# Автоматизирует шаги 2–9 из README.md. Шаг 1 (разметка диска) выполняется
# вручную — скрипт проверяет наличие разделов и при необходимости ждёт.
#
# Использование:
#   sudo ./rpi5imager.sh
#   DISK=/dev/nvme1n1 sudo ./rpi5imager.sh   # указать другой диск
#

set -euo pipefail

# ---------- Конфигурация ----------
DISK="${DISK:-/dev/nvme0n1}"
BOOT_PART="${DISK}p1"
ROOT_PART="${DISK}p2"
MOUNT="/mnt"
BOOT_MOUNT="${MOUNT}/boot/firmware"

# ---------- Утилиты вывода ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

confirm() {
    local prompt="$1" answer
    read -r -p "$prompt [y/N] " answer
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# При ошибке или прерывании аккуратно размонтируем дерево
cleanup() {
    if mountpoint -q "$MOUNT" 2>/dev/null; then
        warn "Прерывание. Размонтирую $MOUNT..."
        umount -R "$MOUNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------- Проверки ----------
[[ $EUID -eq 0 ]] || die "Скрипт требует прав root. Запустите: sudo $0"

for cmd in mkfs.vfat mkfs.btrfs btrfs rsync blkid chroot; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдена утилита: $cmd"
done

# ---------- Шаг 1 (вручную): проверка разметки ----------
log "Проверяю разделы $BOOT_PART и $ROOT_PART на $DISK..."
if [[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" ]]; then
    warn "Разделы не найдены. Выполните разметку диска $DISK вручную:"
    echo "  sudo fdisk $DISK"
    echo "    1. g — создать таблицу разделов GPT"
    echo "    2. n, Enter, Enter, +512M — первый раздел (загрузчик)"
    echo "    3. t, 1 — тип EFI System"
    echo "    4. n, Enter, Enter, Enter — второй раздел на весь остаток"
    echo "    5. w — сохранить изменения и выйти"
    read -r -p "Нажмите Enter, когда разметка будет завершена..."
    [[ -b "$BOOT_PART" && -b "$ROOT_PART" ]] || die "Разделы так и не появились. Прерываю."
fi

# ---------- Шаг 2. Создание файловых систем ----------
log "Шаг 2. Создание файловых систем (FAT32 + Btrfs)"
confirm "Форматировать $BOOT_PART (FAT32) и $ROOT_PART (Btrfs)? Все данные на них будут удалены!" \
    || die "Отменено пользователем."
mkfs.vfat -F 32 -n "boot" "$BOOT_PART"
mkfs.btrfs -L "Debian" -f "$ROOT_PART"

# ---------- Шаг 3. Создание субтомов (схема Fedora) ----------
log "Шаг 3. Создание субтомов root/home/var"
mount "$ROOT_PART" "$MOUNT"
btrfs subvolume create "$MOUNT/root"
btrfs subvolume create "$MOUNT/home"
btrfs subvolume create "$MOUNT/var"
umount "$MOUNT"

# ---------- Шаг 4. Подготовка дерева монтирования ----------
log "Шаг 4. Подготовка дерева монтирования"
mount -o subvol=root,noatime "$ROOT_PART" "$MOUNT"
mkdir -p "$BOOT_MOUNT" "$MOUNT/home" "$MOUNT/var"
mount -o subvol=home,noatime "$ROOT_PART" "$MOUNT/home"
mount -o subvol=var,noatime "$ROOT_PART" "$MOUNT/var"
mount "$BOOT_PART" "$BOOT_MOUNT"

# ---------- Шаг 5. Перенос ОС с SSD на NVMe ----------
log "Шаг 5. Перенос ОС с SSD на NVMe"
confirm "Начать копирование системы с / в $MOUNT? Это может занять много времени." \
    || die "Отменено пользователем."
rsync -axHAWXS --numeric-ids --info=progress2 / "$MOUNT/"
rsync -axHAWXS --numeric-ids --info=progress2 /boot/firmware/ "$BOOT_MOUNT/"

# ---------- Шаг 6. Получение PARTUUID ----------
log "Шаг 6. Получение PARTUUID разделов"
BOOT_UUID="$(blkid -s PARTUUID -o value "$BOOT_PART")"
ROOT_UUID="$(blkid -s PARTUUID -o value "$ROOT_PART")"
[[ -n "$BOOT_UUID" && -n "$ROOT_UUID" ]] || die "Не удалось получить PARTUUID разделов."
log "Boot-раздел:  PARTUUID=$BOOT_UUID"
log "Корневой:     PARTUUID=$ROOT_UUID"

# ---------- Шаг 7. Настройка /etc/fstab и cmdline.txt ----------
log "Шаг 7. Настройка /etc/fstab и cmdline.txt"
cat > "$MOUNT/etc/fstab" <<EOF
# Раздел загрузчика Raspberry Pi 5
PARTUUID=$BOOT_UUID  /boot/firmware  vfat    defaults          0       2

# Корневая система (включая /usr)
PARTUUID=$ROOT_UUID  /               btrfs   defaults,subvol=root,noatime  0  1

# Пользовательские данные и логи
PARTUUID=$ROOT_UUID  /home           btrfs   defaults,subvol=home,noatime  0  2
PARTUUID=$ROOT_UUID  /var            btrfs   defaults,subvol=var,noatime   0  2
EOF

echo "console=serial0,115200 console=tty1 root=PARTUUID=$ROOT_UUID rootfstype=btrfs rootflags=subvol=root rw rootwait" \
    > "$BOOT_MOUNT/cmdline.txt"

# ---------- Шаг 8. Генерация initramfs через chroot ----------
log "Шаг 8. Генерация initramfs через chroot"
mount --bind /dev "$MOUNT/dev"
mount --bind /sys "$MOUNT/sys"
mount --bind /proc "$MOUNT/proc"

# Включаем сборку всех необходимых модулей в initramfs
sed -i 's/^MODULES=.*/MODULES=most/' "$MOUNT/etc/initramfs-tools/initramfs.conf"

# Генерируем новый загрузочный образ для ядра внутри новой среды
chroot "$MOUNT" /bin/bash -c 'update-initramfs -c -k "$(uname -r)"'

# Копируем образ initrd в /boot/firmware
chroot "$MOUNT" /bin/bash -c 'cp -fv /boot/initrd.img-* /boot/firmware/'

# Прописываем initramfs в config.txt
INITRD_FILE="$(basename "$(ls "$BOOT_MOUNT"/initrd.img-* 2>/dev/null | head -n1)")"
[[ -n "$INITRD_FILE" ]] || die "initrd не найден в $BOOT_MOUNT"

if grep -q "^initramfs " "$BOOT_MOUNT/config.txt"; then
    sed -i "s|^initramfs .*|initramfs $INITRD_FILE followkernel|" "$BOOT_MOUNT/config.txt"
    log "Обновлена строка в config.txt: initramfs $INITRD_FILE followkernel"
else
    echo "initramfs $INITRD_FILE followkernel" >> "$BOOT_MOUNT/config.txt"
    log "Добавлена строка в config.txt: initramfs $INITRD_FILE followkernel"
fi

# ---------- Шаг 9. Завершение и размонтирование ----------
log "Шаг 9. Завершение: размонтирование"
umount -R "$MOUNT"

log "Готово! Можно перезагружать Raspberry Pi 5 с NVMe."