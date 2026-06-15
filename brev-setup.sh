#!/usr/bin/env bash
# =============================================================================
# Brev One-Click Setup Script (Idempotent)
# Installs: Selkies WebRTC Desktop + Isaac Sim 6.0 + Oh-My-Zsh + Claude Code
#
# Usage (Brev Launchable setup script):
#   curl -fsSL https://raw.githubusercontent.com/<you>/repo/main/brev-setup.sh | sudo -E bash
#
# Re-run safe: each step checks if already done and skips if so.
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date -u '+%H:%M:%S')] ✓ $*${NC}"; }
info() { echo -e "${CYAN}[$(date -u '+%H:%M:%S')]   $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date -u '+%H:%M:%S')] ⚠ $*${NC}"; }
die()  { echo -e "${RED}[$(date -u '+%H:%M:%S')] ✗ ERROR: $*${NC}"; exit 1; }
step() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; \
         echo -e "${CYAN}  $*${NC}"; \
         echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
UBUNTU_USER="ubuntu"
UBUNTU_HOME="/home/${UBUNTU_USER}"
ISAAC_VERSION="${ISAAC_VERSION:-6.0.0}"
VENV_DIR="${UBUNTU_HOME}/isaac-venv"
SELKIES_CONTAINER="brev-selkies-desktop"

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$(id -u)" == "0" ]] || die "Run as root: curl ... | sudo -E bash"

# =============================================================================
# STEP 0: Detect public IP (used by Selkies TURN)
# Uses AWS metadata service (link-local, never blocked by Brev network policy).
# Falls back to public IP services if not on AWS.
# =============================================================================
step "STEP 0: Detecting public IP"

