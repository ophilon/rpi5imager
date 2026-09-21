полная пошаговая инструкция, как вручную разметить NVMe, создать структуру Btrfs в стиле Fedora, перенести чистую ОС и настроить загрузчик Raspberry Pi 5.
------------------------------
## Шаг 1. Разметка NVMe-накопителя
Для Raspberry Pi 5 на NVMe-диске нам понадобятся два раздела:

   1. Раздел загрузчика (/boot/firmware): тип FAT32, размер 512 MB.
   2. Раздел системы и данных: тип Btrfs, на всё оставшееся пространство.

Определим имя вашего NVMe-диска (обычно это /dev/nvme0n1). Откройте утилиту разметки:

sudo fdisk /dev/nvme0n1

Последовательность команд внутри fdisk:

   1. Нажмите g — создать новую таблицу разделов GPT.
   2. Нажмите n, затем Enter, Enter, введите +512M — создаем первый раздел.
   3. Нажмите t, затем 1 (тип EFI System или FAT32).
   4. Нажмите n, затем Enter, Enter, Enter — создаем второй раздел на весь остаток диска.
   5. Нажмите w — сохранить изменения и выйти.

------------------------------
## Шаг 2. Создание файловых систем

   1. Форматируем загрузочный раздел в FAT32:
   
   sudo mkfs.vfat -F 32 -n "boot" /dev/nvme0n1p1
   
   2. Форматируем основной раздел в Btrfs:
   
   sudo mkfs.btrfs -L "Debian" -f /dev/nvme0n1p2
   
   
------------------------------
## Шаг 3. Создание структуры субтомов (схема Fedora)
Примонтируем чистый Btrfs-раздел и создадим в нем изолированные субтома:

sudo mount /dev/nvme0n1p2 /mnt
sudo btrfs subvolume create /mnt/root
sudo btrfs subvolume create /mnt/home
sudo btrfs subvolume create /mnt/var

После создания субтомов размонтируем диск:

sudo umount /mnt

------------------------------
## Шаг 4. Подготовка дерева монтирования для копирования ОС
Теперь смонтируем субтома так, как они должны выглядеть в работающей системе, чтобы правильно перенести файлы.

# 1. Монтируем главный корень
sudo mount -o subvol=root,noatime /dev/nvme0n1p2 /mnt
# 2. Создаем точки монтирования внутри нового корня
sudo mkdir -p /mnt/home /mnt/var /mnt/boot/firmware
# 3. Монтируем остальные субтома в эти точки
sudo mount -o subvol=home,noatime /dev/nvme0n1p2 /mnt/home
sudo mount -o subvol=var,noatime /dev/nvme0n1p2 /mnt/var
# 4. Монтируем будущий раздел загрузчика Raspberry Pi
sudo mount /dev/nvme0n1p1 /mnt/boot/firmware

------------------------------
## Шаг 5. Перенос операционной системы с SSD на NVMe
Копируем всю текущую рабочую систему с SSD на подготовленный NVMe. Флаг -x (--one-file-system) критически важен: благодаря ему rsync скопирует саму ОС, но проигнорирует виртуальные папки (/proc, /sys, /dev) и не уйдет в бесконечный цикл, пытаясь скопировать NVMe сам в себя.

sudo rsync -axHAWXS --numeric-ids --info=progress2 / /mnt/

Также необходимо скопировать файлы прошивки и загрузчика на первый раздел. На Raspberry Pi они лежат в /boot/firmware:

sudo rsync -axHAWXS --numeric-ids --info=progress2 /boot/firmware/ /mnt/boot/firmware/

------------------------------
## Шаг 6. Получение UUID разделов
Для настройки конфигурационных файлов нам понадобятся уникальные идентификаторы разделов PARTUUID. Узнаем их с помощью команды:

blkid | grep nvme0n1

Вывод покажет что-то вроде:

/dev/nvme0n1p1: PARTUUID="aaaa-01" TYPE="vfat"
/dev/nvme0n1p2: PARTUUID="aaaa-02" TYPE="btrfs"

Запишите ваши значения aaaa-01 и aaaa-02.
------------------------------
## Шаг 7. Настройка файлов конфигурации на NVMe## 1. Правим /etc/fstab нового диска:

sudo nano /mnt/etc/fstab

Очистите старое содержимое и приведите файл к такому виду (подставив свои PARTUUID):

# Раздел загрузчика Raspberry Pi 5
PARTUUID=aaaa-01  /boot/firmware  vfat    defaults          0       2

# Корневая система (включая /usr)
PARTUUID=aaaa-02  /               btrfs   defaults,subvol=root,noatime  0  1

# Пользовательские данные и логи
PARTUUID=aaaa-02  /home           btrfs   defaults,subvol=home,noatime  0  2
PARTUUID=aaaa-02  /var            btrfs   defaults,subvol=var,noatime   0  2

## 2. Правим параметры запуска ядра в cmdline.txt:

sudo nano /mnt/boot/firmware/cmdline.txt

Удалите всё содержимое строки и вставьте следующую конфигурацию строго в одну строчку без переносов:

console=serial0,115200 console=tty1 root=PARTUUID=aaaa-02 rootfstype=btrfs rootflags=subvol=root rw rootwait

(Здесь aaaa-02 — это PARTUUID именно второго (Btrfs) раздела).
------------------------------
## Шаг 8. Генерация initramfs через Chroot
Чтобы ядро Raspberry Pi 5 смогло прочитать Btrfs на NVMe при старте, нам нужно собрать полноценный образ инициализации (initrd) внутри новой среды.

   1. Связываем виртуальные файловые системы текущего SSD с NVMe:
   
   sudo mount --bind /dev /mnt/dev
   sudo mount --bind /sys /mnt/sys
   sudo mount --bind /proc /mnt/proc
   
   2. Входим в окружение NVMe-диска:
   
   sudo chroot /mnt
   
   3. Включаем сборку всех необходимых модулей в initramfs. Открываем файл:
   
   nano /etc/initramfs-tools/initramfs.conf
   
   Убеждаемся, что строка с модулями выглядит так: MODULES=most
   4. Генерируем новый загрузочный образ для ядра (команда автоматически подставит текущую версию):
   
   update-initramfs -c -k $(uname -r)
   
   5. Проверяем, чтобы созданный файл (например, initrd.img-6.x.x-v8+) появился в папке /boot/firmware/. Если его там нет, скопируйте его туда вручную:
   
   cp /boot/initrd.img-* /boot/firmware/
   
   6. Убеждаемся, что в конфигурационном файле Raspberry Pi прописан запуск этого образа. Открываем файл:
   
   nano /boot/firmware/config.txt
   
   В самом конце файла должна быть активна строка с точным именем вашего файла (или универсальный параметр для RPi):
   
   initramfs initrd.img-6.6.31+v8 followkernel
   
   (Замените initrd.img-6.6.31+v8 на точное имя файла, который у вас сгенерировался в /boot/firmware/).
   7. Выходим из изолированной среды:
   
   exit
   
   
------------------------------
## Шаг 9. Завершение и перезагрузка
Размонтируем все разделы, чтобы сбросить кэш записи на NVMe:

sudo umount -R /mnt
