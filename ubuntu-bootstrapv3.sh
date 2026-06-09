#!/usr/bin/env bash
set -euo pipefail

# ubuntu-bootstrap.sh
# Minimal workstation bootstrap:
# 1) preflight
# 2) core apt prerequisites
# 3) CLI baseline
# 4) desktop apps
# 5) verification

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="${HOME}/.local/state/ubuntu-bootstrap"
LOG_FILE="${LOG_DIR}/$(date +%F_%H%M%S).log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "[ERROR] ${SCRIPT_NAME} failed on line ${LINENO}. Log: ${LOG_FILE}" >&2' ERR

info() { printf '\n==> %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }

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
    echo "deb [arch=amd64 signed-by=${keyring}] https://dl.google.com/linux/chrome/deb/ stable main" | sudo tee "$list_file" >/dev/null
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
# Obsidian
# -----------------------------------------------------------------------------

install_obsidian() {
  if snap_installed obsidian; then
    ok "Obsidian already installed"
    return 0
  fi

  ensure_snapd_ready

  info "Installing Obsidian via Snap"
  sudo snap install obsidian --classic
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

ensure_1password_repo() {
  local keyring="/usr/share/keyrings/1password-archive-keyring.gpg"
  local list_file="/etc/apt/sources.list.d/1password.list"
  local policy_dir="/etc/debsig/policies/AC2D62742012EA22"
  local keyring_dir="/usr/share/debsig/keyrings/AC2D62742012EA22"

  if [[ ! -f "$keyring" ]]; then
    info "Installing 1Password signing key"
    sudo install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output "$keyring"
  else
    ok "1Password signing key already present"
  fi

  if [[ ! -f "$list_file" ]]; then
    info "Adding 1Password APT repository"
    echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' | sudo tee "$list_file" >/dev/null
  else
    ok "1Password APT repository already present"
  fi

  if [[ ! -f "$policy_dir/1password.pol" ]]; then
    info "Installing 1Password debsig policy"
    sudo mkdir -p "$policy_dir"
    curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | sudo tee "$policy_dir/1password.pol" >/dev/null
  else
    ok "1Password debsig policy already present"
  fi

  if [[ ! -f "$keyring_dir/debsig.gpg" ]]; then
    info "Installing 1Password debsig keyring"
    sudo mkdir -p "$keyring_dir"
    curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --output "$keyring_dir/debsig.gpg"
  else
    ok "1Password debsig keyring already present"
  fi
}

install_1password() {
  if package_installed 1password || require_cmd 1password; then
    ok "1Password already installed"
    return 0
  fi

  info "Installing 1Password"
  ensure_1password_repo
  apt_update_once
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y 1password
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

install_postman() { install_snap_app postman "Postman"; }
install_spotify() { install_snap_app spotify "Spotify"; }
install_telegram() { install_snap_app telegram-desktop "Telegram Desktop"; }
install_krita() { install_snap_app krita "Krita"; }

install_pinta() {
  if snap_installed pinta || require_cmd pinta; then
    ok "Pinta already installed"
    return 0
  fi

  ensure_snapd_ready

  info "Installing Pinta via Snap"
  sudo snap install pinta
}

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
  if require_cmd tailscale; then
    ok "Tailscale already installed"
    return 0
  fi

  info "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh

  if require_cmd tailscale; then
    ok "Tailscale installed"
  else
    warn "Tailscale install script finished, but the command is still missing"
  fi
}

install_gui_apps() {
  info "Installing remaining GUI apps"

  install_vscode
  install_1password
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

  if require_cmd google-chrome-stable || require_cmd google-chrome; then
    ok "Google Chrome command detected"
  else
    warn "Google Chrome command not found"
  fi

  if snap_installed obsidian || require_cmd obsidian; then
    ok "Obsidian detected"
  else
    warn "Obsidian not detected"
  fi

  if require_cmd google-chrome-stable; then
    google-chrome-stable --version || true
  elif require_cmd google-chrome; then
    google-chrome --version || true
  fi

  if require_cmd obsidian; then
    obsidian --version || true
  elif snap_installed obsidian; then
    snap list obsidian || true
  fi

  ok "Verification finished"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  preflight
  install_core_prereqs
  install_cli_baseline

  info "Installing desktop apps"
  install_google_chrome
  install_obsidian
  install_gui_apps

  verify_all

  info "Bootstrap completed successfully"
  ok "Log saved at: ${LOG_FILE}"
}

main "$@"
