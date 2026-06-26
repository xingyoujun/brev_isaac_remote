#!/usr/bin/env bash
# =============================================================================
# Brev GPU Dev Box Setup (Idempotent, Host-Native, SSH-only)
# Base: Ubuntu 22.04, NVIDIA L40S, Driver 580 (driver 由镜像预装, 本脚本不动它)
#
# What gets installed (all on host, NO Docker, NO remote desktop):
#   - Base system / build tooling + SSH 常用工具 (tmux/htop/nvtop/vim ...)
#   - 经典工具/媒体: unzip zip ffmpeg tree rsync ncdu jq net-tools
#   - Vulkan: libvulkan1 mesa-vulkan-drivers vulkan-tools (GPU 渲染/计算)
#   - CUDA Toolkit 12.6   → /usr/local/cuda-12.6  (nvcc + 库, 仅工具链, 不含 driver)
#   - Miniconda           → ~/miniconda3
#   - uv (Astral)         → ~/.local/bin
#   - Oh-My-Zsh + Powerlevel10k
#   - Claude Code (Node.js 20)
#
# 不创建任何 Python 环境/不装 torch: conda 与 uv 都是空的, 由你自己起 env。
#
# 关键: 装的是 cuda-toolkit-12-6 (不是 cuda / cuda-12-6), 所以 NVIDIA 驱动
#       保持镜像自带的 580 不变。driver 580 向前兼容, 可正常跑 12.6 编译产物。
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

UBUNTU_USER="${SUDO_USER:-ubuntu}"
UBUNTU_HOME="/home/${UBUNTU_USER}"
CUDA_VER="12.6"
CUDA_PKG="cuda-toolkit-12-6"        # 仅工具链, 不含 driver
CUDA_DIR="/usr/local/cuda-${CUDA_VER}"
CONDA_DIR="${UBUNTU_HOME}/miniconda3"

[[ "$(id -u)" == "0" ]] || die "Run as root: curl ... | sudo -E bash"

# =============================================================================
# STEP 1: System dependencies
# =============================================================================
step "STEP 1: System dependencies"

apt-get update -qq

