using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace ADBTypeLink.Core;

/// <summary>一台通过 USB / 无线调试连接的 Android 设备。</summary>
public sealed class AdbDevice
{
    public required string Serial { get; init; }

    public string Model { get; init; } = string.Empty;

    public string State { get; init; } = string.Empty;

    public string DisplayName =>
        string.IsNullOrEmpty(Model) ? Serial : $"{Model}  ·  {Serial}";
}

/// <summary>一次 adb 调用的结果。</summary>
public sealed record AdbResult(int ExitCode, string Text, bool Launched)
{
    public bool Ok => Launched && ExitCode == 0;
}

/// <summary>
/// adb 集成：定位 adb、列出设备、把文字打进手机输入框 / 剪贴板、推送文件。
/// 对应 macOS 端的 <c>ADB.swift</c>，行为保持一致。
/// </summary>
public sealed class AdbService
{
    /// <summary>推送到手机的手机端剪贴板组件路径。</summary>
    public const string ClipJarRemotePath = "/data/local/tmp/adbtype-clip.jar";

    private static readonly byte[] PngHeader = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    private readonly HashSet<string> _clipPushed = new(StringComparer.Ordinal);
    private readonly object _clipGate = new();

    public AdbService(string? adbPath = null)
    {
        AdbPath = string.IsNullOrWhiteSpace(adbPath) ? Locate() ?? string.Empty : adbPath;
    }

    /// <summary>可用的 adb 可执行文件路径；为空表示没找到。</summary>
    public string AdbPath { get; private set; }

    public bool IsAvailable => !string.IsNullOrEmpty(AdbPath) && File.Exists(AdbPath);

    /// <summary>重新指定 adb 路径（用户在界面上手动选择）。</summary>
    public void SetAdbPath(string path)
    {
        AdbPath = path ?? string.Empty;
        lock (_clipGate)
        {
            _clipPushed.Clear();
        }
    }

    // MARK: - 定位 adb

    /// <summary>按 ANDROID_HOME / 常见安装目录 / PATH 顺序找 adb。</summary>
    public static string? Locate()
    {
        foreach (var candidate in CandidatePaths())
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (Exception)
            {
                // 非法路径直接跳过。
            }
        }

