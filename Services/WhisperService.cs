using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace OpenScanner.WhisperServer.Services;

public class WhisperService
{
    private readonly ILogger<WhisperService> _logger;
    private readonly IConfiguration _config;
    private readonly SemaphoreSlim _semaphore = new(1, 1);
    private readonly Lazy<HardwareInfo> _hardwareInfo;
    private readonly Lazy<bool> _whisperXAvailable;

    public WhisperService(ILogger<WhisperService> logger, IConfiguration config)
    {
        _logger = logger;
        _config = config;
        _hardwareInfo = new Lazy<HardwareInfo>(DetectHardware);
        _whisperXAvailable = new Lazy<bool>(CheckWhisperXAvailable);
    }

    public string WhisperBinary => _config["Whisper:BinaryPath"] ?? "/usr/local/bin/whisper-cli";
    public string ModelPath => _config["Whisper:ModelPath"] ?? "/usr/local/share/whisper/models/ggml-small.en.bin";
    public string ModelName => _config["Whisper:ModelName"] ?? "small.en";
    public int TimeoutMs => (_config.GetValue<int?>("Whisper:TimeoutSeconds") ?? 120) * 1000;
    public int DiarizationTimeoutMs => (_config.GetValue<int?>("Whisper:DiarizationTimeoutSeconds") ?? 300) * 1000;
    public string DefaultPrompt => _config["Whisper:DefaultPrompt"] ?? "";
    public string? HuggingFaceToken => _config["Whisper:HuggingFaceToken"];
    public string WhisperXScript => _config["Whisper:WhisperXScript"]
        ?? Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "scripts", "whisperx_transcribe.py");
    public string PythonBinary => _config["Whisper:PythonBinary"] ?? "python3";

    public HardwareInfo Hardware => _hardwareInfo.Value;
    public bool IsDiarizationAvailable => _whisperXAvailable.Value && !string.IsNullOrEmpty(HuggingFaceToken);

    public bool IsReady()
    {
        return File.Exists(WhisperBinary) && File.Exists(ModelPath);
    }

    /// <summary>
    /// Transcribe a WAV audio file using whisper-cli.
    /// Serialized with a semaphore to avoid overloading the system.
    /// </summary>
    public async Task<string?> TranscribeAsync(string wavPath, string? prompt)
    {
        await _semaphore.WaitAsync();
        try
        {
            return await RunWhisperAsync(wavPath, prompt ?? DefaultPrompt);
        }
        finally
        {
            _semaphore.Release();
        }
    }

    /// <summary>
    /// Transcribe with speaker diarization using WhisperX.
    /// Returns a DiarizationResult with formatted text and speaker segments.
    /// </summary>
    public async Task<DiarizationResult?> TranscribeWithDiarizationAsync(string wavPath, string? prompt)
    {
        await _semaphore.WaitAsync();
        try
        {
            return await RunWhisperXAsync(wavPath, prompt ?? DefaultPrompt);
        }
        finally
        {
            _semaphore.Release();
        }
    }

    private async Task<string?> RunWhisperAsync(string wavPath, string prompt)
    {
        var whisperArgs = $"-m \"{ModelPath}\" -f \"{wavPath}\" -nt -otxt -l en --prompt \"{prompt}\"";
        var whisperDir = Path.GetDirectoryName(Path.GetDirectoryName(WhisperBinary));

        var startInfo = new ProcessStartInfo(WhisperBinary, whisperArgs)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = whisperDir ?? Directory.GetCurrentDirectory()
        };

        try
        {
            using var proc = Process.Start(startInfo);
            if (proc == null)
            {
                _logger.LogError("Failed to start whisper-cli process");
                return null;
            }

            var stdoutTask = proc.StandardOutput.ReadToEndAsync();
            var stderrTask = proc.StandardError.ReadToEndAsync();

            var exited = await Task.Run(() => proc.WaitForExit(TimeoutMs));
            if (!exited)
            {
                _logger.LogError("whisper-cli timed out after {Timeout}s", TimeoutMs / 1000);
                proc.Kill(entireProcessTree: true);
                return null;
            }

            var stderr = await stderrTask;
            var stdout = await stdoutTask;

            if (proc.ExitCode != 0)
            {
                _logger.LogError("whisper-cli failed (exit {Code}).\nStderr: {Stderr}\nStdout: {Stdout}",
                    proc.ExitCode, stderr, stdout);
                return null;
            }

            // whisper-cli with -otxt writes output to {input}.txt
            var txtPath = wavPath + ".txt";
            if (!File.Exists(txtPath))
            {
                _logger.LogError("whisper-cli produced no output file.\nStderr: {Stderr}\nStdout: {Stdout}",
                    stderr, stdout);
                return null;
            }

            var text = (await File.ReadAllTextAsync(txtPath)).Trim();
            File.Delete(txtPath);

            if (string.IsNullOrEmpty(text)) return null;
            if (text.StartsWith('[') && text.EndsWith(']')) return null;

            return text;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error running whisper-cli");
            return null;
        }
    }

    private async Task<DiarizationResult?> RunWhisperXAsync(string wavPath, string prompt)
    {
        var scriptPath = Path.GetFullPath(WhisperXScript);
        if (!File.Exists(scriptPath))
        {
            _logger.LogError("WhisperX script not found at {Path}", scriptPath);
            return null;
        }

        var args = $"\"{scriptPath}\" \"{wavPath}\" --model \"{ModelName}\" --hf-token \"{HuggingFaceToken}\" --language en";
        if (!string.IsNullOrEmpty(prompt))
            args += $" --prompt \"{prompt}\"";

        var startInfo = new ProcessStartInfo(PythonBinary, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(scriptPath) ?? Directory.GetCurrentDirectory()
        };

        try
        {
            using var proc = Process.Start(startInfo);
            if (proc == null)
            {
                _logger.LogError("Failed to start WhisperX process");
                return null;
            }

            var stdoutTask = proc.StandardOutput.ReadToEndAsync();
            var stderrTask = proc.StandardError.ReadToEndAsync();

            var exited = await Task.Run(() => proc.WaitForExit(DiarizationTimeoutMs));
            if (!exited)
            {
                _logger.LogError("WhisperX timed out after {Timeout}s", DiarizationTimeoutMs / 1000);
                proc.Kill(entireProcessTree: true);
                return null;
            }

            var stdout = await stdoutTask;
            var stderr = await stderrTask;

            if (proc.ExitCode != 0)
            {
                _logger.LogError("WhisperX failed (exit {Code}).\nStderr: {Stderr}\nStdout: {Stdout}",
                    proc.ExitCode, stderr, stdout);
                return null;
            }

            if (string.IsNullOrWhiteSpace(stdout))
            {
                _logger.LogError("WhisperX produced no output.\nStderr: {Stderr}", stderr);
                return null;
            }

            var json = JsonSerializer.Deserialize<JsonElement>(stdout);

            if (json.TryGetProperty("error", out var errorProp))
            {
                _logger.LogError("WhisperX error: {Error}", errorProp.GetString());
                return null;
            }

            var text = json.TryGetProperty("text", out var textProp) ? textProp.GetString() : null;
            if (string.IsNullOrWhiteSpace(text)) return null;

            var segments = new List<DiarizationSegment>();
            if (json.TryGetProperty("segments", out var segArray))
            {
                foreach (var seg in segArray.EnumerateArray())
                {
                    segments.Add(new DiarizationSegment
                    {
                        Speaker = seg.TryGetProperty("speaker", out var sp) ? sp.GetString() ?? "Unknown" : "Unknown",
                        Text = seg.TryGetProperty("text", out var tx) ? tx.GetString() ?? "" : "",
                        Start = seg.TryGetProperty("start", out var st) ? st.GetDouble() : 0,
                        End = seg.TryGetProperty("end", out var en) ? en.GetDouble() : 0,
                    });
                }
            }

            return new DiarizationResult { Text = text, Segments = segments };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error running WhisperX");
            return null;
        }
    }

    private bool CheckWhisperXAvailable()
    {
        try
        {
            var psi = new ProcessStartInfo(PythonBinary, "-c \"import whisperx; print('ok')\"")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc != null)
            {
                var output = proc.StandardOutput.ReadToEnd().Trim();
                proc.WaitForExit(10000);
                return proc.ExitCode == 0 && output == "ok";
            }
        }
        catch { }
        return false;
    }

    private HardwareInfo DetectHardware()
    {
        var info = new HardwareInfo
        {
            Cpu = GetCpuName(),
        };

        try
        {
            var psi = new ProcessStartInfo("nvidia-smi", "--query-gpu=name,memory.total --format=csv,noheader,nounits")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc != null)
            {
                var output = proc.StandardOutput.ReadToEnd().Trim();
                proc.WaitForExit(3000);
                if (proc.ExitCode == 0 && !string.IsNullOrEmpty(output))
                {
                    var parts = output.Split(',', 2);
                    info.Gpu = parts[0].Trim();
                    if (parts.Length > 1 && int.TryParse(parts[1].Trim(), out var mb))
                        info.GpuMemoryMb = mb;
                    info.CudaAvailable = true;
                }
            }
        }
        catch
        {
            // nvidia-smi not available
        }

        info.WhisperCudaEnabled = CheckWhisperCudaLinked();

        return info;
    }

    private bool CheckWhisperCudaLinked()
    {
        try
        {
            if (!File.Exists(WhisperBinary) || !RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
                return false;

            var psi = new ProcessStartInfo("ldd", WhisperBinary)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc == null) return false;

            var output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(3000);
            return proc.ExitCode == 0 && output.Contains("libcuda", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static string GetCpuName()
    {
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                var lines = File.ReadAllLines("/proc/cpuinfo");
                var modelLine = lines.FirstOrDefault(l => l.StartsWith("model name", StringComparison.OrdinalIgnoreCase));
                if (modelLine != null)
                {
                    var value = modelLine.Split(':', 2);
                    if (value.Length == 2) return value[1].Trim();
                }
            }
        }
        catch { }
        return RuntimeInformation.ProcessArchitecture.ToString();
    }
}

public class HardwareInfo
{
    public string Cpu { get; set; } = "Unknown";
    public string? Gpu { get; set; }
    public int? GpuMemoryMb { get; set; }
    public bool CudaAvailable { get; set; }
    public bool WhisperCudaEnabled { get; set; }
    public string AccelerationMode => WhisperCudaEnabled ? "GPU (CUDA)" : CudaAvailable ? "GPU available but not enabled" : "CPU";
}

public class DiarizationResult
{
    public string Text { get; set; } = "";
    public List<DiarizationSegment> Segments { get; set; } = new();
}

public class DiarizationSegment
{
    public string Speaker { get; set; } = "Unknown";
    public string Text { get; set; } = "";
    public double Start { get; set; }
    public double End { get; set; }
}
