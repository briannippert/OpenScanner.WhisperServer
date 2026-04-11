#!/bin/bash
set -e

# =====================================================
# OpenScanner WhisperServer Installer
# =====================================================
# Installs system dependencies, builds whisper.cpp,
# downloads a Whisper model, builds the .NET server,
# and configures a systemd service.
# =====================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }
log_success() { echo -e "${GREEN}[OK] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

# Parse Arguments
DEPS_ONLY=false
REBUILD_WHISPER=false
PORT=""
for arg in "$@"; do
  case $arg in
    --deps-only)
      DEPS_ONLY=true
      shift
      ;;
    --port=*)
      PORT="${arg#*=}"
      shift
      ;;
    --rebuild-whisper)
      REBUILD_WHISPER=true
      shift
      ;;
  esac
done

# Check NOT Root
if [ "$EUID" -eq 0 ]; then
  log_error "Please run as a regular user (NOT root)."
  log_error "The script will ask for sudo password when needed."
  exit 1
fi

# Ensure sudo is available
if ! command -v sudo &> /dev/null; then
    log_error "This script requires 'sudo' to install system dependencies."
    exit 1
fi

# Refresh sudo credentials upfront
sudo -v

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log_step "Initializing Setup"
log_info "Project Root: $PROJECT_ROOT"
log_info "User: $USER ($HOME)"

# ----------------------------------------------------------------
# 1. Stop Existing Service
# ----------------------------------------------------------------
log_step "Stopping existing service..."
if systemctl is-active --quiet openscanner-whisper; then
    sudo systemctl stop openscanner-whisper
    log_info "Service stopped."
else
    log_info "Service was not running."
fi

# ----------------------------------------------------------------
# 2. Update Code
# ----------------------------------------------------------------
log_step "Updating Repository..."
if git remote get-url origin &> /dev/null; then
    if git pull origin main; then
        log_success "Code pulled successfully."
    else
        log_warn "Git pull failed. Continuing with local files..."
    fi
else
    log_warn "No git remote found. Skipping update."
fi

# ----------------------------------------------------------------
# 3. Check .NET SDK
# ----------------------------------------------------------------
log_step "Checking Environment..."

INSTALL_DOTNET=false
if ! command -v dotnet &> /dev/null; then
    log_info ".NET SDK not found."
    INSTALL_DOTNET=true
else
    DOTNET_VER=$(dotnet --version)
    MAJOR_VER=$(echo "$DOTNET_VER" | cut -d. -f1)
    if [ "$MAJOR_VER" -lt 10 ]; then
        log_info "Found .NET SDK $DOTNET_VER, but .NET 10 is required."
        INSTALL_DOTNET=true
    else
        log_success "Found .NET SDK: $DOTNET_VER"
    fi
fi

if [ "$INSTALL_DOTNET" = true ]; then
    log_info "Attempting to install .NET 10 SDK..."

    if command -v apt-get &> /dev/null; then
        wget https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
        sudo dpkg -i packages-microsoft-prod.deb
        rm packages-microsoft-prod.deb

        sudo apt-get update -qq || log_warn "apt-get update encountered errors. Attempting to continue..."
        sudo apt-get install -y -qq dotnet-sdk-10.0
        log_success ".NET 10 SDK installed."
    else
         log_warn "Could not install .NET SDK automatically. Please install .NET 10 SDK manually."
    fi
fi

# ----------------------------------------------------------------
# 4. System Dependencies
# ----------------------------------------------------------------
log_step "Installing System Libraries..."

sudo apt-get update -qq || log_warn "apt-get update encountered errors. Attempting to continue..."
sudo apt-get install -y -qq git cmake build-essential ffmpeg jq > /dev/null
log_success "Libraries installed."

# Install NVIDIA CUDA toolkit if GPU is present but nvcc is missing
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    if ! command -v nvcc &> /dev/null; then
        log_info "NVIDIA GPU detected but CUDA toolkit not installed. Installing..."
        sudo apt-get install -y -qq nvidia-cuda-toolkit > /dev/null
        log_success "NVIDIA CUDA toolkit installed."
    fi