        return null;
    }

    private static IEnumerable<string> CandidatePaths()
    {
        var exe = OperatingSystem.IsWindows() ? "adb.exe" : "adb";

        foreach (var variable in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_SDK" })
        {
            var root = Environment.GetEnvironmentVariable(variable);
            if (!string.IsNullOrWhiteSpace(root))
            {
                yield return Path.Combine(root, "platform-tools", exe);
            }
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrEmpty(home))
        {
            yield return Path.Combine(home, "AppData", "Local", "Android", "Sdk", "platform-tools", exe);
            yield return Path.Combine(home, "Android", "Sdk", "platform-tools", exe);
            yield return Path.Combine(home, "Library", "Android", "sdk", "platform-tools", exe);
        }

        // PATH 里通常就带着 platform-tools（Android Studio 装完会自动加）。
        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = directory.Trim().Trim('"');
            if (trimmed.Length == 0)
            {
                continue;
            }

            yield return Path.Combine(trimmed, exe);
        }
    }

    /// <summary>
    /// 重启 adb 服务端。5037 被模拟器 / 手机助手抢占时，这是唯一可靠的修复手段。
    /// 注意：会断开其它工具（Nox、QtScrcpy 等）当前的 adb 连接。
    /// </summary>
    public async Task<AdbResult> RestartServerAsync(CancellationToken cancellationToken = default)
    {
        await RunAsync(new[] { "kill-server" }, TimeSpan.FromSeconds(10), null, cancellationToken)
            .ConfigureAwait(false);
        return await RunAsync(new[] { "start-server" }, TimeSpan.FromSeconds(20), null, cancellationToken)
            .ConfigureAwait(false);
    }

    // MARK: - 设备列表

    public async Task<(List<AdbDevice> Devices, string? Error)> ListDevicesAsync(CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return (new List<AdbDevice>(), "未找到 adb（platform-tools）");
        }

        var result = await RunAsync(new[] { "devices", "-l" }, TimeSpan.FromSeconds(12), null, cancellationToken)
            .ConfigureAwait(false);
        if (!result.Ok)
        {
            return (new List<AdbDevice>(), Friendly(result.Text, "adb 无法连接"));
        }

        var devices = new List<AdbDevice>();
        var issues = new List<string>();

        foreach (var rawLine in result.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("List of devices", StringComparison.Ordinal) || line.StartsWith("*", StringComparison.Ordinal))
            {
                continue;
            }

            var fields = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2)
            {
                continue;
            }

            var serial = fields[0];
            var state = fields[1];
            var model = string.Empty;
            foreach (var field in fields.Skip(2))
            {
                if (field.StartsWith("model:", StringComparison.Ordinal))
                {
                    model = field["model:".Length..].Replace('_', ' ');
                }
            }

            switch (state)
            {
                case "device":
                    devices.Add(new AdbDevice { Serial = serial, Model = model, State = state });
                    break;
                case "unauthorized":
                    issues.Add($"{serial} 未授权：请在手机上点击「允许 USB 调试」");
                    break;
                case "offline":
                    issues.Add($"{serial} 离线：请重新插拔数据线");
                    break;
                default:
                    issues.Add($"{serial} 状态：{state}");
                    break;
            }
        }

        return (devices, issues.Count == 0 ? null : string.Join("；", issues));
    }

    // MARK: - 文字输入

    /// <summary>含中文 / emoji 时必须走剪贴板：input text 只可靠支持 ASCII。</summary>
    public static bool NeedsClipboard(string? text) =>
        !string.IsNullOrEmpty(text) && text.Any(character => !IsAscii(character));

    private static bool IsAscii(char character) => character <= 0x7F;

    /// <summary>组装 <c>input text '...'</c>，空格用 %s 表示（由远端 sh 解析）。</summary>
    public static string InputTextCommand(string text)
    {
        var value = text.Replace("\r", " ").Replace("\n", " ");
        value = value.Replace(" ", "%s");
        return "input text " + ShellQuote(value);
    }

    /// <summary>单引号包裹，内部单引号转义，避免被远端 shell 解释。</summary>
    public static string ShellQuote(string text) => "'" + text.Replace("'", "'\\''") + "'";

    /// <summary>光标移到末尾后连续删除：一次 adb 调用搞定。</summary>
    public static string ClearCommand(int deletes = 40) =>
        string.Join(' ', new[] { "input", "keyevent", "123" }.Concat(Enumerable.Repeat("67", deletes)));

    /// <summary>老设备不支持一次多个键码时的兜底。</summary>
    public static string ClearCommandSlow(int deletes = 40) =>
        string.Join("; ", Enumerable.Repeat("input keyevent 67", deletes));

    public Task<AdbResult> ShellAsync(string serial, string command, TimeSpan timeout, CancellationToken cancellationToken = default) =>
        RunAsync(new[] { "-s", serial, "shell", command }, timeout, null, cancellationToken);

    public Task<AdbResult> InputTextAsync(string serial, string text, CancellationToken cancellationToken = default) =>
        ShellAsync(serial, InputTextCommand(text), TimeSpan.FromSeconds(12), cancellationToken);

    public Task<AdbResult> PressEnterAsync(string serial, CancellationToken cancellationToken = default) =>
        ShellAsync(serial, "input keyevent 66", TimeSpan.FromSeconds(8), cancellationToken);

    /// <summary>先快速清空，失败再逐键删除。</summary>
    public async Task<AdbResult> ClearInputAsync(string serial, CancellationToken cancellationToken = default)
    {
        var result = await ShellAsync(serial, ClearCommand(), TimeSpan.FromSeconds(12), cancellationToken)
            .ConfigureAwait(false);
        if (result.Ok)
        {
            return result;
        }

        return await ShellAsync(serial, ClearCommandSlow(), TimeSpan.FromSeconds(20), cancellationToken)
            .ConfigureAwait(false);
    }

    // MARK: - 手机剪贴板

    /// <summary>把文字写进手机剪贴板。返回 null 表示成功，否则是错误文案。</summary>
    public async Task<string?> SetClipboardAsync(
        string serial,
        string text,
        string? clipJarPath,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(clipJarPath) || !File.Exists(clipJarPath))
        {
            return "安装包缺少内置组件 adbtype-clip.jar，请重新构建应用";
        }

        var pushed = false;
        lock (_clipGate)
        {
            pushed = _clipPushed.Contains(serial);
        }

        if (!pushed)
        {
            var push = await RunAsync(
                    new[] { "-s", serial, "push", clipJarPath, ClipJarRemotePath },
                    TimeSpan.FromSeconds(15),
                    null,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!push.Ok)
            {
                return Friendly(push.Text, "推送手机端剪贴板组件失败");
            }

            lock (_clipGate)
            {
                _clipPushed.Add(serial);
            }
        }

        var base64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
        var command = $"CLASSPATH={ClipJarRemotePath} app_process /system/bin Clip {base64}";
        var result = await RunAsync(new[] { "-s", serial, "shell", command }, TimeSpan.FromSeconds(15), null, cancellationToken)
            .ConfigureAwait(false);

        if (!result.Ok || !result.Text.Contains("OK setPrimaryClip", StringComparison.Ordinal))
        {
            if (result.Text.Contains("Exception", StringComparison.Ordinal) || result.Text.Contains("denied", StringComparison.Ordinal))
            {
                lock (_clipGate)
                {
                    _clipPushed.Remove(serial);
                }
            }

            return Friendly(result.Text, "写入手机剪贴板失败");
        }

        return null;
    }

    // MARK: - 截屏

    /// <summary>
    /// 截取手机当前屏幕，返回原始 PNG。必须用 `exec-out` 读二进制，
    /// 不能走 RunAsync 的文本管道，否则 PNG 会被文本解码破坏。
    /// </summary>
    public async Task<(byte[]? Data, string? Error)> CaptureScreenshotAsync(
        string serial,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return (null, "未找到 adb（platform-tools）");
        }

        var startInfo = new ProcessStartInfo(AdbPath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in new[] { "-s", serial, "exec-out", "screencap", "-p" })
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout ?? TimeSpan.FromSeconds(30));

        try
        {
            if (!process.Start())
            {
                return (null, $"无法启动 {AdbPath}");
            }
        }
        catch (Exception ex)
        {
            return (null, $"无法运行 {AdbPath}：{ex.Message}");
        }

        var stdoutTask = ReadAllBytesAsync(process.StandardOutput.BaseStream, timeoutSource.Token);
        var stderrTask = process.StandardError.ReadToEndAsync();

        var timedOut = false;
        var cancelled = false;
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            cancelled = cancellationToken.IsCancellationRequested;
            timedOut = !cancelled;
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (Exception)
            {
                // 已经退出。
            }
        }

        byte[]? data = null;
        try
        {
            data = await stdoutTask.ConfigureAwait(false);
        }
        catch (Exception)
        {
            // 超时 / 取消时读取会被中断。
        }

        var stderr = string.Empty;
        try
        {
            stderr = (await stderrTask.ConfigureAwait(false)).Trim();
        }
        catch (Exception)
        {
            // 超时 / 取消时读取会被中断。
        }

        if (cancelled)
        {
            return (null, "已取消");
        }

        if (timedOut)
        {
            return (null, "截屏超时，请确认手机已解锁、USB 调试已允许");
        }

        if (data is null || data.Length == 0)
        {
            return (null, Friendly(stderr, "截屏失败，请确认手机已解锁、USB 调试已允许"));
        }

        // PNG 文件头：89 50 4E 47 0D 0A 1A 0A
        if (data.Length <= 8 || !data.AsSpan(0, 8).SequenceEqual(PngHeader))
        {
            return (null, "截屏失败：返回数据不是有效 PNG" + (stderr.Length == 0 ? string.Empty : $"（{Shorten(stderr, 2)}）"));
        }

        return (data, null);
    }

    private static async Task<byte[]> ReadAllBytesAsync(Stream stream, CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer, 81920, cancellationToken).ConfigureAwait(false);
        return buffer.ToArray();
    }

    // MARK: - 文件推送

    /// <summary>推送单个文件到手机目录，进度 0~100。</summary>
    public async Task<AdbResult> PushAsync(
        string serial,
        string localPath,
        string remoteDirectory,
        IProgress<double>? progress = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var mkdir = await ShellAsync(serial, "mkdir -p " + ShellQuote(remoteDirectory), TimeSpan.FromSeconds(10), cancellationToken)
            .ConfigureAwait(false);
        if (!mkdir.Ok)
        {
            return mkdir;
        }

        return await RunAsync(
                new[] { "-s", serial, "push", "-p", localPath, remoteDirectory },
                timeout ?? TimeSpan.FromMinutes(30),
                progress,
                cancellationToken)
            .ConfigureAwait(false);
    }

    // MARK: - 文件拉取

    /// <summary>从手机拉取文件 / 目录，进度 0~100。</summary>
    public Task<AdbResult> PullAsync(
        string serial,
        string remotePath,
        string localPath,
        IProgress<double>? progress = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        return RunAsync(
            new[] { "-s", serial, "pull", "-p", remotePath, localPath },
            timeout ?? TimeSpan.FromMinutes(10),
            progress,
            cancellationToken);
    }

    /// <summary>把 adb 的原始报错翻成人话，对应 macOS 端的 <c>ADB.friendly</c>。</summary>
    public static string Friendly(string? raw, string fallback = "adb 执行失败")
    {
        var message = (raw ?? string.Empty).Trim();
        if (message.Length == 0)
        {
            return fallback;
        }

        var lower = message.ToLowerInvariant();
        if (lower.Contains("超时") || lower.Contains("timed out"))
        {
            return "adb 命令超时：5037 端口上的 adb 服务端可能被模拟器 / 手机助手 / QtScrcpy 等工具占用，"
                 + "版本与本机 adb 不一致时 shell 命令就会卡死。请关闭这些工具后重试。";
        }

        if (lower.Contains("server version")) return "adb 服务端版本不一致，已自动重试；仍失败请重启 adb 服务";
        if (lower.Contains("no devices")) return "未检测到设备，请连接手机并开启 USB 调试";
        if (lower.Contains("unauthorized")) return "设备未授权，请在手机上点击「允许 USB 调试」";
        if (lower.Contains("offline")) return "设备离线，请重新插拔 USB 数据线后重试";
        if (lower.Contains("closed")) return "连接已断开，请重新连接设备";
        if (lower.Contains("not found")) return $"adb 不可用：{message}";
        if (lower.Contains("exception") || lower.Contains("java.lang"))
        {
            return "手机端执行 input 出错，请确认屏幕已解锁、输入框可编辑后重试";
        }

        return Shorten(message, 3);
    }

    private static string Shorten(string text, int lines)
    {
        var all = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        return all.Length <= lines ? text : string.Join("\n", all.Take(lines)) + " …";
    }

    // MARK: - 进程执行

    private static readonly Regex PercentPattern = new("(\\d{1,3})%", RegexOptions.Compiled);

    /// <summary>
    /// 执行 adb 命令。<paramref name="timeout"/> 到点会杀掉进程并返回「adb 命令超时」。
    /// 遇到 adb server 版本冲突（别的工具抢占了 5037）时自动重试一次，和 macOS 端一致。
    /// </summary>
    private async Task<AdbResult> RunAsync(
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        IProgress<double>? progress,
        CancellationToken cancellationToken)
    {
        var result = await RunOnceAsync(arguments, timeout, progress, cancellationToken).ConfigureAwait(false);
        if (!result.Ok && result.Text.Contains("server version", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                await Task.Delay(600, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return result;
            }

            result = await RunOnceAsync(arguments, timeout, progress, cancellationToken).ConfigureAwait(false);
        }

        return result;
    }

    private async Task<AdbResult> RunOnceAsync(
        IReadOnlyList<string> arguments,
        TimeSpan timeout,
        IProgress<double>? progress,
        CancellationToken cancellationToken)
    {
        if (!IsAvailable)
        {
            return new AdbResult(-1, "未找到 adb（platform-tools）", false);
        }

        var startInfo = new ProcessStartInfo(AdbPath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        // 让 adb 用固定 locale，报错文案才好判断。
        try
        {
            startInfo.Environment["LC_ALL"] = "C";
            startInfo.Environment["LANG"] = "C";
        }
        catch (Exception)
        {
            // 某些环境不允许改环境变量，忽略。
        }

        var buffer = new StringBuilder();
        var timedOut = false;

        using var process = new Process { StartInfo = startInfo };
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);

        try
        {
            if (!process.Start())
            {
                return new AdbResult(-1, $"无法启动 {AdbPath}", false);
            }
        }
        catch (Exception ex)
        {
            return new AdbResult(-1, $"无法运行 {AdbPath}：{ex.Message}", false);
        }

        var stdoutTask = PumpAsync(process.StandardOutput, buffer, progress, timeoutSource.Token);
        var stderrTask = PumpAsync(process.StandardError, buffer, progress, timeoutSource.Token);

        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            timedOut = true;
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (Exception)
            {
                // 已经退出。
            }
        }

        try
        {
            await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // 读取被取消，忽略。
        }

        var text = buffer.ToString().Trim();
        if (cancellationToken.IsCancellationRequested)
        {
            return new AdbResult(-1, text.Length == 0 ? "已取消" : text, true);
        }

        if (timedOut)
        {
            return new AdbResult(-1, text.Length == 0 ? "adb 命令超时" : text, true);
        }

        int exitCode;
        try
        {
            exitCode = process.HasExited ? process.ExitCode : -1;
        }
        catch (Exception)
        {
            exitCode = -1;
        }

        return new AdbResult(exitCode, text, true);
    }

    private static async Task PumpAsync(
        StreamReader reader,
        StringBuilder buffer,
        IProgress<double>? progress,
        CancellationToken cancellationToken)
    {
        var chunk = new char[4096];
        while (true)
        {
            int read;
            try
            {
                read = await reader.ReadAsync(chunk.AsMemory(), cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception)
            {
                return;
            }

            if (read <= 0)
            {
                return;
            }

            var text = new string(chunk, 0, read);
            lock (buffer)
            {
                buffer.Append(text);
            }

            if (progress is null)
            {
                continue;
            }

            // adb push -p 用 \r 原地刷新进度，形如 "[ 45%] /sdcard/a.bin"。
            var matches = PercentPattern.Matches(text);
            if (matches.Count > 0)
            {
                var last = matches[^1];
                if (int.TryParse(last.Groups[1].Value, out var percent))
                {
                    progress.Report(Math.Clamp(percent, 0, 100) / 100.0);
                }
            }
        }
    }
}
