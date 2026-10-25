#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  Archer installer — run from the Arch Linux live ISO, as root:
#    curl -fsSL https://kvxnomxyz.github.io/archer/install.sh | bash
#    wget -qO- https://kvxnomxyz.github.io/archer/install.sh | bash
#  Pin a version:  ARCHER_VERSION=v0.1.0 bash install.sh
#
#  Flow: prompts -> partition -> pacstrap -> chroot (base config)
#        -> download post-live-iso.sh + first-boot service -> reboot
# ─────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

ARCHER_REPO="${ARCHER_REPO:-kvxnomxyz/archer}"
ARCHER_VERSION="${ARCHER_VERSION:-latest}"
if [[ $ARCHER_VERSION == latest ]]; then
  ARCHER_DL="https://github.com/$ARCHER_REPO/releases/latest/download"
else
  ARCHER_DL="https://github.com/$ARCHER_REPO/releases/download/$ARCHER_VERSION"
fi
CYAN=$'\e[36m'; RED=$'\e[31m'; DIM=$'\e[2m'; OFF=$'\e[0m'
LOG=/tmp/archer-install.log

logo() {
  printf '%s' "$CYAN"
  cat <<'LOGO'
    _             _
   / \   _ __ ___| |__   ___ _ __
  / _ \ | '__/ __| '_ \ / _ \ '__|
 / ___ \| | | (__| | | |  __/ |
/_/   \_\_|  \___|_| |_|\___|_|
LOGO
  printf '  >>>--------------------------->  %sArch, aimed at you.%s\n\n' "$DIM" "$OFF"
}
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }
step() { printf '\n%s==>%s %s\n' "$CYAN" "$OFF" "$*"; }
trap 'die "Install failed at line $LINENO (log: $LOG)"' ERR

# ── Preflight ────────────────────────────────────────────────────────
clear; logo
[[ $EUID -eq 0 ]]                         || die "Run as root (you are on the live ISO)."
[[ -d /sys/firmware/efi/efivars ]]        || die "UEFI boot required."
ping -c1 -W3 archlinux.org &>/dev/null    || die "No internet. Plug in ethernet or use iwctl."

sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
pacman -Sy --noconfirm --needed gum >/dev/null

# ── Preferences ──────────────────────────────────────────────────────
DISK=$(lsblk -dpno NAME,SIZE,MODEL -e7,11 | gum choose --header "Install disk (WILL BE ERASED)" | awk '{print $1}')

HOST_NAME=$(gum input --header "Hostname" --value archer)
while :; do
  NEW_USER=$(gum input --header "Username" --placeholder "lowercase, no spaces")
  [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]*$ ]] && break
  gum style --foreground 196 "Invalid username."
done
while :; do
  PASSWORD=$(gum input --password --header "Password")
  [[ -n $PASSWORD && $PASSWORD == "$(gum input --password --header "Confirm password")" ]] && break
  gum style --foreground 196 "Empty or mismatched."
done

TIMEZONE=$(timedatectl list-timezones | gum filter --header "Timezone" --placeholder "e.g. Europe/Warsaw")
LOCALE=$(awk '/UTF-8/{print $1}' /usr/share/i18n/SUPPORTED | gum filter --header "Locale" --value en_US.UTF-8)
KEYMAP=$(localectl list-keymaps | gum filter --header "Keyboard layout" --value us)

FS=$(gum choose --header "Filesystem" btrfs ext4)
KERNEL=$(gum choose --header "Kernel" linux linux-zen linux-lts)
DESKTOP=$(gum choose --header "Desktop" hyprland sway kde gnome none)
BUNDLES=$(gum choose --no-limit --header "Software bundles (space = toggle)" \
  dev gaming creator office media | tr '\n' ' ') || true
PLUGINS=$(gum input --header "Archer plugins (names or git URLs, space-separated, optional)" --placeholder "e.g. nvidia-tweaks https://github.com/me/my-plugin") || true

case "$(grep -m1 vendor_id /proc/cpuinfo)" in
  *Intel*) UCODE=intel-ucode ;;
  *AMD*)   UCODE=amd-ucode ;;
  *)       UCODE="" ;;
esac

clear; logo
gum style --border rounded --padding "0 2" --border-foreground 6 \
  "Disk:      $DISK ($FS)" "Host:      $HOST_NAME" "User:      $NEW_USER" \
  "Locale:    $LOCALE / $KEYMAP / $TIMEZONE" "Kernel:    $KERNEL" \
  "Desktop:   $DESKTOP" "Bundles:   ${BUNDLES:-none}" "Plugins:   ${PLUGINS:-none}"
gum confirm --default=false "Erase $DISK and install Archer?" || die "Aborted."

exec > >(tee -a "$LOG") 2>&1

