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
    "TimeoutSeconds": 120,
    "DiarizationTimeoutSeconds": 300,
    "HuggingFaceToken": ""
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

Returns the server status, model information, and hardware details.

```bash
curl http://localhost:8090/health
```

Response:
```json
{
  "status": "ok",
  "model": "small.en",
  "binaryFound": true,
  "modelFound": true,
  "acceleration": "GPU (CUDA)",
  "cpu": "Intel Core i7-12700K",
  "gpu": "NVIDIA GeForce RTX 3080",
  "gpuMemoryMb": 10240,
  "diarizationAvailable": true
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

#### With Speaker Diarization

When WhisperX is configured, add `diarize=true` to identify speakers:

```bash
curl -X POST http://localhost:8090/transcribe \
  -F "file=@recording.wav" \
  -F "prompt=Dispatch, Unit 1, 10-4, copy, over." \
  -F "diarize=true"
```

Response:
```json
{
  "text": "[Speaker 1]: Unit 1, respond code 3 to Main and First.\n[Speaker 2]: Copy, Unit 1 en route.",
  "segments": [
    { "speaker": "Speaker 1", "text": "Unit 1, respond code 3 to Main and First.", "start": 0.0, "end": 3.2 },
    { "speaker": "Speaker 2", "text": "Copy, Unit 1 en route.", "start": 3.5, "end": 5.1 }
  ]
}
```

Parameters:
- `file` (required): WAV audio file
- `prompt` (optional): Context prompt to guide transcription accuracy
- `diarize` (optional): Set to `true` to enable speaker diarization (requires WhisperX)

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
7. (Optional) Enable **Speaker Diarization** if WhisperX is configured

## Speaker Diarization (WhisperX)

WhisperX adds speaker diarization -- identifying who is speaking in each part of a radio transmission.

### Setup

The installer will prompt you to set up WhisperX. You'll need:

1. A [HuggingFace](https://huggingface.co) account
2. A HuggingFace access token (create one at https://huggingface.co/settings/tokens)
3. Accept the license for these models:
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0

When the installer asks for your HuggingFace token, paste it in. This enables WhisperX in a Python virtual environment alongside the standard whisper.cpp installation.

### Manual Setup

If you want to set up WhisperX after the initial install:

```bash
python3 -m venv .venv
.venv/bin/pip install whisperx
```

Then add these to `appsettings.json` under the `Whisper` section:

```json
{
  "Whisper": {
    "HuggingFaceToken": "hf_your_token_here",
    "DiarizationTimeoutSeconds": 300
  }
}
```

### How It Works

When diarization is enabled in OpenScanner and the server has WhisperX available:
- Transcription uses WhisperX instead of whisper-cli
- WhisperX performs transcription, alignment, and speaker diarization
- Results include speaker labels like `[Speaker 1]:` before each segment
- The standard whisper-cli is used as fallback when diarization is not requested

## License

MIT
