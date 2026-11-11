using System.Globalization;

namespace ADBTypeLink.Core;

/// <summary>手机文件浏览的一项；对应 macOS 的 DeviceFileEntry。</summary>
public sealed record DeviceFileEntry(
    string Name,
    string Path,
    bool IsDirectory,
    bool IsSymlink,
    long Size,
    string Modified,
    string Permissions,
    string? LinkTarget)
{
    public bool IsHidden => Name.StartsWith('.');

    public string SizeText
    {
        get
        {
            if (IsDirectory) return "—";
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            double value = Size;
            var unit = 0;
            while (value >= 1024 && unit < units.Length - 1)
            {
                value /= 1024;
                unit++;
            }
            return unit == 0
                ? $"{Size} B"
                : $"{value.ToString("0.#", CultureInfo.InvariantCulture)} {units[unit]}";
        }
    }
}

/// <summary>手机路径规范化；对应 macOS 的 DevicePath。</summary>
public static class DevicePath
{
    public static string Normalize(string? raw)
    {
        var value = (raw ?? string.Empty).Trim();
        if (value.Length == 0) return "/";
        if (!value.StartsWith('/')) value = "/" + value;
        var parts = new List<string>();
        foreach (var component in value.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (component == ".") continue;
            if (component == "..")
            {
                if (parts.Count > 0) parts.RemoveAt(parts.Count - 1);
                continue;
            }
            parts.Add(component);
        }
        return "/" + string.Join('/', parts);
    }

    public static string Join(string directory, string name)
        => directory == "/" ? "/" + name : directory.TrimEnd('/') + "/" + name;

    public static string Parent(string path)
    {
        var normalized = Normalize(path);
        if (normalized == "/") return "/";
        var index = normalized.LastIndexOf('/');
        return index <= 0 ? "/" : normalized[..index];
    }

    public static bool IsAppDataPath(string path)
    {
        var normalized = Normalize(path);
        return normalized == "/data"
            || normalized == "/data/data"
            || normalized.StartsWith("/data/data/", StringComparison.Ordinal);
    }

    public static bool IsHostOnlyPath(string path)
    {
        var lower = path.ToLowerInvariant();
        if (lower.StartsWith("file://", StringComparison.Ordinal)) return true;
        string[] prefixes = { "/users/", "/volumes/", "/applications/", "/library/", "/private/" };
        return prefixes.Any(lower.StartsWith);
    }
}

/// <summary>解析 adb shell ls -la；对应 macOS 的 DeviceFileParser。</summary>
public static class DeviceFileParser
{
    public static List<DeviceFileEntry> Parse(string output, string directory)
    {
        var entries = new List<DeviceFileEntry>();
        foreach (var rawLine in output.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r', '\n');
            if (line.Length == 0 || line.StartsWith("total ", StringComparison.Ordinal)) continue;

            var parts = line.Split(' ', 8, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 8) continue;
            var permissions = parts[0];
            if (permissions.Length < 10) continue;
            var type = permissions[0];
            if ("dl-bcps".IndexOf(type) < 0) continue;

            _ = long.TryParse(parts[4], out var size);
            var modified = parts[5] + " " + parts[6];
            var name = parts[7];
            string? linkTarget = null;
            var arrow = name.IndexOf(" -> ", StringComparison.Ordinal);
            if (arrow >= 0)
            {
                linkTarget = name[(arrow + 4)..];
                name = name[..arrow];
            }
            if (name.Length == 0 || name == "." || name == "..") continue;

            entries.Add(new DeviceFileEntry(
                name,
                DevicePath.Join(directory, name),
                type == 'd',
                type == 'l',
                size,
                modified,
                permissions,
                linkTarget));
        }

        return entries
            .OrderByDescending(item => item.IsDirectory)
            .ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static List<DeviceFileEntry> ParsePackages(string output, string directory)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rawLine in output.Split('\n'))
        {
            var line = rawLine.Trim();
            if (!line.StartsWith("package:", StringComparison.Ordinal)) continue;
            var name = line["package:".Length..].Trim();
            if (name.Length == 0 || name.Contains('/')) continue;
            names.Add(name);
        }

        return names
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .Select(name => new DeviceFileEntry(
                name,
                DevicePath.Join(directory, name),
                true,
                false,
                0,
                "—",
                "app",
                null))
            .ToList();
    }
}

/// <summary>手机文件浏览的 adb 操作；对应 macOS 的 ADB extension。</summary>
public sealed class DeviceFileService
{
    private readonly AdbService _adb;

    public DeviceFileService(AdbService adb)
    {
        _adb = adb;
    }

    public AdbService Adb => _adb;

    public async Task<(List<DeviceFileEntry>? Entries, string? Error)> ListDirectoryAsync(
        string serial,
        string path,
        CancellationToken cancellationToken = default)
    {
        var target = DevicePath.Normalize(path);
        var listingPath = target == "/" ? "/" : target.TrimEnd('/') + "/";
        var command = "ls -la " + AdbService.ShellQuote(listingPath);
        var result = await _adb.ShellAsync(serial, command, TimeSpan.FromSeconds(25), cancellationToken)
            .ConfigureAwait(false);

        if (result.Ok)
        {
            return (DeviceFileParser.Parse(result.Text, target), null);
        }

        if (target == "/data")
        {
            return ([new DeviceFileEntry("data", "/data/data", true, false, 0, "—", "dir", null)], null);
        }

        if (target == "/data/data")
        {
            var packages = await ListPackagesAsync(serial, cancellationToken).ConfigureAwait(false);
            if (packages.Count > 0) return (packages, null);
        }

        if (target.StartsWith("/data/data/", StringComparison.Ordinal))
        {
            var runAs = await ListWithRunAsAsync(serial, target, cancellationToken).ConfigureAwait(false);
            if (runAs.Entries is not null) return runAs;
            return (null, runAs.Error);
        }

        return (null, FileError(result, $"无法读取 {target}"));
    }