# ── Partition + format + mount ───────────────────────────────────────
step "Partitioning $DISK"
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISK" >/dev/null
sgdisk --zap-all "$DISK" >/dev/null
sgdisk -n1:0:+1G -t1:ef00 -c1:ESP -n2:0:0 -t2:8300 -c2:ROOT "$DISK" >/dev/null
partprobe "$DISK"; sleep 2

if [[ $DISK =~ [0-9]$ ]]; then P="${DISK}p"; else P="$DISK"; fi
ESP_PART="${P}1"; ROOT_PART="${P}2"

mkfs.fat -F32 "$ESP_PART" >/dev/null
if [[ $FS == btrfs ]]; then
  mkfs.btrfs -fq "$ROOT_PART"
  mount "$ROOT_PART" /mnt
  for sv in @ @home @log @pkg @snapshots; do btrfs subvolume create "/mnt/$sv" >/dev/null; done
  umount /mnt
  O="noatime,compress=zstd"
  mount -o "$O,subvol=@" "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
  mount -o "$O,subvol=@home"      "$ROOT_PART" /mnt/home
  mount -o "$O,subvol=@log"       "$ROOT_PART" /mnt/var/log
  mount -o "$O,subvol=@pkg"       "$ROOT_PART" /mnt/var/cache/pacman/pkg
  mount -o "$O,subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
else
  mkfs.ext4 -qF "$ROOT_PART"
  mount "$ROOT_PART" /mnt
  mkdir -p /mnt/boot
fi
mount "$ESP_PART" /mnt/boot

# ── Base system ──────────────────────────────────────────────────────
step "Installing base system (this takes a while)"
PKGS=(base "$KERNEL" "${KERNEL}-headers" linux-firmware base-devel git curl sudo nano
      networkmanager efibootmgr dosfstools pciutils man-db)
[[ -n $UCODE ]]    && PKGS+=("$UCODE")
[[ $FS == btrfs ]] && PKGS+=(btrfs-progs)
pacstrap -K /mnt "${PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# Save choices for chroot + post-install (no password stored)
mkdir -p /mnt/etc/archer
{
  for v in HOST_NAME NEW_USER TIMEZONE LOCALE KEYMAP FS KERNEL DESKTOP BUNDLES PLUGINS UCODE ROOT_PART; do
    printf '%s=%q\n' "$v" "${!v}"
  done
  printf 'ARCHER_DL=%q\n' "$ARCHER_DL"
} > /mnt/etc/archer/install.conf

# ── Chroot: configure + fetch post-live-iso.sh + service ─────────────
step "Configuring system in chroot"
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/archer/install.conf

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE"   > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOST_NAME"     > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$HOST_NAME" > /etc/hosts

useradd -m -G wheel -s /bin/bash "$NEW_USER"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
passwd -l root >/dev/null

mkinitcpio -P

# systemd-boot
bootctl install
UUID=$(blkid -s UUID -o value "$ROOT_PART")
FLAGS="rw quiet"
[[ $FS == btrfs ]] && FLAGS="rootflags=subvol=@ $FLAGS"
printf 'default archer.conf\ntimeout 3\nconsole-mode max\neditor no\n' > /boot/loader/loader.conf
{
  echo "title   Archer"
  echo "linux   /vmlinuz-$KERNEL"
  [[ -n $UCODE ]] && echo "initrd  /$UCODE.img"
  echo "initrd  /initramfs-$KERNEL.img"
  echo "options root=UUID=$UUID $FLAGS"
} > /boot/loader/entries/archer.conf

systemctl enable NetworkManager NetworkManager-wait-online systemd-timesyncd fstrim.timer

# Download the post-install script and register the first-boot service
install -d /usr/local/share/archer
curl -fsSL "$ARCHER_DL/post-live-iso.sh" -o /usr/local/share/archer/post-live-iso.sh
chmod 755 /usr/local/share/archer/post-live-iso.sh

cat > /etc/systemd/system/archer-post-install.service <<'UNIT'
[Unit]
Description=Archer first-boot setup
After=network-online.target NetworkManager-wait-online.service
Wants=network-online.target
Before=getty@tty1.service display-manager.service
ConditionPathExists=/usr/local/share/archer/post-live-iso.sh

[Service]
Type=oneshot
ExecStart=/usr/local/share/archer/post-live-iso.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable archer-post-install.service
CHROOT

arch-chroot /mnt bash /root/chroot-setup.sh
echo "$NEW_USER:$PASSWORD" | arch-chroot /mnt chpasswd
rm -f /mnt/root/chroot-setup.sh

# ── Done ─────────────────────────────────────────────────────────────
cp "$LOG" /mnt/var/log/archer-install.log
sync; umount -R /mnt
clear; logo
gum style --foreground 2 "✓ Base install complete. Rebooting — remove the USB stick."
echo "  First boot will finish setup automatically (needs internet), then reboot once more."
sleep 6
reboot
