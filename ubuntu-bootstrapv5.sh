#!/usr/bin/env bash
set -euo pipefail

# ubuntu-bootstrap.sh — v5
# Workstation bootstrap:
# 1) preflight
# 2) core apt prerequisites
# 3) CLI baseline
# 4) fonts
# 5) desktop apps
# 6) verification

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="${HOME}/.local/state/ubuntu-bootstrap"
LOG_FILE="${LOG_DIR}/$(date +%F_%H%M%S).log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "[ERROR] ${SCRIPT_NAME} failed on line ${LINENO}. Log: ${LOG_FILE}" >&2' ERR

info()  { printf '\n==> %s\n' "$*"; }
ok()    { printf '[OK] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_ubuntu() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* ]]
}

package_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

snap_installed() {
  require_cmd snap || return 1
  snap list "$1" >/dev/null 2>&1
}

ensure_sudo() {
  info "Refreshing sudo credentials"
  sudo -v
}

apt_update_once() {
  info "Updating apt package lists"
  sudo apt-get update
}

install_apt_packages() {
  local -a pkgs=("$@")
  local -a missing=()

  for pkg in "${pkgs[@]}"; do
    if package_installed "$pkg"; then
      ok "APT package already installed: $pkg"
    else
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} > 0)); then
    info "Installing APT packages: ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

ensure_snapd_ready() {
  if ! require_cmd snap; then
    info "Installing snapd"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
  fi

  info "Ensuring snap service is available"
  sudo systemctl enable --now snapd.socket >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

preflight() {
  info "Ubuntu bootstrap starting"

  if ! is_ubuntu; then
    echo "[ERROR] This script is intended for Ubuntu or an Ubuntu-based system." >&2
    exit 1
  fi

  ensure_sudo
}

# -----------------------------------------------------------------------------
# Core apt prerequisites
# -----------------------------------------------------------------------------

install_core_prereqs() {
  info "Installing base tooling"

  apt_update_once
  install_apt_packages \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    debsig-verify \
    xz-utils \
    snapd

  ensure_snapd_ready
}

# -----------------------------------------------------------------------------
# CLI baseline
# -----------------------------------------------------------------------------

install_cli_baseline() {
  info "Installing CLI baseline"

  install_apt_packages \
    git \
    tmux \
    fzf \
    btop \
    fastfetch
}

# -----------------------------------------------------------------------------
# Fonts
#
# Two layers:
#   1) apt fonts  — fonts-liberation (Windows-metric-compatible, needed for
#                   LibreOffice cross-platform doc fidelity)
#                   fonts-firacode   (monospace fallback)
#   2) JetBrains Mono Nerd Font v3.4.0 — pinned release, downloaded from the
#      official nerd-fonts repo, extracted to /usr/local/share/fonts/.
#      Idempotency: skip if the font directory already exists and fc-list
#      can find the family.
# -----------------------------------------------------------------------------

JETBRAINS_NERD_FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.tar.xz"
JETBRAINS_NERD_FONT_DIR="/usr/local/share/fonts/JetBrainsMonoNerdFont"

install_fonts() {
  info "Installing apt fonts"
  install_apt_packages \
    fonts-liberation \
    fonts-firacode

  if [[ -d "$JETBRAINS_NERD_FONT_DIR" ]] && fc-list | grep -qi "JetBrainsMono"; then
    ok "JetBrains Mono Nerd Font already installed"
    return 0
  fi

  info "Downloading JetBrains Mono Nerd Font v3.4.0"
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/jbmono-nerd-XXXXXX)"

  curl -fsSL "$JETBRAINS_NERD_FONT_URL" -o "${tmp_dir}/JetBrainsMono.tar.xz"

  info "Extracting fonts"
  tar -xJf "${tmp_dir}/JetBrainsMono.tar.xz" -C "$tmp_dir"

  sudo mkdir -p "$JETBRAINS_NERD_FONT_DIR"
  sudo find "$tmp_dir" -name "*.ttf" -exec cp {} "$JETBRAINS_NERD_FONT_DIR/" \;

  info "Refreshing font cache"
  sudo fc-cache -fv >/dev/null 2>&1

  rm -rf "$tmp_dir"
  ok "JetBrains Mono Nerd Font installed"
}

