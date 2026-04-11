using OpenScanner.WhisperServer.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<WhisperService>();

var app = builder.Build();

app.MapGet("/health", (WhisperService whisper) =>
{
    var ready = whisper.IsReady();
    return Results.Ok(new
    {
        status = ready ? "ok" : "error",
        model = whisper.ModelName,
        binaryFound = File.Exists(whisper.WhisperBinary),
        modelFound = File.Exists(whisper.ModelPath)
    });
});

app.MapPost("/transcribe", async (HttpRequest request, WhisperService whisper, ILogger<Program> logger) =>
{
    if (!whisper.IsReady())
    {
        return Results.Json(new { error = "Whisper is not configured. Check binary and model paths." },
            statusCode: 503);
    }

    if (!request.HasFormContentType)
    {
        return Results.Json(new { error = "Request must be multipart/form-data." }, statusCode: 400);
    }

    var form = await request.ReadFormAsync();
    var file = form.Files.GetFile("file");
    if (file == null || file.Length == 0)
    {
        return Results.Json(new { error = "No audio file provided. Send as 'file' in multipart form data." },
            statusCode: 400);
    }

    var prompt = form.TryGetValue("prompt", out var promptValues) ? promptValues.ToString() : null;

    // Save uploaded file to temp location
    var tempDir = Path.Combine(Path.GetTempPath(), "whisper-server");
    Directory.CreateDirectory(tempDir);
    var ext = Path.GetExtension(file.FileName);
    if (string.IsNullOrEmpty(ext)) ext = ".wav";
    var tempPath = Path.Combine(tempDir, $"{Guid.NewGuid()}{ext}");

    try
    {
        await using (var stream = new FileStream(tempPath, FileMode.Create))
        {
            await file.CopyToAsync(stream);
        }

        logger.LogInformation("Transcribing {FileName} ({Size} bytes)", file.FileName, file.Length);

        var text = await whisper.TranscribeAsync(tempPath, prompt);

        return Results.Ok(new { text = text ?? "" });
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Transcription failed for {FileName}", file.FileName);
        return Results.Json(new { error = "Transcription failed: " + ex.Message }, statusCode: 500);
    }
    finally
    {
        if (File.Exists(tempPath)) File.Delete(tempPath);
    }
});

app.Run();
