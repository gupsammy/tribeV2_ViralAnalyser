#!/usr/bin/env bash
# bootstrap.sh — first-boot setup for TRIBE v2 ViralAnalyser on Ubuntu 22.04 + NVIDIA.
# Replaces start_mvp.ps1 for AWS / Linux deployments.
# Idempotent — safe to re-run after fixing a partial failure.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/gupsammy/tribeV2_ViralAnalyser.git}"
APP_USER="${APP_USER:-ubuntu}"
WORKSPACE="${WORKSPACE:-/workspace}"
DATA_DEVICE="${DATA_DEVICE:-/dev/nvme1n1}"   # Nitro renames /dev/sdf to /dev/nvme1n1
APP_DIR="$WORKSPACE/app"
VENV_DIR="$APP_DIR/.venv"

exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "[bootstrap] $(date -u) starting (repo=$REPO_URL workspace=$WORKSPACE)"

# ----------------------------------------------------------------------------
# 1. Mount data EBS volume at $WORKSPACE
#    Wait up to 2 minutes for the attachment to appear; fall back to root vol.
# ----------------------------------------------------------------------------
for _ in {1..60}; do
  [[ -b "$DATA_DEVICE" ]] && break
  sleep 2
done

if [[ -b "$DATA_DEVICE" ]]; then
  if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
    echo "[bootstrap] formatting $DATA_DEVICE as ext4 (first boot only)"
    mkfs.ext4 -F "$DATA_DEVICE"
  fi
  mkdir -p "$WORKSPACE"
  if ! mountpoint -q "$WORKSPACE"; then
    UUID=$(blkid -s UUID -o value "$DATA_DEVICE")
    grep -q "$UUID" /etc/fstab \
      || echo "UUID=$UUID $WORKSPACE ext4 defaults,nofail 0 2" >>/etc/fstab
    mount "$WORKSPACE"
  fi
else
  echo "[bootstrap] WARNING: $DATA_DEVICE never appeared; placing $WORKSPACE on root volume"
  mkdir -p "$WORKSPACE"
fi
chown "$APP_USER":"$APP_USER" "$WORKSPACE"

# ----------------------------------------------------------------------------
# 2. System packages
#    DLAMI Base GPU ships NVIDIA drivers + CUDA; we add app-level deps.
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  git python3 python3-venv python3-pip \
  chromium-browser ffmpeg curl ca-certificates

CHROME_BIN=$(command -v chromium-browser || command -v chromium || true)
[[ -n "$CHROME_BIN" ]] || { echo "[bootstrap] no chromium binary found"; exit 1; }

# ----------------------------------------------------------------------------
# 3. Clone repo into $APP_DIR
# ----------------------------------------------------------------------------
sudo -u "$APP_USER" -H bash <<EOF
set -euo pipefail
if [[ ! -d "$APP_DIR/.git" ]]; then
  git clone "$REPO_URL" "$APP_DIR"
else
  cd "$APP_DIR" && git fetch --all && git pull --ff-only
fi
EOF

# ----------------------------------------------------------------------------
# 4. Python venv + dependencies
#    'uv' provides the 'uvx' shim that tribe_runtime.py shells out to for whisperx.
#    CUDA 12.4 wheel for torch 2.6 matches the DLAMI Base GPU driver stack.
# ----------------------------------------------------------------------------
sudo -u "$APP_USER" -H bash <<EOF
set -euo pipefail
cd "$APP_DIR"
[[ -d "$VENV_DIR" ]] || python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip wheel
pip install --extra-index-url https://download.pytorch.org/whl/cu124 'torch>=2.5.1,<2.7'
pip install -r requirements.txt
pip install uv
EOF

# ----------------------------------------------------------------------------
# 5. App env file (read by the systemd unit)
# ----------------------------------------------------------------------------
cat >/etc/viralanalyser.env <<EOF
TRIBE_CACHE_DIR=$WORKSPACE/tribe_cache
TRIBE_CHROME_PATH=$CHROME_BIN
PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin:/bin
EOF
chown "$APP_USER":"$APP_USER" /etc/viralanalyser.env
chmod 644 /etc/viralanalyser.env

# ----------------------------------------------------------------------------
# 6. Pre-pull TRIBE + Whisper checkpoints (~5GB)
#    Pays the first-run download cost here, not on the first user request.
# ----------------------------------------------------------------------------
sudo -u "$APP_USER" -H bash <<EOF
set -euo pipefail
source "$VENV_DIR/bin/activate"
cd "$APP_DIR"
TRIBE_CACHE_DIR="$WORKSPACE/tribe_cache" python bootstrap_models.py
EOF

# ----------------------------------------------------------------------------
# 7. Ollama + qwen3:8b (matches app's qwen fallback; fits in L4 24GB VRAM)
# ----------------------------------------------------------------------------
if ! command -v ollama &>/dev/null; then
  echo "[bootstrap] installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable ollama
systemctl start ollama
# Wait for the API to be ready, then pull the model
for _ in {1..30}; do
  curl -sf http://localhost:11434/api/tags &>/dev/null && break
  sleep 2
done
ollama pull qwen3:8b || echo "[bootstrap] WARNING: ollama pull failed; app will use fallback copy"

# ----------------------------------------------------------------------------
# 8. systemd unit
# ----------------------------------------------------------------------------
install -m 0644 "$APP_DIR/deploy/aws/viralanalyser.service" \
  /etc/systemd/system/viralanalyser.service
systemctl daemon-reload
systemctl enable viralanalyser
systemctl restart viralanalyser

echo "[bootstrap] $(date -u) complete; service status:"
systemctl --no-pager status viralanalyser || true