    public async Task<List<DeviceFileEntry>> ListPackagesAsync(
        string serial,
        CancellationToken cancellationToken = default)
    {
        var result = await _adb.ShellAsync(serial, "pm list packages", TimeSpan.FromSeconds(25), cancellationToken)
            .ConfigureAwait(false);
        return result.Ok ? DeviceFileParser.ParsePackages(result.Text, "/data/data") : [];
    }

    private async Task<(List<DeviceFileEntry>? Entries, string? Error)> ListWithRunAsAsync(
        string serial,
        string path,
        CancellationToken cancellationToken)
    {
        const string prefix = "/data/data/";
        var relative = path[prefix.Length..];
        var pieces = relative.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (pieces.Length == 0) return (null, "应用数据路径无效");

        var package = pieces[0];
        var subpath = string.Join('/', pieces.Skip(1));
        var command = "run-as " + AdbService.ShellQuote(package)
            + " ls -la " + AdbService.ShellQuote(subpath.Length == 0 ? "." : subpath);
        var result = await _adb.ShellAsync(serial, command, TimeSpan.FromSeconds(25), cancellationToken)
            .ConfigureAwait(false);
        if (result.Ok)
        {
            return (DeviceFileParser.Parse(result.Text, path), null);
        }

        var lower = result.Text.ToLowerInvariant();
        if (lower.Contains("not debuggable"))
        {
            return (null, $"{package} 不是 debuggable 应用，无法读取它的数据目录");
        }
        if (lower.Contains("not an application"))
        {
            return (null, $"{package} 没有可访问的应用数据目录");
        }
        return (null, FileError(result, $"无法读取 {path}"));
    }

    public async Task<bool> IsDirectoryAsync(string serial, string path, CancellationToken cancellationToken = default)
    {
        var normalized = DevicePath.Normalize(path);
        if (normalized == "/data" || normalized == "/data/data" || normalized.StartsWith("/data/data/", StringComparison.Ordinal))
        {
            return true;
        }

        var quoted = AdbService.ShellQuote(normalized);
        var command = $"if [ -d {quoted} ]; then echo __adbtype_dir__; elif [ -e {quoted} ]; then echo __adbtype_file__; else echo __adbtype_missing__; fi";
        var result = await _adb.ShellAsync(serial, command, TimeSpan.FromSeconds(15), cancellationToken)
            .ConfigureAwait(false);
        return result.Ok && result.Text.Contains("__adbtype_dir__", StringComparison.Ordinal);
    }

    public async Task<AdbResult> CreateAsync(
        string serial,
        string path,
        bool isDirectory,
        CancellationToken cancellationToken = default)
    {
        var target = DevicePath.Normalize(path);
        if (target == "/" || DevicePath.IsHostOnlyPath(target))
        {
            return new AdbResult(-1, "不能在手机根目录执行这个操作", true);
        }
        if (DevicePath.IsAppDataPath(target))
        {
            return new AdbResult(-1, "应用数据目录只能浏览，不能新建", true);
        }

        var quoted = AdbService.ShellQuote(target);
        var check = await _adb.ShellAsync(
            serial,
            $"if [ -e {quoted} ]; then echo __adbtype_exists__; fi",
            TimeSpan.FromSeconds(15),
            cancellationToken).ConfigureAwait(false);
        if (check.Ok && check.Text.Contains("__adbtype_exists__", StringComparison.Ordinal))
        {
            return new AdbResult(-1, "同名文件或文件夹已存在", true);
        }

        var command = isDirectory ? "mkdir " + quoted : ": > " + quoted;
        return await _adb.ShellAsync(serial, command, TimeSpan.FromSeconds(20), cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<AdbResult> RemoveAsync(
        string serial,
        string path,
        CancellationToken cancellationToken = default)
    {
        var target = DevicePath.Normalize(path);
        if (target == "/" || DevicePath.IsHostOnlyPath(target))
        {
            return new AdbResult(-1, "只能删除手机目录里的内容", true);
        }
        if (DevicePath.IsAppDataPath(target))
        {
            return new AdbResult(-1, "应用数据目录只能浏览，不能删除", true);
        }

        return await _adb.ShellAsync(serial, "rm -rf " + AdbService.ShellQuote(target), TimeSpan.FromSeconds(30), cancellationToken)
            .ConfigureAwait(false);
    }

    public Task<AdbResult> PullAsync(
        string serial,
        string remotePath,
        string localPath,
        IProgress<double>? progress = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        return _adb.PullAsync(serial, remotePath, localPath, progress, timeout, cancellationToken);
    }

    public Task<AdbResult> PushAsync(
        string serial,
        string localPath,
        string remoteDirectory,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        return _adb.PushAsync(serial, localPath, remoteDirectory, progress, null, cancellationToken);
    }

    public static string FileError(AdbResult result, string fallback)
    {
        if (!result.Launched) return result.Text;
        var raw = result.Text.Trim();
        var lower = raw.ToLowerInvariant();
        if (lower.Contains("permission denied")) return "没有权限读取这个路径";
        if (lower.Contains("no such file or directory")) return "路径不存在";
        if (lower.Contains("not a directory")) return "这不是一个文件夹";
        if (lower.Contains("no devices") || lower.Contains("unauthorized") || lower.Contains("offline"))
        {
            return AdbService.Friendly(raw);
        }
        return raw.Length == 0 ? fallback : raw;
    }
}