fi

# ----------------------------------------------------------------
# 5. Whisper Model Selection
# ----------------------------------------------------------------
log_step "Whisper Model Selection"

APPSETTINGS="$PROJECT_ROOT/appsettings.json"
CURRENT_MODEL=$(jq -r '.Whisper.ModelName // "small.en"' "$APPSETTINGS" 2>/dev/null || echo "small.en")

echo ""
echo -e "  Available Whisper models (English-only models recommended for radio):"
echo ""
echo -e "    ${BOLD}1)${NC} tiny.en      - Fastest, lowest accuracy (~75 MB)"
echo -e "    ${BOLD}2)${NC} base.en      - Fast, decent accuracy (~150 MB)"
echo -e "    ${BOLD}3)${NC} small.en     - Good balance of speed and accuracy (~500 MB)"
echo -e "    ${BOLD}4)${NC} medium.en    - High accuracy, slower (~1.5 GB)"
echo -e "    ${BOLD}5)${NC} large-v3     - Best accuracy, slowest (~3 GB, multilingual)"
echo ""
echo -e "  Current model: ${BOLD}$CURRENT_MODEL${NC}"
echo ""

read -r -p "$(echo -e "${BLUE}[INFO]${NC} Select a model [1-5] (press Enter to keep ${BOLD}$CURRENT_MODEL${NC}): ")" MODEL_CHOICE

case "$MODEL_CHOICE" in
    1) WHISPER_MODEL="tiny.en" ;;
    2) WHISPER_MODEL="base.en" ;;
    3) WHISPER_MODEL="small.en" ;;
    4) WHISPER_MODEL="medium.en" ;;
    5) WHISPER_MODEL="large-v3" ;;
    *) WHISPER_MODEL="$CURRENT_MODEL" ;;
esac

log_info "Using model: $WHISPER_MODEL"

# ----------------------------------------------------------------
# 5b. Port Selection
# ----------------------------------------------------------------
if [ -z "$PORT" ]; then
    CURRENT_PORT=$(jq -r '.Urls // empty' "$APPSETTINGS" 2>/dev/null | grep -oP ':\K[0-9]+' || echo "8090")
    [ -z "$CURRENT_PORT" ] && CURRENT_PORT="8090"

    echo ""
    read -r -p "$(echo -e "${BLUE}[INFO]${NC} Port to run the server on (press Enter to keep ${BOLD}$CURRENT_PORT${NC}): ")" PORT_CHOICE
    PORT="${PORT_CHOICE:-$CURRENT_PORT}"
fi

log_info "Using port: $PORT"

# ----------------------------------------------------------------
# 6. Whisper.cpp Setup
# ----------------------------------------------------------------
log_step "Checking Whisper.cpp..."

WHISPER_DIR="$PROJECT_ROOT/whisper.cpp"

if [ ! -d "$WHISPER_DIR" ]; then
    log_info "Cloning whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

# Detect NVIDIA GPU for CUDA acceleration
CMAKE_EXTRA_ARGS=""
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    log_success "NVIDIA GPU detected: $GPU_NAME"

    if command -v nvcc &> /dev/null; then
        log_info "CUDA toolkit found. Enabling GPU acceleration."
        CMAKE_EXTRA_ARGS="-DGGML_CUDA=ON"
    else
        log_warn "NVIDIA GPU detected but CUDA toolkit (nvcc) not found."
        log_info "Install the CUDA toolkit for GPU acceleration:"
        log_info "  sudo apt-get install nvidia-cuda-toolkit"
        log_info "Falling back to CPU-only build."
    fi
else
    log_info "No NVIDIA GPU detected. Using CPU-only build."
fi

if [ "$REBUILD_WHISPER" = true ] && [ -d "$WHISPER_DIR/build" ]; then
    log_info "Removing existing whisper.cpp build (--rebuild-whisper)..."
    rm -rf "$WHISPER_DIR/build"
fi

