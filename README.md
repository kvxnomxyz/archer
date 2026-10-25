<pre>
    _             _
   / \   _ __ ___| |__   ___ _ __
  / _ \ | '__/ __| '_ \ / _ \ '__|
 / ___ \| | | (__| | | |  __/ |
/_/   \_\_|  \___|_| |_|\___|_|
</pre>

**Arch, aimed at you.** Arch-based OS with a guided installer, plugins and themes, installed with one command.

## Install

Boot the [Arch Linux live ISO](https://archlinux.org/download/), get online, then run:

```bash
curl -fsSL https://kvxnomxyz.github.io/archer/install.sh | bash
```
```bash
wget -qO- https://kvxnomxyz.github.io/archer/install.sh | bash
```

> **Warning:** the installer erases the disk you select. Test in a VM first.

Pin a version:

```bash
ARCHER_VERSION=v0.1.0 bash <(curl -fsSL https://kvxnomxyz.github.io/archer/install.sh)
```

Requirements: UEFI boot and an internet connection (ethernet recommended; Wi-Fi set up in the live ISO does not carry over to first boot).

## How it works

1. **`install.sh`** (live ISO): TUI for disk, user, locale, filesystem (btrfs/ext4), kernel (linux/zen/lts), desktop and software bundles. Partitions, runs `pacstrap`, sets up systemd-boot, then chroots, downloads `post-live-iso.sh` and registers a first-boot service.
2. **`post-live-iso.sh`** (first boot): installs GPU drivers, desktop, bundles, `yay` and the `archer` CLI, applies branding and your plugins, then **deletes itself and the service** and reboots. If it fails, it stays in place so you can retry:
   ```bash
   sudo systemctl start archer-post-install
   ```

## Options

| Choice | Options |
|---|---|
| Desktop | Hyprland, Sway, KDE, GNOME, none |
| Filesystem | btrfs (subvolumes), ext4 |
| Kernel | `linux`, `linux-zen`, `linux-lts` |
| Bundles | dev, gaming, creator, office, media |

## The `archer` CLI

```bash
archer                         # interactive menu
archer theme list              # list themes
archer theme set <name>        # switch theme (terminal, bar, compositor)
archer plugin add <name|url>   # install a plugin
archer plugin remove [--purge] <name>
archer plugin list
archer plugin update
archer update                  # system + AUR + plugins
```

Hyprland keybinds: `Super+Return` terminal, `Super+Space` launcher, `Super+Alt+Space` archer menu.

## Plugins

A plugin is a git repo. Short names resolve to `github.com/kvxnomxyz/archer-plugin-<name>` (override with `ARCHER_PLUGIN_BASE`).

```
my-plugin/
├─ plugin.conf     # NAME= DESCRIPTION= VERSION=
├─ packages.txt    # pacman packages, one per line
├─ aur.txt         # AUR packages, one per line
├─ install.sh      # optional, runs after packages
├─ remove.sh       # optional, runs on removal
├─ themes/<name>/  # optional, auto-registered
└─ hooks/<event>   # optional executables (theme-set, post-update)
```

Plugins run arbitrary code. Read them before installing.

## Themes

A theme is a folder in `~/.config/archer/themes/` with `colors.sh`, `kitty.conf`, `hyprland.conf` and `waybar.css`. `archer theme set` relinks the active theme and runs the `theme-set` hooks, which reload your apps.

## Releases

Pushing a tag like `v0.1.0` triggers the workflow in `.github/workflows/release.yml`, which attaches `install.sh` and `post-live-iso.sh` to a GitHub release. The site in `docs/` serves launcher scripts that always fetch the newest release.

## Repo layout

```
install.sh            installer (release asset)
post-live-iso.sh      first-boot setup (release asset)
docs/                 GitHub Pages site + launcher scripts
.github/workflows/    release automation
```

## License

[MIT](LICENSE)
