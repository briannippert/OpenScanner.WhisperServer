# OpenScanner.WhisperServer

A lightweight .NET Web API server that provides remote Whisper AI transcription for [OpenScanner](https://github.com/briannippert/OpenScanner). Run this on a more powerful machine to offload speech-to-text processing from your Raspberry Pi.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) built with `whisper-cli`
- A Whisper model file (e.g., `ggml-small.en.bin`)

### Building whisper.cpp

```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
cmake -B build
cmake --build build --config Release

# Download a model
bash models/download-ggml-model.sh small.en
```

## Configuration

Edit `appsettings.json` to point to your whisper.cpp installation:

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

## Connecting to OpenScanner

1. Start this server on your network (e.g., `dotnet run --urls "http://0.0.0.0:8090"`)
2. In the OpenScanner UI, go to **Settings**
3. Enable **AI Transcription**
4. Set **Transcription Mode** to **Remote Server**
5. Enter the server URL (e.g., `http://192.168.1.100:8090`)
6. Click **Test** to verify connectivity

## License

MIT
