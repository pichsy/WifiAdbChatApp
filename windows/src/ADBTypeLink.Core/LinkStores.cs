using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ADBTypeLink.Core;

/// <summary>本机设备 ID：首次启动生成 UUID 并持久化（§8 device.json）。</summary>
internal static class DeviceIdStore
{
    public static string LoadOrCreate(string filePath)
    {
        try
        {
            if (File.Exists(filePath))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(filePath));
                if (document.RootElement.ValueKind == JsonValueKind.Object
                    && LinkProtocol.GetString(document.RootElement, "deviceId") is { Length: > 0 } saved)
                {
                    return saved;
                }
            }
        }
        catch (Exception)
        {
            // 文件损坏就重新生成。
        }

        var deviceId = Guid.NewGuid().ToString();
        WriteAtomic(filePath, JsonSerializer.Serialize(new { deviceId }, Options()));
        return deviceId;
    }

    private static JsonSerializerOptions Options() => new() { WriteIndented = true };

    private static void WriteAtomic(string path, string content)
    {
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var temp = path + ".tmp";
            File.WriteAllText(temp, content, new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception)
        {
            // 写不了就下次再试，设备 ID 本次仍可用。
        }
    }
}

/// <summary>已配对设备 ID 集合（§8 paired.json，JSON 字符串数组）。</summary>
internal sealed class PairedStore
{
    private readonly string _filePath;
    private readonly object _gate = new();
    private readonly HashSet<string> _ids = new(StringComparer.Ordinal);

    public PairedStore(string filePath)
    {
        _filePath = filePath;
        Load();
    }

    public int Count
    {
        get
        {
            lock (_gate)
            {
                return _ids.Count;
            }
        }
    }

    public bool Contains(string peerId)
    {
        lock (_gate)
        {
            return _ids.Contains(peerId);
        }
    }

    /// <summary>返回是否新插入。</summary>
    public bool Add(string peerId)
    {
        bool inserted;
        lock (_gate)
        {
            inserted = _ids.Add(peerId);
            if (inserted)
            {
                SaveLocked();
            }
        }

        return inserted;
    }

    public bool Remove(string peerId)
    {
        bool removed;
        lock (_gate)
        {
            removed = _ids.Remove(peerId);
            if (removed)
            {
                SaveLocked();
            }
        }

        return removed;
    }

    public void Clear()
    {
        lock (_gate)
        {
            _ids.Clear();
            SaveLocked();
        }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return;
            }

            var list = JsonSerializer.Deserialize<string[]>(File.ReadAllText(_filePath));
            if (list is null)
            {
                return;
            }

            foreach (var id in list)
            {
                if (!string.IsNullOrEmpty(id))
                {
                    _ids.Add(id);
                }
            }
        }
        catch (Exception)
        {
            // 损坏的配对文件按空集合处理。
        }
    }

    private void SaveLocked()
    {
        try
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(_ids.ToArray()), new UTF8Encoding(false));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception)
        {
            // 持久化失败不影响本次运行。
        }
    }
}

/// <summary>聊天记录（§8 chat.json）：单条时间线，最多 500 条。</summary>
internal sealed class ChatStore
{
    public const int MaxMessages = 500;

    private readonly string _filePath;
    private readonly object _gate = new();
    private readonly List<ChatMessage> _messages = new();

    public ChatStore(string filePath)
    {
        _filePath = filePath;
        Load();
    }

    public IReadOnlyList<ChatMessage> Snapshot()
    {
        lock (_gate)
        {
            return _messages.ToArray();
        }
    }

    public void Append(ChatMessage message)
    {
        lock (_gate)
        {
            _messages.Add(message);
            if (_messages.Count > MaxMessages)
            {
                _messages.RemoveRange(0, _messages.Count - MaxMessages);
            }

            SaveLocked();
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _messages.Clear();
            SaveLocked();
        }
    }

    private static JsonSerializerOptions Options() => new()
    {
        WriteIndented = false,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private void Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return;
            }

            var list = JsonSerializer.Deserialize<List<ChatMessage>>(File.ReadAllText(_filePath), Options());
            if (list is null)
            {
                return;
            }

            _messages.AddRange(list.OrderBy(item => item.Date));
            if (_messages.Count > MaxMessages)
            {
                _messages.RemoveRange(0, _messages.Count - MaxMessages);
            }
        }
        catch (Exception)
        {
            // 损坏的聊天记录按空处理，不影响启动。
            _messages.Clear();
        }
    }

    private void SaveLocked()
    {
        try
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var json = JsonSerializer.Serialize(_messages, Options());
            // 直接写原始 UTF-8（中文不转义），与 macOS 端 chat.json 风格一致。
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception)
        {
            // 磁盘异常时忽略，避免打断收发。
        }
    }
}

/// <summary>本机设置：接收目录（§8）。</summary>
internal sealed class SettingsStore
{
    private readonly string _filePath;

    public SettingsStore(string filePath)
    {
        _filePath = filePath;
    }

    public string? ReceiveDir { get; private set; }

    public void Load()
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                return;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(_filePath));
            if (document.RootElement.ValueKind == JsonValueKind.Object)
            {
                ReceiveDir = LinkProtocol.GetString(document.RootElement, "receiveDir");
            }
        }
        catch (Exception)
        {
            ReceiveDir = null;
        }
    }

    public void Save(string receiveDir)
    {
        ReceiveDir = receiveDir;
        try
        {
            var json = JsonSerializer.Serialize(
                new { receiveDir },
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                    Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
                });
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception)
        {
            // 设置写不进去也不影响本次使用。
        }
    }
}