# -----------------------------------------------------------------------------
# Google Chrome
# -----------------------------------------------------------------------------

ensure_google_chrome_repo() {
  local keyring="/etc/apt/keyrings/google-chrome.gpg"
  local list_file="/etc/apt/sources.list.d/google-chrome.list"

  if [[ ! -f "$keyring" ]]; then
    info "Installing Google Chrome signing key"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o "$keyring"
  else
    ok "Google Chrome signing key already present"
  fi

  if [[ ! -f "$list_file" ]] || ! grep -q "dl.google.com/linux/chrome/deb" "$list_file"; then
    info "Adding Google Chrome APT repository"
    echo "deb [arch=amd64 signed-by=${keyring}] https://dl.google.com/linux/chrome/deb/ stable main" \
      | sudo tee "$list_file" >/dev/null
  else
    ok "Google Chrome APT repository already present"
  fi
}

install_google_chrome() {
  if require_cmd google-chrome-stable || require_cmd google-chrome; then
    ok "Google Chrome already installed"
    return 0
  fi

  info "Installing Google Chrome"
  ensure_google_chrome_repo
  apt_update_once
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
}

# -----------------------------------------------------------------------------
# Obsidian  (official .deb from GitHub releases)
# -----------------------------------------------------------------------------

install_obsidian() {
  if package_installed obsidian || require_cmd obsidian; then
    ok "Obsidian already installed"
    return 0
  fi

  info "Resolving latest Obsidian .deb URL from GitHub"
  local deb_url
  deb_url="$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | grep -oP '"browser_download_url":\s*"\K[^"]+amd64\.deb(?=")')"

  if [[ -z "$deb_url" ]]; then
    warn "Could not determine latest Obsidian .deb URL — skipping"
    return 1
  fi

  local tmp_deb
  tmp_deb="$(mktemp /tmp/obsidian-XXXXXX.deb)"

  info "Downloading Obsidian: ${deb_url}"
  curl -fsSL "$deb_url" -o "$tmp_deb"

  info "Installing Obsidian .deb"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp_deb"

  rm -f "$tmp_deb"
  ok "Obsidian installed"
}

# -----------------------------------------------------------------------------
# Additional GUI apps
# -----------------------------------------------------------------------------

ensure_vscode_repo() {
  local keyring="/usr/share/keyrings/microsoft.gpg"
  local list_file="/etc/apt/sources.list.d/vscode.sources"

  if [[ ! -f "$keyring" ]]; then
    info "Installing Microsoft signing key"
    sudo install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o "$keyring"
  else
    ok "Microsoft signing key already present"
  fi

  if [[ ! -f "$list_file" ]]; then
    info "Adding Microsoft VS Code repository"
    cat <<EOF | sudo tee "$list_file" >/dev/null
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
  else
    ok "Microsoft VS Code repository already present"
  fi
}

install_vscode() {
  if require_cmd code; then
    ok "VS Code already installed"
    return 0
  fi

  info "Installing VS Code"
  ensure_vscode_repo
  apt_update_once
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y code
}

install_snap_app() {
  local snap_name="$1"
  local label="$2"
  shift 2

  if snap_installed "$snap_name" || require_cmd "$snap_name"; then
    ok "$label already installed"
    return 0
  fi

  ensure_snapd_ready

  info "Installing $label via Snap"
  sudo snap install "$snap_name" "$@"
}

install_postman()  { install_snap_app postman          "Postman"; }
install_spotify()  { install_snap_app spotify          "Spotify"; }
install_telegram() { install_snap_app telegram-desktop "Telegram Desktop"; }
install_krita()    { install_snap_app krita            "Krita"; }
install_pinta()    { install_snap_app pinta            "Pinta"; }

