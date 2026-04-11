# OpenScanner.WhisperServer

A lightweight .NET Web API server that provides remote Whisper AI transcription for [OpenScanner](https://github.com/briannippert/OpenScanner). Run this on a more powerful machine to offload speech-to-text processing from your Raspberry Pi.

## Prerequisites

- A Linux machine (Ubuntu/Debian recommended) with a GPU or fast CPU
- The installer handles everything else (.NET SDK, whisper.cpp, model download)

## Quick Start

```bash
git clone https://github.com/briannippert/OpenScanner.WhisperServer.git
cd OpenScanner.WhisperServer

chmod +x scripts/*.sh
./scripts/install_service.sh
```

The installer will:
1. Install system dependencies (.NET 10 SDK, cmake, ffmpeg)
2. Prompt you to select a Whisper model
3. Prompt you to choose a port (default: 8090)
4. Clone and build whisper.cpp (with CUDA if an NVIDIA GPU is detected)
5. Download your chosen model
6. Build the .NET server
7. Configure and start a systemd service

### Installer Options

- `--deps-only`: Install dependencies and download the model, then exit without building or installing the service
- `--port=NNNN`: Set the listening port (skips the interactive prompt)
- `--rebuild-whisper`: Force a clean rebuild of whisper.cpp (useful after installing CUDA)

```bash
# Install deps only
./scripts/install_service.sh --deps-only

# Use a custom port
./scripts/install_service.sh --port=9000

# Rebuild whisper.cpp with GPU support after installing CUDA toolkit
sudo apt-get install nvidia-cuda-toolkit
./scripts/install_service.sh --rebuild-whisper
```

### GPU Acceleration

The installer automatically detects NVIDIA GPUs and enables CUDA acceleration when the CUDA toolkit is installed. If you install the CUDA toolkit after the initial setup, re-run the installer with `--rebuild-whisper` to recompile whisper.cpp with GPU support.

### Uninstall

```bash
./scripts/uninstall_service.sh
```

## Manual Setup

If you prefer to set things up manually:

### Prerequisites (Manual)

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) built with `whisper-cli`
- A Whisper model file (e.g., `ggml-small.en.bin`)

### Building whisper.cpp

```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp

# CPU-only build
cmake -B build
cmake --build build --config Release

# Or with CUDA for GPU acceleration (requires nvidia-cuda-toolkit)
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release

# Download a model
bash models/download-ggml-model.sh small.en
```

## Configuration

Edit `appsettings.json` to point to your whisper.cpp installation (the installer does this automatically):

```json
{
  "Whisper": {
    "BinaryPath": "/path/to/whisper.cpp/build/bin/whisper-cli",
    "ModelPath": "/path/to/whisper.cpp/models/ggml-small.en.bin",
    "ModelName": "small.en",
    "TimeoutSeconds": 120
  }
}
```

Or use environment variables:

```bash
export Whisper__BinaryPath=/path/to/whisper-cli
export Whisper__ModelPath=/path/to/ggml-small.en.bin
```

## Running

If installed via the installer, the server runs as a systemd service:

```bash
systemctl status openscanner-whisper    # Check status
journalctl -u openscanner-whisper -f    # View logs
```

To run manually instead:

```bash
dotnet run
```

By default, the server listens on `http://localhost:5000`. To change the port:

```bash
dotnet run --urls "http://0.0.0.0:8090"
```

## API Endpoints

### GET /health

Returns the server status and model information.

```bash
curl http://localhost:8090/health
```

Response:
```json
{
  "status": "ok",
  "model": "small.en",
  "binaryFound": true,
  "modelFound": true
}
```

### POST /transcribe

Transcribe an audio file. Send the file as multipart form data.

```bash
curl -X POST http://localhost:8090/transcribe \
  -F "file=@recording.wav" \
  -F "prompt=Dispatch, Unit 1, 10-4, copy, over."
```

Response:
```json
{
  "text": "Unit 1, responding code 3 to Main and First."
}
```

Parameters:
- `file` (required): WAV audio file
- `prompt` (optional): Context prompt to guide transcription accuracy. If omitted, the default radio-context prompt from config is used.

## Updating

Re-run the installer to pull the latest code, rebuild, and restart:

```bash
./scripts/install_service.sh
```

## Connecting to OpenScanner

1. Start this server on your network (e.g., `dotnet run --urls "http://0.0.0.0:8090"`)
2. In the OpenScanner UI, go to **Settings**
3. Enable **AI Transcription**
4. Set **Transcription Mode** to **Remote Server**
5. Enter the server URL (e.g., `http://192.168.1.100:8090`)
6. Click **Test** to verify connectivity

## License

MIT