detect_public_ip() {
  # AWS metadata service - most reliable on Brev (EC2-backed)
  local ip
  ip=$(curl -fsSL --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi

  # Fallback to public services
  for url in https://icanhazip.com https://api.ipify.org https://ifconfig.me/ip; do
    ip=$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

PUBLIC_IP=$(detect_public_ip || true)
if [[ -n "$PUBLIC_IP" ]]; then
  log "Public IP: $PUBLIC_IP"
  export SELKIES_TURN_HOST="$PUBLIC_IP"
  export TURN_EXTERNAL_IP="$PUBLIC_IP"
  export SELKIES_AUTO_TURN_HOST=0
else
  warn "Could not detect public IP — TURN may advertise wrong address"
fi

# =============================================================================
# STEP 1: Selkies WebRTC Desktop (idempotent)
# - If container is already running with correct IP → skip
# - If container is running with wrong IP → update TURN only (no restart)
# - If container is not running → full install
# =============================================================================
step "STEP 1: Selkies WebRTC Desktop"

CONTAINER_RUNNING=false
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SELKIES_CONTAINER}$"; then
  CONTAINER_RUNNING=true
fi

if $CONTAINER_RUNNING; then
  # Check if TURN IP matches current public IP
  CURRENT_TURN_IP=$(docker exec "$SELKIES_CONTAINER" \
    bash -c "ps aux | grep turnserver | grep -o 'external-ip=[^ ]*' | head -1 | cut -d= -f2" 2>/dev/null || true)

  if [[ "$CURRENT_TURN_IP" == "$PUBLIC_IP" ]]; then
    log "Selkies already running with correct TURN IP ($PUBLIC_IP) — skipping"
  else
    warn "Selkies running but TURN IP is wrong ($CURRENT_TURN_IP → $PUBLIC_IP)"
    info "Restarting turnserver inside container with correct IP..."

    docker exec "$SELKIES_CONTAINER" bash -c "
      pkill turnserver 2>/dev/null || true
      sleep 1
      turnserver --verbose \
        --listening-ip=0.0.0.0 --listening-ip=:: \
        --listening-port=47998 \
        --realm=example.com \
        --external-ip=${PUBLIC_IP} \
        --min-port=47999 --max-port=48015 \
        --channel-lifetime=-1 \
        --lt-cred-mech \
        --user=selkies:\$(cat /tmp/runtime-ubuntu/turnserver-turndb 2>/dev/null | head -1 | cut -d: -f2 || echo 'selkies') \
        --no-cli \
        --allow-loopback-peers \
        --log-file=stdout \
        --pidfile=/tmp/runtime-ubuntu/turnserver.pid &
    " 2>/dev/null || warn "Could not restart turnserver (non-fatal)"
    log "TURN IP updated to $PUBLIC_IP"
  fi
else
  info "Starting Selkies desktop (fresh install)..."
  export SELKIES_ACCELERATION=auto
  export SELKIES_MODE=webrtc

  curl -fsSL \
    "https://raw.githubusercontent.com/Shiftius/brev-selkies-desktop/main/assets/brev-selkies-desktop.sh" \
    | bash
  log "Selkies desktop started"
fi

# =============================================================================
# STEP 2: System dependencies (idempotent via apt)
# =============================================================================
step "STEP 2: System dependencies"

PKGS_NEEDED=()
for pkg in zsh git curl wget build-essential python3-pip python3-venv software-properties-common; do
  dpkg -s "$pkg" &>/dev/null || PKGS_NEEDED+=("$pkg")
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
  info "Installing: ${PKGS_NEEDED[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${PKGS_NEEDED[@]}" > /dev/null
  log "System packages installed"
else
  log "System packages already present — skipping"
fi

# Python 3.12 (required by Isaac Sim 6.0)
if python3.12 --version &>/dev/null; then
  log "Python 3.12 already installed — skipping"
else
  info "Installing Python 3.12..."
  add-apt-repository -y ppa:deadsnakes/ppa > /dev/null
  apt-get update -qq
  apt-get install -y --no-install-recommends python3.12 python3.12-venv python3.12-dev > /dev/null
  log "Python 3.12 installed"
fi

# =============================================================================
# STEP 3: Isaac Sim 6.0 via pip (idempotent)
# Skip if venv already contains isaacsim at target version.
# =============================================================================
step "STEP 3: Isaac Sim ${ISAAC_VERSION}"

ISAAC_INSTALLED_VERSION=""
if [[ -f "${VENV_DIR}/bin/python" ]]; then
  ISAAC_INSTALLED_VERSION=$(
    sudo -u "$UBUNTU_USER" bash -c "
      source ${VENV_DIR}/bin/activate
      python -c 'import isaacsim; print(isaacsim.__version__)' 2>/dev/null || true
    " || true
  )
fi

if [[ "$ISAAC_INSTALLED_VERSION" == "${ISAAC_VERSION}"* ]]; then
  log "Isaac Sim ${ISAAC_INSTALLED_VERSION} already installed — skipping"
else
  if [[ -n "$ISAAC_INSTALLED_VERSION" ]]; then
    warn "Isaac Sim ${ISAAC_INSTALLED_VERSION} found, upgrading to ${ISAAC_VERSION}..."
  else
    info "Installing Isaac Sim ${ISAAC_VERSION} (this takes 20-40 min)..."
  fi

  # Create or reuse venv
  if [[ ! -d "$VENV_DIR" ]]; then
    sudo -u "$UBUNTU_USER" python3.12 -m venv "$VENV_DIR"
  fi

  sudo -u "$UBUNTU_USER" bash -c "
    source ${VENV_DIR}/bin/activate
    pip install --upgrade pip --quiet
    OMNI_KIT_ACCEPT_EULA=YES pip install \
      'isaacsim[all,extscache]==${ISAAC_VERSION}' \
      --extra-index-url https://pypi.nvidia.com \
      --quiet
  "
  log "Isaac Sim ${ISAAC_VERSION} installed"
fi

# Launcher script (always rewrite to ensure up to date)
cat > "${UBUNTU_HOME}/launch-isaac-sim.sh" << 'LAUNCHER'
#!/usr/bin/env bash
# Launch Isaac Sim (GUI mode)
source ~/isaac-venv/bin/activate
export OMNI_KIT_ACCEPT_EULA=YES
isaacsim isaacsim.exp.full "$@"
LAUNCHER
chmod +x "${UBUNTU_HOME}/launch-isaac-sim.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${UBUNTU_HOME}/launch-isaac-sim.sh"

# Desktop shortcut for Selkies
mkdir -p "${UBUNTU_HOME}/Desktop"
cat > "${UBUNTU_HOME}/Desktop/IsaacSim.desktop" << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Isaac Sim 6.0
Comment=NVIDIA Isaac Sim
Exec=/home/ubuntu/launch-isaac-sim.sh
Terminal=false
Categories=Science;Simulation;
DESKTOP
chmod +x "${UBUNTU_HOME}/Desktop/IsaacSim.desktop"
chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${UBUNTU_HOME}/Desktop"

# =============================================================================
# STEP 4: Oh-My-Zsh + plugins (idempotent)
# =============================================================================
step "STEP 4: Oh-My-Zsh"

if [[ -d "${UBUNTU_HOME}/.oh-my-zsh" ]]; then
  log "Oh-My-Zsh already installed — skipping install"
else
  info "Installing Oh-My-Zsh..."
  sudo -u "$UBUNTU_USER" bash -c '
    RUNZSH=no CHSH=no sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  '
  log "Oh-My-Zsh installed"
fi

# Plugins (idempotent: clone only if dir missing)
ZSH_CUSTOM="${UBUNTU_HOME}/.oh-my-zsh/custom"

clone_if_missing() {
  local repo="$1" dest="$2"
  if [[ -d "$dest" ]]; then
    info "$(basename $dest) already present — skipping"
  else
    sudo -u "$UBUNTU_USER" git clone --depth=1 "$repo" "$dest" 2>/dev/null
    log "$(basename $dest) installed"
  fi
}

clone_if_missing \
  https://github.com/zsh-users/zsh-autosuggestions \
  "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"

clone_if_missing \
  https://github.com/zsh-users/zsh-syntax-highlighting \
  "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"

clone_if_missing \
  https://github.com/romkatv/powerlevel10k.git \
  "${ZSH_CUSTOM}/themes/powerlevel10k"

# Write .zshrc (always rewrite to keep in sync)
sudo -u "$UBUNTU_USER" tee "${UBUNTU_HOME}/.zshrc" > /dev/null << 'ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  docker
  python
  history
)