ALL_PKGS=(
  # 基础 / 网络
  curl wget git ca-certificates gnupg software-properties-common
  # 编译工具链 (nvcc 需要宿主 gcc/g++/make; Ubuntu 22.04 的 gcc-11 适配 CUDA 12.6)
  build-essential pkg-config
  # SSH 工作流常用
  zsh tmux htop nvtop vim
  # 经典工具 / 媒体
  unzip zip ffmpeg tree rsync ncdu jq net-tools
  # Vulkan (GPU 渲染/计算; NVIDIA 的 Vulkan ICD 由驱动提供, 这里装 loader+工具)
  libvulkan1 mesa-vulkan-drivers vulkan-tools
  # 轻量 Python 兜底 (主力用 conda / uv)
  python3-pip python3-venv
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

# =============================================================================
# STEP 2: CUDA Toolkit 12.6 (本地工具链, nvcc) —— 不安装/不改动 NVIDIA driver
#   通过 NVIDIA 官方 apt repo (cuda-keyring) 安装到 /usr/local/cuda-12.6
# =============================================================================
step "STEP 2: CUDA Toolkit ${CUDA_VER} (nvcc, toolkit-only)"

if [[ -x "${CUDA_DIR}/bin/nvcc" ]]; then
  log "CUDA ${CUDA_VER} toolkit already installed (${CUDA_DIR}) — skipping"
else
  if ! command -v nvidia-smi &>/dev/null; then
    warn "未检测到 nvidia-smi —— 请确认使用的是带 NVIDIA 驱动的 GPU 镜像"
  fi
  info "Adding NVIDIA CUDA apt repo (cuda-keyring)..."
  KEYRING_DEB=/tmp/cuda-keyring.deb
  curl -fsSL -o "$KEYRING_DEB" \
    "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"
  dpkg -i "$KEYRING_DEB" > /dev/null
  rm -f "$KEYRING_DEB"
  apt-get update -qq

  info "Installing ${CUDA_PKG} (~5GB, 仅工具链, 不含 driver, 5-15 min)..."
  # 只装 toolkit。绝不要装 'cuda' 或 'cuda-12-6'，否则会连带安装驱动并与 580 冲突。
  apt-get install -y --no-install-recommends "${CUDA_PKG}" > /dev/null 2>&1 || \
    apt-get install -y --no-install-recommends "${CUDA_PKG}"
  log "CUDA ${CUDA_VER} toolkit installed → ${CUDA_DIR}"
fi

# =============================================================================
# STEP 3: Miniconda  →  ~/miniconda3
# =============================================================================
step "STEP 3: Miniconda"

if [[ -x "${CONDA_DIR}/bin/conda" ]]; then
  log "Miniconda already installed (${CONDA_DIR}) — skipping"
else
  info "Downloading & installing Miniconda (latest)..."
  sudo -u "$UBUNTU_USER" bash -c "
    set -e
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p '${CONDA_DIR}'
    rm -f /tmp/miniconda.sh
  "
  log "Miniconda installed → ${CONDA_DIR}"
fi

# 让 bash 登录 shell 也能用 conda (zsh 的初始化在 STEP 5 的 .zshrc 里手写)
sudo -u "$UBUNTU_USER" "${CONDA_DIR}/bin/conda" init bash > /dev/null 2>&1 || true
# 不自动激活 base, 避免每个 shell 都带 (base) 前缀; 需要时手动 `conda activate base`
sudo -u "$UBUNTU_USER" "${CONDA_DIR}/bin/conda" config --set auto_activate_base false || true
log "conda initialized (bash); auto_activate_base=false"

# =============================================================================
# STEP 4: uv (Astral) —— 装到 ~/.local/bin, 不改 shell 配置 (PATH 已在 .zshrc 里)
# =============================================================================
step "STEP 4: uv"

if sudo -u "$UBUNTU_USER" bash -c 'export PATH="$HOME/.local/bin:$PATH"; command -v uv &>/dev/null'; then
  UV_VER=$(sudo -u "$UBUNTU_USER" bash -c 'export PATH="$HOME/.local/bin:$PATH"; uv --version' 2>/dev/null || echo "")
  log "uv already installed (${UV_VER}) — skipping"
else
  info "Installing uv (Astral)..."
  # UV_NO_MODIFY_PATH=1 → 不写入 .zshrc/.bashrc/.profile, 保证幂等; 默认装到 ~/.local/bin
  sudo -u "$UBUNTU_USER" bash -c \
    'curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
  log "uv installed → ${UBUNTU_HOME}/.local/bin/uv"
fi

# =============================================================================
# STEP 5: Oh-My-Zsh + plugins + 环境变量 (CUDA / conda) —— idempotent
# =============================================================================
step "STEP 5: Oh-My-Zsh"

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

# 注意: 'ZSHRC' 用单引号包裹 => heredoc 内所有 $ 均按字面写入, 运行时再展开
sudo -u "$UBUNTU_USER" tee "${UBUNTU_HOME}/.zshrc" > /dev/null << 'ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting python history)
source $ZSH/oh-my-zsh.sh

# ---- CUDA Toolkit 12.6 ----
export CUDA_HOME=/usr/local/cuda-12.6
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"

# ---- Node / nvm ----
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]          && source "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# >>> conda initialize >>>
__conda_setup="$("$HOME/miniconda3/bin/conda" 'shell.zsh' 'hook' 2>/dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
        . "$HOME/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="$HOME/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<
ZSHRC
log ".zshrc written (CUDA + conda + nvm)"

CURRENT_SHELL=$(getent passwd "$UBUNTU_USER" | cut -d: -f7)
[[ "$CURRENT_SHELL" == "$(which zsh)" ]] \
  && log "zsh already default shell — skipping" \
  || { chsh -s "$(which zsh)" "$UBUNTU_USER"; log "Default shell set to zsh"; }

# =============================================================================
# STEP 6: Node.js 20 + Claude Code (idempotent)
# =============================================================================
step "STEP 6: Node.js + Claude Code"

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
NVCC_VER=$("${CUDA_DIR}/bin/nvcc" --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo "n/a")
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Dev Box Setup Complete!                  ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Shell    reconnect SSH to use zsh                 ║${NC}"
echo -e "${GREEN}║  CUDA     nvcc --version  (release ${NVCC_VER})            ${NC}"
echo -e "${GREEN}║  conda    conda create -n myenv python=3.11        ║${NC}"
echo -e "${GREEN}║           conda activate myenv                     ║${NC}"
echo -e "${GREEN}║  uv       uv venv && source .venv/bin/activate     ║${NC}"
echo -e "${GREEN}║  vulkan   vulkaninfo | head  (验证 Vulkan)          ║${NC}"
echo -e "${GREEN}║  Claude   claude   (first run → browser/device login)${NC}"
echo -e "${GREEN}║  GPU      nvidia-smi  /  nvtop                     ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  注意: nvidia-smi 顶部显示的 CUDA 版本是 driver     ║${NC}"
echo -e "${GREEN}║  支持的最高版本(如 13.0), 与 nvcc 的 12.6 不冲突.   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
