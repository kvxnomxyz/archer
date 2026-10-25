#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  Archer post-install — runs ONCE on first boot via archer-post-install.service
#  On success it removes itself + the service, then reboots.
#  On failure it stays in place: fix the issue, then
#    systemctl start archer-post-install
# ─────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF="$(readlink -f "$0")"
source /etc/archer/install.conf
LOG=/var/log/archer-post-install.log
exec > >(tee -a "$LOG") 2>&1

CYAN=$'\e[36m'; OFF=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$CYAN" "$OFF" "$*"; }
trap 'rm -f /etc/sudoers.d/99-archer-tmp' EXIT
trap 'echo "✗ Archer setup failed at line $LINENO. Log: $LOG. Retry: systemctl start archer-post-install"' ERR

# Install a group; if it fails, fall back to one-by-one and skip bad packages
pac() {
  pacman -S --needed --noconfirm "$@" || {
    for p in "$@"; do pacman -S --needed --noconfirm "$p" || echo "WARN: skipped $p"; done
  }
}
as_user() { sudo -u "$NEW_USER" -H "$@"; }
has() { [[ " $BUNDLES " == *" $1 "* ]]; }

step "Waiting for network"
for _ in {1..60}; do ping -c1 -W2 archlinux.org &>/dev/null && break; sleep 5; done
ping -c1 -W2 archlinux.org &>/dev/null

