# OpenScanner.WhisperServer

A lightweight .NET Web API server that provides remote Whisper AI transcription for [OpenScanner](https://github.com/briannippert/OpenScanner). Run this on a more powerful machine to offload speech-to-text processing from your Raspberry Pi.

Unlike a per-clip `whisper-cli` invocation, this server keeps models **resident in memory** by managing a pool of long-lived [`whisper-server`](https://github.com/ggerganov/whisper.cpp/tree/master/examples/server) processes. The first request for a model loads it; subsequent requests reuse the warm process, and multiple clips can be transcribed **concurrently**.

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
2. Prompt you to select a default Whisper model (pre-warmed at startup)
3. Prompt you to choose a port (default: 8090)
4. Clone and build whisper.cpp — including `whisper-server` — (with CUDA if an NVIDIA GPU is detected)
5. Download your chosen model
6. Build the .NET server
7. Configure and start a systemd service

### Installer Options

- `--deps-only`: Install dependencies and download the model, then exit without building or installing the service
- `--port=NNNN`: Set the listening port (skips the interactive prompt)
- `--rebuild-whisper`: Force a clean rebuild of whisper.cpp (useful after installing CUDA)

### GPU Acceleration

The installer automatically detects NVIDIA GPUs and enables CUDA acceleration when the CUDA toolkit is installed. If you install the CUDA toolkit after the initial setup, re-run the installer with `--rebuild-whisper` to recompile whisper.cpp with GPU support.

### Uninstall

```bash
./scripts/uninstall_service.sh
```

## Manual Setup

### Building whisper.cpp

The resident `whisper-server` binary is built by default as part of the examples:

```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp

cmake -B build                  # CPU-only
# cmake -B build -DGGML_CUDA=ON # or with CUDA
cmake --build build --config Release   # produces build/bin/whisper-server

bash models/download-ggml-model.sh large-v3-turbo-q5_0
```

## Configuration

Edit `appsettings.json` (the installer does this automatically):

```json
{
  "Whisper": {
    "ModelsDir": "/path/to/whisper.cpp/models",
    "WhisperServerBinary": "/path/to/whisper.cpp/build/bin/whisper-server",
    "DefaultModel": "large-v3-turbo-q5_0",
    "BasePort": 8100,
    "InstancesPerModel": 2,
    "MaxResidentModels": 2,
    "Threads": 0,
    "UseGpu": true,
    "StartupTimeoutSeconds": 120,
    "TimeoutSeconds": 120,
    "DefaultPrompt": "..."
  }
}
```

| Key | Default | Purpose |
|---|---|---|
| `ModelsDir` | — | Directory of `ggml-*.bin` models (also drives `/models`) |
| `WhisperServerBinary` | — | Path to the built `whisper-server` binary |
| `DefaultModel` | `large-v3-turbo-q5_0` | Model pre-warmed at startup and used when a request omits `model` |
| `BasePort` | `8100` | First loopback port for spawned `whisper-server` processes |
| `InstancesPerModel` | `2` | Processes per model → concurrency for a single model |
| `MaxResidentModels` | `2` | Distinct models kept in memory (LRU eviction beyond this) |
| `Threads` | `0` | Threads per process (`0` = all cores) |
| `UseGpu` | `true` | Pass `-ng` to disable GPU when `false` |
| `StartupTimeoutSeconds` | `120` | How long to wait for a model to load |
| `TimeoutSeconds` | `120` | Per-inference request timeout |
| `DefaultPrompt` | radio prompt | Decoding bias when a request omits `prompt` |

Ports `BasePort` … `BasePort + InstancesPerModel × MaxResidentModels` are used internally and only bound to `127.0.0.1`. Only the .NET server's own port is exposed on the network.

## Running

If installed via the installer, the server runs as a systemd service:

```bash
systemctl status openscanner-whisper    # Check status
journalctl -u openscanner-whisper -f    # View logs
```

To run manually: `dotnet run --urls "http://0.0.0.0:8090"` (default dev port is 5000).

## API Endpoints

### GET /health

```json
{
  "status": "ok",
  "defaultModel": "large-v3-turbo-q5_0",
  "binaryFound": true,
  "defaultModelFound": true,
  "loadedModels": ["large-v3-turbo-q5_0"],
  "acceleration": "GPU (CUDA)",
  "cpu": "Intel Core i7-12700K",
  "gpu": "NVIDIA GeForce RTX 3080",
  "gpuMemoryMb": 10240
}
```

### GET /models

Lists the models installed in `ModelsDir`. OpenScanner queries this to populate its remote-model dropdown.

```json
{ "models": [ { "id": "large-v3-turbo-q5_0", "label": "large-v3-turbo-q5_0" }, { "id": "small.en", "label": "small.en" } ] }
```

### POST /transcribe

Transcribe an audio file (multipart form data). OpenScanner sends a pre-filtered 16 kHz mono WAV.

```bash
curl -X POST http://localhost:8090/transcribe \
  -F "file=@recording.wav" \
  -F "model=small.en" \
  -F "prompt=Dispatch, Unit 1, 10-4, copy, over."
```

Parameters:
- `file` (required): WAV audio file
- `model` (optional): model id from `/models`; defaults to `DefaultModel`
- `prompt` (optional): context prompt to guide accuracy; defaults to `DefaultPrompt`

Response:
```json
{ "text": "Unit 1, responding code 3 to Main and First." }
```

## Connecting to OpenScanner

1. Start this server on your network (`dotnet run --urls "http://0.0.0.0:8090"` or via the systemd service).
2. In the OpenScanner UI, go to **Settings → Transcription** and enable **AI Transcription**.
3. Set the **Backend** to **Remote**.
4. Enter the server URL (e.g. `http://192.168.1.100:8090`) and click **Test**.
5. Pick a **Model** from the list queried live from this server.

## Updating

Re-run the installer to pull the latest code, rebuild, and restart:

```bash
./scripts/install_service.sh
```

## License

MIT