install_libreoffice() {
  if package_installed libreoffice || require_cmd libreoffice || require_cmd soffice; then
    ok "LibreOffice already installed"
    return 0
  fi

  info "Installing LibreOffice"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libreoffice
}

install_document_viewer() {
  if package_installed evince || require_cmd evince; then
    ok "Document Viewer (Evince) already installed"
    return 0
  fi

  info "Installing Document Viewer (Evince)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y evince
}

install_tailscale() {
  if ! require_cmd tailscale; then
    info "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh

    if ! require_cmd tailscale; then
      warn "Tailscale install script finished but the command is still missing"
      return 1
    fi
    ok "Tailscale installed"
  else
    ok "Tailscale already installed"
  fi

  info "Ensuring tailscaled service is active"
  sudo systemctl enable --now tailscaled 2>/dev/null || true

  # $SUDO_USER is set by sudo to the original invoking user.
  # Falling back to $USER handles the rare case of running without sudo.
  local real_user="${SUDO_USER:-$USER}"
  info "Setting Tailscale operator permission for ${real_user}"
  if sudo tailscale set --operator="$real_user"; then
    ok "Tailscale operator set for ${real_user}"
  else
    warn "Could not set Tailscale operator — run manually: sudo tailscale set --operator=${real_user}"
  fi
}

install_gui_apps() {
  info "Installing GUI apps"

  install_vscode
  install_postman
  install_spotify
  install_telegram
  install_krita
  install_pinta
  install_libreoffice
  install_document_viewer
  install_tailscale
}

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

verify_all() {
  info "Running verification"

  local pass=0
  local fail=0

  _check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      ok "$label"
      ((pass++)) || true
    else
      warn "NOT FOUND: $label"
      ((fail++)) || true
    fi
  }

  # Fonts
  _check "fonts-liberation (apt)"       bash -c 'dpkg -s fonts-liberation'
  _check "fonts-firacode (apt)"         bash -c 'dpkg -s fonts-firacode'
  _check "JetBrains Mono Nerd Font"     bash -c 'fc-list | grep -qi JetBrainsMono'

  # GUI apps
  _check "Google Chrome"                bash -c 'command -v google-chrome-stable || command -v google-chrome'
  _check "Obsidian"                     bash -c 'dpkg -s obsidian || command -v obsidian'
  _check "VS Code"                      command -v code
  _check "Postman"                      bash -c 'snap list postman || command -v postman'
  _check "Spotify"                      bash -c 'snap list spotify || command -v spotify'
  _check "Telegram Desktop"             bash -c 'snap list telegram-desktop || command -v telegram-desktop'
  _check "Krita"                        bash -c 'snap list krita || command -v krita'
  _check "Pinta"                        bash -c 'snap list pinta || command -v pinta'
  _check "LibreOffice"                  bash -c 'dpkg -s libreoffice || command -v soffice'
  _check "Document Viewer (Evince)"     bash -c 'dpkg -s evince || command -v evince'
  _check "Tailscale"                    command -v tailscale

  # CLI baseline
  _check "git"                          command -v git
  _check "tmux"                         command -v tmux
  _check "fzf"                          command -v fzf
  _check "btop"                         command -v btop
  _check "fastfetch"                    command -v fastfetch

  printf '\nVerification: %d OK, %d missing\n' "$pass" "$fail"

  if ((fail > 0)); then
    warn "Some items were not detected — review the log: ${LOG_FILE}"
  else
    ok "All checks passed"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  preflight
  install_core_prereqs
  install_cli_baseline

  info "Installing fonts"
  install_fonts

  info "Installing desktop apps"
  install_google_chrome
  install_obsidian
  install_gui_apps

  verify_all

  info "Bootstrap completed successfully"
  ok "Log saved at: ${LOG_FILE}"
}

main "$@"