# ── Branding ─────────────────────────────────────────────────────────
step "Branding"
install -d /etc/archer
cat > /etc/archer/logo.txt <<'LOGO'
    _             _
   / \   _ __ ___| |__   ___ _ __
  / _ \ | '__/ __| '_ \ / _ \ '__|
 / ___ \| | | (__| | | |  __/ |
/_/   \_\_|  \___|_| |_|\___|_|
LOGO
# Arch + bow logo for neofetch (backslashes are doubled on purpose; neofetch un-escapes them)
cat > /etc/archer/neofetch-logo.ascii <<'NFLOGO'
                           ${c1}/\\
                          ${c1}//\\\\
         ${c2}-|              ${c1}//  \\\\
       ${c2}(  |             ${c1}//    \\\\
      ${c2}(   |            ${c1}//      \\\\
    ${c2}(     |           ${c1}//        \\\\
   ${c2}(      |          ${c1}//          \\\\
   ${c2}(      |         ${c1}//            \\\\
  ${c2}(       |        ${c1}//              \\\\
  ${c2}(       +-==----------------------------->>
  ${c2}(       |      ${c1}//                  \\\\
   ${c2}(      |     ${c1}//                    \\\\
   ${c2}(      |    ${c1}//                      \\\\
    ${c2}(     |   ${c1}//                        \\\\
      ${c2}(   |  ${c1}//                          \\\\
       ${c2}(  | ${c1}//                            \\\\
         ${c2}-|${c1}//                              \\\\
NFLOGO
rm -f /etc/os-release
cat > /etc/os-release <<'OSR'
NAME="Archer"
PRETTY_NAME="Archer"
ID=archer
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://github.com/kvxnomxyz/archer"
LOGO=archlinux-logo
OSR
{ cat /etc/archer/logo.txt; printf '\n  \\n (\\l)\n\n'; } > /etc/issue

# ── Repos / base tooling ─────────────────────────────────────────────
step "Preparing package manager"
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/; s/^#Color/Color/; s/^#NoUpgrade.*/NoUpgrade = etc\/os-release/' /etc/pacman.conf
if has gaming; then
  sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
fi
pacman -Syu --noconfirm

pac pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber bluez bluez-utils gum fastfetch btop \
    firefox bash-completion zram-generator noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd \
    xdg-user-dirs xdg-utils unzip zip wget openssh

step "neofetch"
pacman -S --needed --noconfirm neofetch || {
  echo "neofetch is not in the repos; using the pinned upstream script"
  curl -fsSL https://raw.githubusercontent.com/dylanaraps/neofetch/7.1.0/neofetch -o /usr/local/bin/neofetch
  chmod 755 /usr/local/bin/neofetch
}

# ── GPU ──────────────────────────────────────────────────────────────
step "GPU drivers"
GPU="$(lspci | grep -Ei 'vga|3d|display' || true)"
[[ $GPU == *NVIDIA* ]] && { [[ $KERNEL == linux ]] && pac nvidia-open nvidia-utils || pac nvidia-open-dkms nvidia-utils; }
[[ $GPU == *AMD* || $GPU == *ATI* ]] && pac mesa vulkan-radeon
[[ $GPU == *Intel* ]] && pac mesa vulkan-intel intel-media-driver
if has gaming; then   # Steam needs matching 32-bit drivers; pick them explicitly
  [[ $GPU == *NVIDIA* ]] && pac lib32-nvidia-utils
  [[ $GPU == *AMD* || $GPU == *ATI* ]] && pac lib32-mesa lib32-vulkan-radeon
  [[ $GPU == *Intel* ]] && pac lib32-mesa lib32-vulkan-intel
fi
true

# ── Desktop ──────────────────────────────────────────────────────────
step "Desktop: $DESKTOP"
DM=""
case "$DESKTOP" in
  hyprland)
    pac hyprland hyprpaper hyprlock hyprpolkitagent xdg-desktop-portal-hyprland waybar fuzzel mako \
        kitty nautilus grim slurp wl-clipboard brightnessctl playerctl pavucontrol \
        network-manager-applet qt5-wayland qt6-wayland sddm
    DM=sddm ;;
  sway)
    pac sway swaybg swayidle swaylock foot wmenu waybar mako grim slurp wl-clipboard \
        xdg-desktop-portal-wlr nautilus pavucontrol network-manager-applet sddm
    DM=sddm ;;
  kde)    pac plasma-meta konsole dolphin kate sddm; DM=sddm ;;
  gnome)  pac gnome gnome-tweaks; DM=gdm ;;
  none)   ;;
esac

# ── Bundles ──────────────────────────────────────────────────────────
step "Bundles: ${BUNDLES:-none}"
has dev     && { pac github-cli git-lfs docker docker-compose neovim code go rust nodejs npm python python-pip jq ripgrep fd
                 systemctl enable docker; usermod -aG docker "$NEW_USER"; }
has gaming  && pac steam lutris gamemode mangohud
has creator && pac obs-studio kdenlive gimp inkscape audacity krita
has office  && pac libreoffice-fresh thunderbird okular
has media   && pac vlc mpv yt-dlp ffmpeg
true

# ── AUR helper (yay) ─────────────────────────────────────────────────
step "Installing yay"
echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-archer-tmp
chmod 440 /etc/sudoers.d/99-archer-tmp
if ! command -v yay &>/dev/null; then
  as_user bash -c 'cd /tmp && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git \
    && cd yay-bin && makepkg -si --noconfirm'
fi

# ── Archer CLI (plugins, themes, updates) ────────────────────────────
step "Installing archer CLI"
cat > /usr/local/bin/archer <<'ARCHER_CLI'
#!/usr/bin/env bash
# archer — control CLI for Archer OS
#
# Plugin layout (a git repo):
#   plugin.conf     NAME= DESCRIPTION= VERSION=      (shell vars)
#   packages.txt    pacman packages, one per line
#   aur.txt         AUR packages, one per line
#   install.sh      optional hook, runs after packages
#   remove.sh       optional hook, runs on removal
#   themes/<name>/  optional themes, auto-registered
#   hooks/<event>   optional executables (events: theme-set, post-update)
set -Eeuo pipefail

ARCHER_HOME="${ARCHER_HOME:-$HOME/.local/share/archer}"
ARCHER_CFG="${ARCHER_CFG:-$HOME/.config/archer}"
PLUGINS="$ARCHER_HOME/plugins"
PLUGIN_BASE="${ARCHER_PLUGIN_BASE:-https://github.com/kvxnomxyz/archer-plugin-}"
mkdir -p "$PLUGINS" "$ARCHER_CFG/themes" "$ARCHER_CFG/hooks"

die() { echo "archer: $*" >&2; exit 1; }
pkglist() { grep -hv '^\s*\(#\|$\)' "$1" 2>/dev/null || true; }

logo() {
  printf '\033[36m'; cat /etc/archer/logo.txt 2>/dev/null; printf '\033[0m\n'
  echo "  $(grep -m1 ^PRETTY_NAME /etc/os-release | cut -d'"' -f2) · $(uname -r)"
}

hook() { # run every plugin's + the user's hook for event $1
  local ev="$1"; shift
  local h
  for h in "$ARCHER_CFG/hooks/$ev" "$PLUGINS"/*/hooks/"$ev"; do
    [[ -x $h ]] && "$h" "$@" || true
  done
}

# ── Plugins ──────────────────────────────────────────────────────────
plugin_apply() {
  local d="$PLUGINS/$1" pk t
  pk="$(pkglist "$d/packages.txt")"
  [[ -n $pk ]] && sudo pacman -S --needed --noconfirm $pk
  pk="$(pkglist "$d/aur.txt")"
  [[ -n $pk ]] && yay -S --needed --noconfirm $pk
  for t in "$d"/themes/*/; do
    [[ -d $t ]] && ln -sfn "${t%/}" "$ARCHER_CFG/themes/$(basename "$t")"
  done
  [[ -x $d/install.sh ]] && (cd "$d" && ./install.sh)
  return 0
}

plugin_add() {
  local yes=0; [[ ${1:-} == --yes ]] && { yes=1; shift; }
  local src="${1:?usage: archer plugin add [--yes] <name|git-url>}" url name dir a
  if [[ $src == *://* || $src == git@* ]]; then url="$src"; else url="${PLUGIN_BASE}${src}"; fi
  name="$(basename "${url%.git}")"; name="${name#archer-plugin-}"
  dir="$PLUGINS/$name"
  [[ -d $dir ]] && die "$name already installed (try: archer plugin update)"
  git clone --depth 1 "$url" "$dir" || die "could not clone $url"
  if (( ! yes )); then
    echo "Plugins can run arbitrary code (and install packages). Review: $dir"
    read -rp "Install '$name'? [y/N] " a
    [[ $a == [yY]* ]] || { rm -rf "$dir"; die "aborted"; }
  fi
  plugin_apply "$name"
  echo "✓ plugin '$name' installed"
}

plugin_remove() {
  local purge=0; [[ ${1:-} == --purge ]] && { purge=1; shift; }
  local name="${1:?usage: archer plugin remove [--purge] <name>}" d pk l
  d="$PLUGINS/$name"; [[ -d $d ]] || die "not installed: $name"
  [[ -x $d/remove.sh ]] && (cd "$d" && ./remove.sh) || true
  if (( purge )); then
    pk="$(pkglist "$d/packages.txt")"; [[ -n $pk ]] && sudo pacman -Rns --noconfirm $pk || true
    pk="$(pkglist "$d/aur.txt")";      [[ -n $pk ]] && yay -Rns --noconfirm $pk || true
  fi
  for l in "$ARCHER_CFG"/themes/*; do
    [[ -L $l && $(readlink "$l") == "$d"/* ]] && rm -f "$l"
  done
  rm -rf "$d"
  echo "✓ plugin '$name' removed"
}

plugin_list() {
  local d
  for d in "$PLUGINS"/*/; do
    [[ -d $d ]] || continue
    ( DESCRIPTION=""; VERSION=""
      [[ -f $d/plugin.conf ]] && source "$d/plugin.conf"
      printf '%-20s %-8s %s\n' "$(basename "$d")" "$VERSION" "$DESCRIPTION" )
  done
}

plugin_update() {
  local d
  for d in "$PLUGINS"/*/; do
    [[ -d $d/.git ]] || continue
    git -C "$d" pull --ff-only -q && plugin_apply "$(basename "$d")"
  done
}

plugin() {
  local cmd="${1:-list}"; shift || true
  case "$cmd" in
    add|install) plugin_add "$@" ;;
    remove|rm)   plugin_remove "$@" ;;
    list|ls)     plugin_list ;;
    update)      plugin_update ;;
    *) die "usage: archer plugin <add|remove|list|update>" ;;
  esac
}

# ── Themes ───────────────────────────────────────────────────────────
theme_list() { ls -1 "$ARCHER_CFG/themes"; }
theme_set() {
  local t="${1:?usage: archer theme set <name>}"
  [[ -d $ARCHER_CFG/themes/$t ]] || die "no such theme: $t"
  ln -sfn "$(readlink -f "$ARCHER_CFG/themes/$t")" "$ARCHER_CFG/current-theme"
  hook theme-set "$t"
  echo "✓ theme: $t"
}
theme() {
  local cmd="${1:-list}"; shift || true
  case "$cmd" in
    list|ls) theme_list ;;
    set)     theme_set "$@" ;;
    *) die "usage: archer theme <list|set>" ;;
  esac
}

update() {
  sudo pacman -Syu
  command -v yay &>/dev/null && yay -Sua --noconfirm
  plugin_update
  hook post-update
}

menu() {
  command -v gum >/dev/null || die "gum not installed"
  clear; logo; echo
  case "$(gum choose Theme Plugins Update Quit)" in
    Theme)   theme_set "$(theme_list | gum choose)" ;;
    Plugins) plugin_list; read -rsp $'\n(enter to close)' ;;
    Update)  update; read -rsp $'\n(enter to close)' ;;
  esac
}

case "${1:-menu}" in
  plugin|plugins) shift; plugin "$@" ;;
  theme|themes)   shift; theme "$@" ;;
  update)         update ;;
  menu)           menu ;;
  logo)           logo ;;
  version|-v)     echo "archer 0.1.0" ;;
  *) cat <<HELP
archer — Archer OS control
  archer                       interactive menu
  archer theme list|set <n>    switch theme
  archer plugin add <n|url>    install plugin (names resolve to \$ARCHER_PLUGIN_BASE)
  archer plugin remove [--purge] <n> | list | update
  archer update                system + AUR + plugins
  archer logo | version
HELP
  ;;
esac
ARCHER_CLI
chmod 755 /usr/local/bin/archer

# ── User config (theme system + sane defaults) ──────────────────────
step "Writing user config"
H="/home/$NEW_USER"
T="$H/.config/archer/themes/archer-dark"
install -d "$T" "$H/.config/archer/hooks" "$H/.config/hypr" "$H/.config/kitty" \
           "$H/.config/waybar" "$H/.config/fastfetch" "$H/.config/neofetch" "$H/.local/share/archer/plugins"

cat > "$T/colors.sh" <<'EOF'
BG="#1a1b26"; FG="#c0caf5"; ACCENT="#7aa2f7"; MUTED="#3b4261"
EOF
cat > "$T/kitty.conf" <<'EOF'
foreground #c0caf5
background #1a1b26
cursor #7aa2f7
selection_background #33467c
EOF
cat > "$T/hyprland.conf" <<'EOF'
general {
    col.active_border = rgb(7aa2f7)
    col.inactive_border = rgb(3b4261)
}
EOF
cat > "$T/waybar.css" <<'EOF'
* { color: #c0caf5; }
window#waybar { background: rgba(26, 27, 38, 0.9); }
EOF
ln -sfn "$T" "$H/.config/archer/current-theme"

cat > "$H/.config/archer/hooks/theme-set" <<'EOF'
#!/usr/bin/env bash
command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
pkill -USR2 waybar 2>/dev/null || true
pkill -USR1 kitty 2>/dev/null || true
EOF
chmod +x "$H/.config/archer/hooks/theme-set"

printf 'include ~/.config/archer/current-theme/kitty.conf\nfont_family JetBrainsMono Nerd Font\nfont_size 11\n' > "$H/.config/kitty/kitty.conf"
cat > "$H/.config/waybar/style.css" <<WBCSS
@import url("$H/.config/archer/current-theme/waybar.css");
* { font-family: "JetBrainsMono Nerd Font"; font-size: 13px; }
#clock, #pulseaudio, #network, #battery, #tray { padding: 0 8px; }
WBCSS
WB_WS="sway/workspaces"; [[ $DESKTOP == hyprland ]] && WB_WS="hyprland/workspaces"
cat > "$H/.config/waybar/config.jsonc" <<WBCFG
{
  "layer": "top", "position": "top", "height": 30,
  "modules-left": ["$WB_WS"],
  "modules-center": ["clock"],
  "modules-right": ["tray", "pulseaudio", "network", "battery"]
}
WBCFG
printf '{ "logo": { "type": "file", "source": "/etc/archer/logo.txt", "color": { "1": "cyan" } } }\n' > "$H/.config/fastfetch/config.jsonc"
cat > "$H/.config/neofetch/config.conf" <<'NFCONF'
# Archer neofetch layout
# Edit freely: ~/.config/neofetch/config.conf

print_info() {
    local theme="none" plugins=0 ver
    [[ -L $HOME/.config/archer/current-theme ]] &&
        theme="$(basename "$(readlink -f "$HOME/.config/archer/current-theme")")"
    [[ -d $HOME/.local/share/archer/plugins ]] &&
        plugins="$(find "$HOME/.local/share/archer/plugins" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    ver="$(archer version 2>/dev/null)"; ver="${ver#archer }"

    info title
    info underline

    info "OS" distro
    info "Host" model
    info "Kernel" kernel
    info "Uptime" uptime
    info "Packages" packages
    info "Shell" shell
    info "WM" wm
    info "Terminal" term

    prin " "
    info "CPU" cpu
    info "GPU" gpu
    info "Memory" memory
    info "Disk" disk

    prin " "
    prin "Archer" "${ver:-dev}"
    prin "Theme" "$theme"
    prin "Plugins" "$plugins"

    prin " "
    info cols
}

# Logo
image_backend="ascii"
image_source="/etc/archer/neofetch-logo.ascii"
ascii_colors=(6 7)          # c1 = cyan (the A), c2 = white (bow + arrow)
ascii_bold="on"
gap=3

# Text
colors=(6 7 6 6 7 7)        # title, @, underline, subtitle, colon, info
bold="on"
separator=" ->"
underline_enabled="on"
underline_char="-"
title_fqdn="off"

# Values
os_arch="on"
kernel_shorthand="on"
uptime_shorthand="on"
memory_percent="on"
memory_unit="gib"
shell_version="off"
cpu_speed="off"
cpu_cores="off"
cpu_temp="off"
gpu_type="all"
refresh_rate="off"
package_managers="on"
disk_show=('/')

# Color blocks
color_blocks="on"
block_range=(0 15)
block_width=3
block_height=1
NFCONF

if [[ $DESKTOP == hyprland ]]; then
  XKB="${KEYMAP%%-*}"; [[ $XKB == uk ]] && XKB=gb
  {
    cat <<EOF
monitor = , preferred, auto, 1
\$mod = SUPER
source = ~/.config/archer/current-theme/hyprland.conf

exec-once = waybar
exec-once = mako
exec-once = systemctl --user start hyprpolkitagent
exec-once = nm-applet --indicator

input {
    kb_layout = $XKB
    follow_mouse = 1
}
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
}
decoration {
    rounding = 8
}

bind = \$mod, Return, exec, kitty
bind = \$mod, Space, exec, fuzzel
bind = \$mod ALT, Space, exec, kitty -e archer menu
bind = \$mod, E, exec, nautilus
bind = \$mod, B, exec, firefox
bind = \$mod, Q, killactive
bind = \$mod, F, fullscreen
bind = \$mod, V, togglefloating
bind = \$mod, L, exec, hyprlock
bind = \$mod SHIFT, M, exit
bind = , Print, exec, grim -g "\$(slurp)" - | wl-copy
bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
bindm = \$mod, mouse:272, movewindow
bindm = \$mod, mouse:273, resizewindow
EOF
    for i in {1..9}; do
      echo "bind = \$mod, $i, workspace, $i"
      echo "bind = \$mod SHIFT, $i, movetoworkspace, $i"
    done
  } > "$H/.config/hypr/hyprland.conf"
fi
chown -R "$NEW_USER:$NEW_USER" "$H"
as_user xdg-user-dirs-update || true

# ── Plugins chosen at install time ───────────────────────────────────
if [[ -n ${PLUGINS// /} ]]; then
  step "Plugins: $PLUGINS"
  for p in $PLUGINS; do as_user archer plugin add --yes "$p" || echo "WARN: plugin $p failed"; done
fi

# ── Services ─────────────────────────────────────────────────────────
step "Enabling services"
systemctl enable bluetooth
[[ -n $DM ]] && systemctl enable "$DM"
if [[ $DESKTOP != none ]]; then systemctl set-default graphical.target; fi
printf '[zram0]\nzram-size = min(ram / 2, 8192)\n' > /etc/systemd/zram-generator.conf

# ── Self-destruct + reboot ───────────────────────────────────────────
step "Finishing up — cleaning installer, rebooting"
systemctl disable archer-post-install.service || true
rm -f /etc/systemd/system/archer-post-install.service
systemctl daemon-reload
rm -f /etc/sudoers.d/99-archer-tmp
[[ $SELF == /usr/local/share/archer/* ]] && rm -f -- "$SELF"
rmdir /usr/local/share/archer 2>/dev/null || true
systemd-run --on-active=5s --unit=archer-reboot systemctl reboot
exit 0