# Auto-detect CUDA mismatch: GPU available but binary built without CUDA
if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ] && [ -n "$CMAKE_EXTRA_ARGS" ]; then
    if ! ldd "$WHISPER_DIR/build/bin/whisper-cli" 2>/dev/null | grep -q 'libcuda'; then
        log_warn "Existing whisper-cli was built without CUDA, but GPU acceleration is available."
        log_info "Rebuilding whisper.cpp with CUDA support..."
        rm -rf "$WHISPER_DIR/build"
    fi
fi

if [ ! -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    log_info "Building whisper.cpp${CMAKE_EXTRA_ARGS:+ (with CUDA)}..."
    cd "$WHISPER_DIR"
    cmake -B build $CMAKE_EXTRA_ARGS
    cmake --build build --config Release -j$(nproc)
    log_success "Whisper.cpp built."
fi

# Download model
if [ ! -f "$WHISPER_DIR/models/ggml-$WHISPER_MODEL.bin" ]; then
    log_info "Downloading Whisper model ($WHISPER_MODEL)..."
    cd "$WHISPER_DIR"
    bash ./models/download-ggml-model.sh "$WHISPER_MODEL"
    log_success "Whisper model downloaded."
fi
cd "$PROJECT_ROOT"

# ----------------------------------------------------------------
# 7. WhisperX Speaker Diarization (Optional)
# ----------------------------------------------------------------
log_step "Speaker Diarization Setup (WhisperX)"

CURRENT_HF_TOKEN=$(jq -r '.Whisper.HuggingFaceToken // ""' "$APPSETTINGS" 2>/dev/null || echo "")

echo ""
echo -e "  WhisperX enables speaker diarization -- identifying who is"
echo -e "  speaking in each part of a radio transmission."
echo ""
echo -e "  ${BOLD}Requirements:${NC}"
echo -e "    - Python 3.9+ with pip"
echo -e "    - A HuggingFace account and access token"
echo -e "    - Accept the pyannote model license at:"
echo -e "      ${BLUE}https://huggingface.co/pyannote/speaker-diarization-3.1${NC}"
echo -e "      ${BLUE}https://huggingface.co/pyannote/segmentation-3.0${NC}"
echo ""

if [ -n "$CURRENT_HF_TOKEN" ]; then
    echo -e "  Current token: ${BOLD}${CURRENT_HF_TOKEN:0:8}...${NC}"
    echo ""
fi

read -r -p "$(echo -e "${BLUE}[INFO]${NC} Enter your HuggingFace token (press Enter to ${BOLD}skip${NC} diarization): ")" HF_TOKEN_INPUT
HF_TOKEN="${HF_TOKEN_INPUT:-$CURRENT_HF_TOKEN}"

WHISPERX_VENV="$PROJECT_ROOT/.venv"
if [ -n "$HF_TOKEN" ]; then
    log_info "Setting up WhisperX..."

    # Ensure Python 3.9+ and pip
    if ! command -v python3 &> /dev/null; then
        log_info "Installing Python 3..."
        sudo apt-get install -y -qq python3 python3-pip python3-venv > /dev/null
    fi

    PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
    log_info "Found Python $PYTHON_VER"

    if [ ! -d "$WHISPERX_VENV" ]; then
        log_info "Creating Python virtual environment..."
        python3 -m venv "$WHISPERX_VENV"
    fi

    log_info "Installing WhisperX (this may take several minutes)..."
    "$WHISPERX_VENV/bin/pip" install --quiet --upgrade pip
    "$WHISPERX_VENV/bin/pip" install --quiet whisperx

    if "$WHISPERX_VENV/bin/python" -c "import whisperx; print('ok')" 2>/dev/null | grep -q "ok"; then
        log_success "WhisperX installed successfully."
    else
        log_warn "WhisperX installation may have issues. Diarization might not work."
    fi
else
    log_info "Skipping WhisperX setup (no HuggingFace token provided)."
fi

# ----------------------------------------------------------------
# 8. Update appsettings.json with selected model and paths
# ----------------------------------------------------------------
log_step "Updating Configuration..."

WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
WHISPER_MODEL_PATH="$WHISPER_DIR/models/ggml-$WHISPER_MODEL.bin"
PYTHON_BIN="${WHISPERX_VENV}/bin/python"
WHISPERX_SCRIPT="$PROJECT_ROOT/scripts/whisperx_transcribe.py"

UPDATED=$(jq \
    --arg bin "$WHISPER_BIN" \
    --arg modelPath "$WHISPER_MODEL_PATH" \
    --arg modelName "$WHISPER_MODEL" \
    --arg hfToken "$HF_TOKEN" \
    --arg pythonBin "$PYTHON_BIN" \
    --arg wxScript "$WHISPERX_SCRIPT" \
    '.Whisper.BinaryPath = $bin | .Whisper.ModelPath = $modelPath | .Whisper.ModelName = $modelName | .Whisper.HuggingFaceToken = $hfToken | .Whisper.PythonBinary = $pythonBin | .Whisper.WhisperXScript = $wxScript' \
    "$APPSETTINGS")
echo "$UPDATED" > "$APPSETTINGS"

log_success "Configuration updated:"
log_info "  Binary:      $WHISPER_BIN"
log_info "  Model:       $WHISPER_MODEL_PATH"
if [ -n "$HF_TOKEN" ]; then
    log_info "  Diarization: Enabled (WhisperX)"
else
    log_info "  Diarization: Disabled (no HuggingFace token)"
fi

if [ "$DEPS_ONLY" = true ]; then
    log_success "Dependencies installed. Skipping build and service installation (--deps-only)."
    exit 0
fi

# ----------------------------------------------------------------
# 9. Build Application
# ----------------------------------------------------------------
log_step "Building Application..."

cd "$PROJECT_ROOT"
if dotnet build -c Release -o bin/Release/net10.0/publish; then
    log_success "Server built successfully."
else
    log_error "Server build failed."
    exit 1
fi

# ----------------------------------------------------------------
# 10. Configure Systemd Service
# ----------------------------------------------------------------
log_step "Configuring Systemd Service..."

SERVICE_FILE="/etc/systemd/system/openscanner-whisper.service"
NET_EXEC="$PROJECT_ROOT/bin/Release/net10.0/publish/OpenScanner.WhisperServer"

chmod +x "$NET_EXEC"

TEMP_SERVICE_FILE=$(mktemp)
cat <<EOF > "$TEMP_SERVICE_FILE"
[Unit]
Description=OpenScanner Whisper Transcription Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_ROOT
ExecStart=$NET_EXEC --urls "http://0.0.0.0:$PORT"
Restart=always
RestartSec=5
Environment=DOTNET_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://0.0.0.0:$PORT

[Install]
WantedBy=multi-user.target
EOF

sudo mv "$TEMP_SERVICE_FILE" "$SERVICE_FILE"
sudo chown root:root "$SERVICE_FILE"
sudo chmod 644 "$SERVICE_FILE"

sudo systemctl daemon-reload
sudo systemctl enable openscanner-whisper
sudo systemctl restart openscanner-whisper

# ----------------------------------------------------------------
# 11. Finalize
# ----------------------------------------------------------------
log_step "Finalizing..."
chmod +x "$PROJECT_ROOT"/scripts/*.sh

IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo "================================================="
log_success "Installation Complete!"
echo "================================================="
echo -e "   ${BOLD}Model:${NC}   $WHISPER_MODEL"
echo -e "   ${BOLD}Port:${NC}    $PORT"
echo -e "   ${BOLD}Status:${NC}  systemctl status openscanner-whisper"
echo -e "   ${BOLD}Logs:${NC}    journalctl -u openscanner-whisper -f"
echo -e "   ${BOLD}Health:${NC}  http://$IP_ADDR:$PORT/health"
echo ""
echo -e "   To connect from OpenScanner, set the remote URL to:"
echo -e "   ${BOLD}http://$IP_ADDR:$PORT${NC}"
echo "================================================="
