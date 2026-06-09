#!/usr/bin/env bash
set -euo pipefail

# ubuntu-bootstrap.sh
# Minimal workstation bootstrap:
# 1) preflight
# 2) core apt prerequisites
# 3) CLI baseline
# 4) Google Chrome + Obsidian
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

install_obsidian() {
  if snap_installed obsidian; then
    ok "Obsidian already installed"
    return 0
  fi

  if ! require_cmd snap; then
    info "Installing snapd"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
  fi

  info "Ensuring snap service is available"
  sudo systemctl enable --now snapd.socket >/dev/null 2>&1 || true

  info "Installing Obsidian via Snap"
  sudo snap install obsidian --classic
}

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

main() {
  info "Ubuntu bootstrap starting"

  if ! is_ubuntu; then
    echo "[ERROR] This script is intended for Ubuntu or an Ubuntu-based system." >&2
    exit 1
  fi

  ensure_sudo

  info "Installing base tooling"
  apt_update_once
  install_apt_packages \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    snapd

  info "Installing CLI baseline"
  install_apt_packages \
    git \
    tmux \
    fzf \
    btop \
    fastfetch

  info "Installing desktop apps"
  install_google_chrome
  install_obsidian

  verify_all

  info "Bootstrap completed successfully"
  ok "Log saved at: ${LOG_FILE}"
}

main "$@"