source $ZSH/oh-my-zsh.sh

# ── Isaac Sim ──────────────────────────────────────────────────────
alias isaac='source ~/isaac-venv/bin/activate'
alias isaacsim-run='~/launch-isaac-sim.sh'

# ── nvm ───────────────────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]            && source "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ]   && source "$NVM_DIR/bash_completion"

# ── PATH ──────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
ZSHRC

# Set zsh as default shell (idempotent)
CURRENT_SHELL=$(getent passwd "$UBUNTU_USER" | cut -d: -f7)
if [[ "$CURRENT_SHELL" == "$(which zsh)" ]]; then
  log "zsh already default shell — skipping"
else
  chsh -s "$(which zsh)" "$UBUNTU_USER"
  log "Default shell set to zsh"
fi

# =============================================================================
# STEP 5: Node.js 20 + Claude Code (idempotent)
# =============================================================================
step "STEP 5: Node.js + Claude Code"

# Check if claude is already installed and up to date
CLAUDE_INSTALLED=false
if sudo -u "$UBUNTU_USER" bash -c '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
  command -v claude &>/dev/null
' 2>/dev/null; then
  CLAUDE_INSTALLED=true
fi

if $CLAUDE_INSTALLED; then
  log "Claude Code already installed — skipping"
else
  info "Installing nvm + Node.js 20 + Claude Code..."

  # Install nvm if missing
  if [[ ! -d "${UBUNTU_HOME}/.nvm" ]]; then
    sudo -u "$UBUNTU_USER" bash -c \
      'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
  fi

  sudo -u "$UBUNTU_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    source "$NVM_DIR/nvm.sh"

    # Install Node 20 if not present
    if ! nvm ls 20 &>/dev/null; then
      nvm install 20
    fi
    nvm use 20
    nvm alias default 20

    # npm global without sudo
    mkdir -p ~/.npm-global
    npm config set prefix "~/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"

    # Install Claude Code
    npm install -g @anthropic-ai/claude-code --quiet
  '
  log "Claude Code installed"
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Setup Complete!                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Desktop  : https://<instance>.brevlab.com       ║${NC}"
echo -e "${GREEN}║  Isaac Sim: ~/launch-isaac-sim.sh                ║${NC}"
echo -e "${GREEN}║  Claude   : claude  (first run → browser login)  ║${NC}"
echo -e "${GREEN}║  Shell    : reconnect SSH to use zsh             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
