using System.Text;
using System.Text.Json;

namespace ADBTypeLink.Core;

/// <summary>
/// 本机多实例兜底发现（不属于网络协议，只是同一台电脑上两个实例的本地注册表）。
///
/// 原因：macOS/Windows 上多个 socket 绑定同一 UDP 端口时，发往 127.0.0.1 的单播只会投递给
/// 最后绑定的那个 socket（实测行为），所以规格 §2.1 里「本机回环」这条路在旧系统语义下
/// 只能单向发现。这里用临时目录里每个实例一个心跳文件补齐同机双实例发现，
/// 不改变任何网络报文，远端设备仍走 UDP 广播。
/// </summary>
internal sealed class LocalInstanceRegistry : IDisposable
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(2);

    private readonly string _instanceId;
    private readonly string _instanceName;
    private readonly Func<int> _portProvider;
    private Action<string>? _log;
    private readonly string _directory;
    private readonly string _filePath;

    private Timer? _timer;
    private int _started;

    public LocalInstanceRegistry(string instanceId, string instanceName, Func<int> portProvider, Action<string>? log = null)
    {
        _instanceId = instanceId;
        _instanceName = instanceName;
        _portProvider = portProvider;
        _log = log;
        _directory = DefaultDirectory;
        _filePath = Path.Combine(_directory, Sanitize(instanceId) + ".json");
    }

    /// <summary>运行期替换日志出口（应用启动后再挂文件日志时用）。</summary>
    public void SetLog(Action<string>? log) => _log = log;

    /// <summary>本机实例注册目录（每个用户独立，Windows 在 %TEMP%，macOS 在 /var/folders/...）。</summary>
    public static string DefaultDirectory => Path.Combine(Path.GetTempPath(), "ADBTypeLink", "instances");

    public void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) == 1)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(_directory);
        }
        catch (Exception ex)
        {
            _log?.Invoke($"local registry dir failed: {ex.Message}");
        }

        WriteSelf();
        _timer = new Timer(_ => WriteSelf(), null, RefreshInterval, RefreshInterval);
    }

    /// <summary>扫描本机其它实例；超过 8 秒没更新的记录视为已退出。</summary>
    public IReadOnlyList<LinkPeer> Scan()
    {
        var peers = new List<LinkPeer>();
        try
        {
            if (!Directory.Exists(_directory))
            {
                return peers;
            }

            var now = DateTime.UtcNow;
            foreach (var file in Directory.EnumerateFiles(_directory, "*.json"))
            {
                try
                {
                    var info = new FileInfo(file);
                    if ((now - info.LastWriteTimeUtc) > LinkProtocol.InstanceTimeout)
                    {
                        continue;
                    }

                    using var document = JsonDocument.Parse(File.ReadAllText(file));
                    var root = document.RootElement;
                    if (root.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }

                    var id = LinkProtocol.GetString(root, "id");
                    var name = LinkProtocol.GetString(root, "name");
                    var port = LinkProtocol.GetInt64(root, "port");
                    if (string.IsNullOrEmpty(id)
                        || string.Equals(id, _instanceId, StringComparison.Ordinal)
                        || string.IsNullOrEmpty(name)
                        || port is null or <= 0 or > 65535)
                    {
                        continue;
                    }

                    peers.Add(new LinkPeer
                    {
                        Id = id,
                        Name = name,
                        Host = "127.0.0.1",
                        Port = (int)port.Value,
                        LastSeenUtc = info.LastWriteTimeUtc,
                    });
                }
                catch (Exception)
                {
                    // 单个坏文件忽略。
                }
            }
        }
        catch (Exception ex)
        {
            _log?.Invoke($"local registry scan failed: {ex.Message}");
        }

        return peers;
    }

    private void WriteSelf()
    {
        try
        {
            var port = _portProvider();
            if (port <= 0)
            {
                return;
            }

            var payload = JsonSerializer.Serialize(new
            {
                id = _instanceId,
                name = _instanceName,
                host = "127.0.0.1",
                port,
                pid = Environment.ProcessId,
            });

            Directory.CreateDirectory(_directory);
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, payload, new UTF8Encoding(false));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception ex)
        {
            _log?.Invoke($"local registry write failed: {ex.Message}");
        }
    }

    private static string Sanitize(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var character in value)
        {
            builder.Append(char.IsLetterOrDigit(character) || character is '-' or '_' ? character : '_');
        }

        return builder.Length == 0 ? "instance" : builder.ToString();
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _started, 0) == 0)
        {
            return;
        }

        _timer?.Dispose();
        _timer = null;

        try
        {
            if (File.Exists(_filePath))
            {
                File.Delete(_filePath);
            }
        }
        catch (Exception)
        {
            // 删除失败只会留下一个会过期的文件。
        }
    }
}
