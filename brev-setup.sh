#!/usr/bin/env bash
# =============================================================================
# Brev One-Click Setup Script (Idempotent, Host-Native, GPU-Accelerated)
#
# Architecture:
#   宿主机直接运行（无 Docker）:
#     - headless Xorg + NVIDIA driver  → Isaac Sim RTX GPU 全速渲染
#     - Selkies-GStreamer (systemd)    → nvh264enc 硬件编码流媒体
#     - coturn (systemd)              → TCP+UDP TURN 双栈，WebRTC 保底
#     - Xfce4                         → 轻量桌面环境
#     - Isaac Sim 6.0 (pip)           → ~/isaac-venv，首次安装预热 shader
#     - Oh-My-Zsh + Powerlevel10k
#     - Claude Code (Node.js 20)
#
# 重复运行安全：每步幂等检查，重启后只更新 TURN IP，其余全部跳过。
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date -u '+%H:%M:%S')] ✓ $*${NC}"; }
info() { echo -e "${CYAN}[$(date -u '+%H:%M:%S')]   $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date -u '+%H:%M:%S')] ⚠ $*${NC}"; }
die()  { echo -e "${RED}[$(date -u '+%H:%M:%S')] ✗ $*${NC}"; exit 1; }
step() { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"
         echo -e "${CYAN}  $*${NC}"
         echo -e "${CYAN}══════════════════════════════════════════════${NC}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
UBUNTU_USER="${SUDO_USER:-ubuntu}"
UBUNTU_HOME="/home/${UBUNTU_USER}"
ISAAC_VERSION="${ISAAC_VERSION:-6.0.0}"
VENV_DIR="${UBUNTU_HOME}/isaac-venv"
SELKIES_PORT="${SELKIES_PORT:-8080}"
TURN_PORT="${TURN_PORT:-47998}"
TURN_MIN_PORT="${TURN_MIN_PORT:-47999}"
TURN_MAX_PORT="${TURN_MAX_PORT:-48015}"
DISPLAY_NUM=":0"           # Xorg (GPU) 用 :0，不用 Xvfb
SELKIES_INSTALL_DIR="/opt/selkies-gstreamer"
XORG_CONF="/etc/X11/xorg.conf"
TURN_SECRET_FILE="/etc/selkies-turn-secret"

[[ "$(id -u)" == "0" ]] || die "Run as root: curl ... | sudo -E bash"

# =============================================================================
# STEP 0: Detect public IP
# =============================================================================
step "STEP 0: Detecting public IP"

detect_public_ip() {
  local ip
  ip=$(curl -fsSL --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  for url in https://icanhazip.com https://api.ipify.org https://ifconfig.me/ip; do
    ip=$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}

PUBLIC_IP=$(detect_public_ip || true)
[[ -n "$PUBLIC_IP" ]] && log "Public IP: $PUBLIC_IP" \
  || warn "Could not detect public IP — TURN may not work correctly"

# =============================================================================
# STEP 1: System dependencies
# =============================================================================
step "STEP 1: System dependencies"

apt-get update -qq

ALL_PKGS=(
  # Base
  curl wget git jq tar gzip ca-certificates software-properties-common build-essential zsh
  # Xorg + NVIDIA xorg driver
  xserver-xorg-core xserver-xorg-legacy x11-utils x11-xserver-utils x11-xkb-utils xauth
  # Xfce4 desktop
  xfce4 xfce4-terminal xfce4-screenshooter xdg-utils dbus-x11
  # Selkies host deps (official list)
  libpulse0 pulseaudio
  wayland-protocols libwayland-dev libwayland-egl1
  libx11-xcb1 libxcb-dri3-0 libxkbcommon0 libxdamage1 libxfixes3 libxv1 libxtst6 libxext6
  # coturn TURN server
  coturn
  # Python
  python3-pip python3-venv
  # nvidia-xconfig tool
  nvidia-prime
)

PKGS_NEEDED=()
for pkg in "${ALL_PKGS[@]}"; do
  dpkg -s "$pkg" &>/dev/null || PKGS_NEEDED+=("$pkg")
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
  info "Installing ${#PKGS_NEEDED[@]} packages..."
  apt-get install -y --no-install-recommends "${PKGS_NEEDED[@]}" > /dev/null 2>&1 || \
    apt-get install -y --no-install-recommends "${PKGS_NEEDED[@]}"
  log "System packages installed"
else
  log "System packages already present — skipping"
fi

# Python 3.12
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
# STEP 2: Headless Xorg + NVIDIA GPU (replaces Xvfb)
#
# Key points:
#  - L40S 没有物理显示输出，需要 AllowEmptyInitialConfiguration
#  - ConnectedMonitor + Virtual 强制 1920x1080 虚拟屏幕
#  - BusID 从 nvidia-smi 动态读取，适配不同实例
# =============================================================================
step "STEP 2: Headless Xorg + NVIDIA GPU"

# 动态获取 GPU 的 PCI BusID
get_gpu_busid() {
  # nvidia-smi 输出格式: "00000000:30:00.0"，转换为 Xorg 格式 "PCI:48:0:0"
  local raw
  raw=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 || true)
  if [[ -z "$raw" ]]; then
    echo "PCI:0:0:0"
    return
  fi
  # 格式: 00000000:30:00.0 → bus=0x30=48, slot=0x00=0, func=0
  local domain bus slot func
  IFS=':.' read -r domain bus slot func <<< "$raw"
  local bus_dec slot_dec func_dec
  bus_dec=$((16#$bus))
  slot_dec=$((16#$slot))
  func_dec=$((16#${func:-0}))
  echo "PCI:${bus_dec}:${slot_dec}:${func_dec}"
}

GPU_BUSID=$(get_gpu_busid)
info "GPU BusID: $GPU_BUSID"

# Allow Xorg to run as non-root (needed for systemd service as ubuntu user)
cat > /etc/X11/Xwrapper.config << 'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP

# Write Xorg config (always rewrite — BusID may change after instance restart)
cat > "$XORG_CONF" << XORGEOF
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0"
EndSection

Section "Device"
    Identifier     "NvidiaGPU"
    Driver         "nvidia"
    BusID          "${GPU_BUSID}"
    # Allow starting without a physical monitor attached
    Option         "AllowEmptyInitialConfiguration" "true"
    # Fake a connected digital display so NVIDIA driver sets a real mode
    Option         "ConnectedMonitor" "DFP-0"
    # Enable GPU rendering even without a display
    Option         "HardDPMS" "false"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "NvidiaGPU"
    DefaultDepth   24
    SubSection "Display"
        Depth      24
        Virtual    1920 1080
        Modes      "1920x1080"
    EndSubSection
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    HorizSync      28.0 - 160.0
    VertRefresh    24.0 - 144.0
    Option         "DPMS" "false"
EndSection
XORGEOF

log "Xorg config written (GPU: ${GPU_BUSID})"

# =============================================================================
# STEP 3: Selkies-GStreamer (host-native portable tarball)
# =============================================================================
step "STEP 3: Selkies-GStreamer"

install_selkies() {
  info "Fetching latest Selkies-GStreamer release..."
  local version
  version=$(curl -fsSL "https://api.github.com/repos/selkies-project/selkies/releases/latest" \
    | jq -r '.tag_name' | sed 's/[^0-9\.\-]*//g')
  info "Installing Selkies-GStreamer v${version}..."
  mkdir -p "$SELKIES_INSTALL_DIR"
  curl -fsSL \
    "https://github.com/selkies-project/selkies/releases/download/v${version}/selkies-gstreamer-portable-v${version}_amd64.tar.gz" \
    | tar -xzf - -C "$SELKIES_INSTALL_DIR" --strip-components=1
  echo "$version" > "${SELKIES_INSTALL_DIR}/.version"
  log "Selkies-GStreamer v${version} installed"
}

if [[ -f "${SELKIES_INSTALL_DIR}/selkies-gstreamer-run" ]]; then
  log "Selkies-GStreamer already installed — skipping"
else
  install_selkies
fi

# =============================================================================
# STEP 4: coturn TURN server (TCP + UDP 双栈)
#
# 修复 WebRTC 穿透问题：
#  - UDP 47998-48015: 直接 P2P，延迟最低
#  - TCP 47998: 保底 relay，当 UDP 被拦截时自动回落
#  - 每次重启重写配置，确保 external-ip 始终正确
# =============================================================================
step "STEP 4: coturn TURN server (TCP+UDP)"

# 生成或复用 TURN 密钥（重启后保持一致）
if [[ ! -f "$TURN_SECRET_FILE" ]]; then
  openssl rand -hex 16 > "$TURN_SECRET_FILE"
fi
TURN_SECRET=$(cat "$TURN_SECRET_FILE")

TURN_EXTERNAL_LINE=""
[[ -n "$PUBLIC_IP" ]] && TURN_EXTERNAL_LINE="external-ip=${PUBLIC_IP}"

# 每次都重写 coturn 配置（确保 IP 更新）
cat > /etc/turnserver.conf << TURNEOF
# coturn config — auto-generated by brev-setup.sh
listening-port=${TURN_PORT}
tls-listening-port=5349
min-port=${TURN_MIN_PORT}
max-port=${TURN_MAX_PORT}
realm=selkies.local
${TURN_EXTERNAL_LINE}

# 同时启用 TCP 和 UDP（双栈保底）
no-udp=false
no-tcp=false

# 认证
lt-cred-mech
user=selkies:${TURN_SECRET}

# 稳定性
channel-lifetime=-1
no-cli
allow-loopback-peers
fingerprint

log-file=/var/log/turnserver.log
pidfile=/var/run/turnserver.pid
TURNEOF

systemctl enable coturn > /dev/null 2>&1 || true
systemctl restart coturn
log "coturn running — UDP+TCP on ${TURN_PORT}, relay ports ${TURN_MIN_PORT}-${TURN_MAX_PORT}"

# =============================================================================
# STEP 5: systemd services (Xorg + Xfce4 + Selkies)
# =============================================================================
step "STEP 5: Systemd services"

RUNTIME_DIR="/tmp/runtime-${UBUNTU_USER}"

# ── 5a. Xorg service (GPU 显示服务器) ─────────────────────────────────────────
cat > /etc/systemd/system/xorg-gpu.service << XORGSERVICE
[Unit]
Description=Xorg GPU Display Server (headless NVIDIA)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=simple
User=root
# 等待 NVIDIA 驱动完全就绪
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do nvidia-smi > /dev/null 2>&1 && break || sleep 2; done'
ExecStart=/usr/bin/Xorg ${DISPLAY_NUM} -config ${XORG_CONF} -noreset +extension GLX +extension RANDR +extension RENDER
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
XORGSERVICE

# ── 5b. Xfce4 session service ──────────────────────────────────────────────────
cat > /etc/systemd/system/xfce4-session.service << XFCESERVICE
[Unit]
Description=Xfce4 Desktop Session
After=xorg-gpu.service
Requires=xorg-gpu.service

[Service]
Type=simple
User=${UBUNTU_USER}
Environment=DISPLAY=${DISPLAY_NUM}
Environment=XDG_RUNTIME_DIR=${RUNTIME_DIR}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=${RUNTIME_DIR}/bus
ExecStartPre=/bin/bash -c 'mkdir -p ${RUNTIME_DIR} && chmod 700 ${RUNTIME_DIR}'
# 等待 Xorg 接受连接
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 20); do DISPLAY=${DISPLAY_NUM} xdpyinfo > /dev/null 2>&1 && break || sleep 1; done'
ExecStart=/usr/bin/startxfce4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
XFCESERVICE

# ── 5c. Selkies streaming service ─────────────────────────────────────────────
cat > /etc/systemd/system/selkies-desktop.service << SELKIESSERVICE
[Unit]
Description=Selkies WebRTC Remote Desktop Stream
After=xfce4-session.service
Requires=xfce4-session.service

[Service]
Type=simple
User=${UBUNTU_USER}
Environment=DISPLAY=${DISPLAY_NUM}
Environment=XDG_RUNTIME_DIR=${RUNTIME_DIR}
Environment=PULSE_RUNTIME_PATH=${RUNTIME_DIR}/pulse
Environment=PULSE_SERVER=unix:${RUNTIME_DIR}/pulse/native
Environment=PIPEWIRE_LATENCY=128/48000

ExecStartPre=/bin/bash -c 'mkdir -p ${RUNTIME_DIR}/pulse'
# 等待 Xfce4 桌面完全渲染
ExecStartPre=/bin/bash -c 'sleep 5'

ExecStart=${SELKIES_INSTALL_DIR}/selkies-gstreamer-run \
    --addr=0.0.0.0 \
    --port=${SELKIES_PORT} \
    --enable_https=false \
    --enable_basic_auth=false \
    --enable_resize=true \
    --encoder=nvh264enc \
    --video_bitrate=8000 \
    --framerate=60 \
    --turn_host=${PUBLIC_IP:-127.0.0.1} \
    --turn_port=${TURN_PORT} \
    --turn_username=selkies \
    --turn_password=${TURN_SECRET} \
    --turn_protocol=udp \
    --turn_enable_tcp=true

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SELKIESSERVICE

# 重载并启动所有服务
systemctl daemon-reload
for svc in xorg-gpu xfce4-session selkies-desktop; do
  systemctl enable "$svc" > /dev/null 2>&1
  systemctl restart "$svc"
  log "$svc service started"
done

# Healthcheck
info "Waiting for Selkies to be ready (up to 2 min)..."
for i in $(seq 1 24); do
  if curl -fsS "http://127.0.0.1:${SELKIES_PORT}/" > /dev/null 2>&1; then
    log "Selkies healthcheck passed ✓"
    break
  fi
  [[ $i -eq 24 ]] && warn "Selkies not yet responding — check: journalctl -u selkies-desktop -f"
  sleep 5
done

# =============================================================================
# STEP 6: Isaac Sim 6.0 via pip (idempotent + shader 预热)
# =============================================================================
step "STEP 6: Isaac Sim ${ISAAC_VERSION}"

ISAAC_INSTALLED_VERSION=""
if [[ -f "${VENV_DIR}/bin/python" ]]; then
  ISAAC_INSTALLED_VERSION=$(
    sudo -u "$UBUNTU_USER" bash -c "
      source ${VENV_DIR}/bin/activate 2>/dev/null
      python -c 'import isaacsim; print(isaacsim.__version__)' 2>/dev/null || true
    " || true
  )
fi

if [[ "$ISAAC_INSTALLED_VERSION" == "${ISAAC_VERSION}"* ]]; then
  log "Isaac Sim ${ISAAC_INSTALLED_VERSION} already installed — skipping"
else
  [[ -n "$ISAAC_INSTALLED_VERSION" ]] \
    && info "Upgrading Isaac Sim ${ISAAC_INSTALLED_VERSION} → ${ISAAC_VERSION}..." \
    || info "Installing Isaac Sim ${ISAAC_VERSION} (20-40 min)..."

  [[ ! -d "$VENV_DIR" ]] && sudo -u "$UBUNTU_USER" python3.12 -m venv "$VENV_DIR"

  sudo -u "$UBUNTU_USER" bash -c "
    source ${VENV_DIR}/bin/activate
    pip install --upgrade pip --quiet
    OMNI_KIT_ACCEPT_EULA=YES pip install \
      'isaacsim[all,extscache]==${ISAAC_VERSION}' \
      --extra-index-url https://pypi.nvidia.com \
      --quiet
  "
  log "Isaac Sim ${ISAAC_VERSION} installed"

  # ── Shader 预热（避免首次 GUI 启动时卡顿 5-15 分钟）──────────────────────────
  info "Pre-warming Isaac Sim shaders (this runs headless, ~5 min)..."
  sudo -u "$UBUNTU_USER" bash -c "
    source ${VENV_DIR}/bin/activate
    export OMNI_KIT_ACCEPT_EULA=YES
    export DISPLAY=${DISPLAY_NUM}
    # 无窗口模式启动后立即关闭，触发 shader 缓存编译
    timeout 300 isaacsim isaacsim.exp.full \
      --no-window \
      --/app/fastShutdown=1 \
      --/app/extensions/excluded/0=omni.kit.splash \
      2>/dev/null || true
  " || warn "Shader pre-warm timed out (non-fatal, will compile on first GUI launch)"
  log "Shader pre-warm complete"
fi

# Launcher script
cat > "${UBUNTU_HOME}/launch-isaac-sim.sh" << 'LAUNCHER'
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-:0}"
source ~/isaac-venv/bin/activate
export OMNI_KIT_ACCEPT_EULA=YES
isaacsim isaacsim.exp.full "$@"
LAUNCHER
chmod +x "${UBUNTU_HOME}/launch-isaac-sim.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${UBUNTU_HOME}/launch-isaac-sim.sh"

# Desktop shortcut
mkdir -p "${UBUNTU_HOME}/Desktop"
cat > "${UBUNTU_HOME}/Desktop/IsaacSim.desktop" << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Isaac Sim 6.0
Exec=/home/ubuntu/launch-isaac-sim.sh
Terminal=false
Categories=Science;Simulation;
DESKTOP
chmod +x "${UBUNTU_HOME}/Desktop/IsaacSim.desktop"
chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${UBUNTU_HOME}/Desktop"

# =============================================================================
# STEP 7: Oh-My-Zsh (idempotent)
# =============================================================================
step "STEP 7: Oh-My-Zsh"

if [[ ! -d "${UBUNTU_HOME}/.oh-my-zsh" ]]; then
  sudo -u "$UBUNTU_USER" bash -c \
    'RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
  log "Oh-My-Zsh installed"
else
  log "Oh-My-Zsh already installed — skipping"
fi

ZSH_CUSTOM="${UBUNTU_HOME}/.oh-my-zsh/custom"
clone_if_missing() {
  local repo="$1" dest="$2"
  [[ -d "$dest" ]] && { info "$(basename $dest) already present — skipping"; return; }
  sudo -u "$UBUNTU_USER" git clone --depth=1 "$repo" "$dest" 2>/dev/null
  log "$(basename $dest) installed"
}
clone_if_missing https://github.com/zsh-users/zsh-autosuggestions    "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
clone_if_missing https://github.com/romkatv/powerlevel10k.git          "${ZSH_CUSTOM}/themes/powerlevel10k"

sudo -u "$UBUNTU_USER" tee "${UBUNTU_HOME}/.zshrc" > /dev/null << 'ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting docker python history)
source $ZSH/oh-my-zsh.sh

alias isaac='source ~/isaac-venv/bin/activate'
alias isaacsim-run='~/launch-isaac-sim.sh'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]          && source "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
export DISPLAY="${DISPLAY:-:0}"
ZSHRC

CURRENT_SHELL=$(getent passwd "$UBUNTU_USER" | cut -d: -f7)
[[ "$CURRENT_SHELL" == "$(which zsh)" ]] \
  && log "zsh already default shell — skipping" \
  || { chsh -s "$(which zsh)" "$UBUNTU_USER"; log "Default shell set to zsh"; }

# =============================================================================
# STEP 8: Node.js 20 + Claude Code (idempotent)
# =============================================================================
step "STEP 8: Node.js + Claude Code"

CLAUDE_INSTALLED=false
sudo -u "$UBUNTU_USER" bash -c '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
  command -v claude &>/dev/null
' 2>/dev/null && CLAUDE_INSTALLED=true

if $CLAUDE_INSTALLED; then
  log "Claude Code already installed — skipping"
else
  [[ ! -d "${UBUNTU_HOME}/.nvm" ]] && \
    sudo -u "$UBUNTU_USER" bash -c \
      'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
  sudo -u "$UBUNTU_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    source "$NVM_DIR/nvm.sh"
    nvm ls 20 &>/dev/null || nvm install 20
    nvm use 20 && nvm alias default 20
    mkdir -p ~/.npm-global
    npm config set prefix "~/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"
    npm install -g @anthropic-ai/claude-code --quiet
  '
  log "Claude Code installed"
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Setup Complete!                          ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Desktop    https://<instance>.brevlab.com         ║${NC}"
echo -e "${GREEN}║  Isaac Sim  ~/launch-isaac-sim.sh                  ║${NC}"
echo -e "${GREEN}║             (or double-click on desktop)           ║${NC}"
echo -e "${GREEN}║  Claude     claude  (first run → browser login)    ║${NC}"
echo -e "${GREEN}║  Shell      reconnect SSH to use zsh               ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Debug commands:                                   ║${NC}"
echo -e "${GREEN}║    journalctl -u xorg-gpu -f                       ║${NC}"
echo -e "${GREEN}║    journalctl -u xfce4-session -f                  ║${NC}"
echo -e "${GREEN}║    journalctl -u selkies-desktop -f                ║${NC}"
echo -e "${GREEN}║    journalctl -u coturn -f                         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
