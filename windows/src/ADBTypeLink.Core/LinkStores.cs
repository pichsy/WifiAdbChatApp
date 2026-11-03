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

/// <summary>
/// 按设备分开的聊天记录：每台设备一个文件（chats/&lt;peerId&gt;.json）。
///
/// 以前所有消息挤在一个 chat.json 里，界面上只能是一条全局流，
/// 跟谁说过什么全靠 PeerName 猜。现在一台设备一份缓存，
/// 清空某台设备不影响别人，设备列表里的每一项都指向自己那份。
/// </summary>
internal sealed class ConversationStore
{
    public const int MaxMessages = 500;

    /// <summary>没有设备 ID 的旧消息，按名字分开存放，键名前缀。</summary>
    public const string LegacyPrefix = "legacy:";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly Dictionary<string, List<ChatMessage>> _buckets = new(StringComparer.Ordinal);

    public ConversationStore(string directory, string legacyChatFile)
    {
        _directory = directory;
        try
        {
            Directory.CreateDirectory(_directory);
        }
        catch (Exception)
        {
            // 目录建不出来时后续读写各自失败，不阻塞启动。
        }

        MigrateLegacy(legacyChatFile);
    }

    /// <summary>消息属于哪个会话：有设备 ID 用 ID，旧消息按名字归堆。</summary>
    public static string KeyFor(ChatMessage message) =>
        !string.IsNullOrEmpty(message.PeerId) ? message.PeerId : LegacyPrefix + message.PeerName;

    /// <summary>某台设备的完整会话（按时间升序）。</summary>
    public IReadOnlyList<ChatMessage> Snapshot(string key)
    {
        if (string.IsNullOrEmpty(key))
        {
            return Array.Empty<ChatMessage>();
        }

        lock (_gate)
        {
            return BucketLocked(key).ToArray();
        }
    }

    /// <summary>
    /// 某台设备看到的会话：它自己的消息 + 迁移过来的旧消息（同名）。
    /// 旧版本没有 PeerId，只能按名字对齐，这样升级后历史记录不会凭空消失。
    /// </summary>
    public IReadOnlyList<ChatMessage> SnapshotForPeer(string peerId, string peerName)
    {
        lock (_gate)
        {
            // 旧会话设备的 Id 本身就是 legacy:<名字>，和按名字回退找的是同一个桶，
            // 不去重就会把整段历史重复显示一遍。
            var keys = new HashSet<string>(StringComparer.Ordinal);
            if (!string.IsNullOrEmpty(peerId))
            {
                keys.Add(peerId);
            }

            if (!string.IsNullOrEmpty(peerName))
            {
                keys.Add(LegacyPrefix + peerName);
            }

            var merged = new List<ChatMessage>();
            foreach (var key in keys)
            {
                merged.AddRange(BucketLocked(key));
            }

            return merged.OrderBy(message => message.Date).ToArray();
        }
    }

    /// <summary>所有会话键（含 legacy: 开头的旧会话）。</summary>
    public IReadOnlyList<string> Keys()
    {
        lock (_gate)
        {
            LoadAllLocked();
            return _buckets.Keys.ToArray();
        }
    }

    /// <summary>旧会话的名字（没有设备 ID 的那部分）。</summary>
    public IReadOnlyList<string> LegacyNames()
    {
        lock (_gate)
        {
            LoadAllLocked();
            return _buckets.Keys
                .Where(key => key.StartsWith(LegacyPrefix, StringComparison.Ordinal))
                .Select(key => key[LegacyPrefix.Length..])
                .OrderBy(name => name, StringComparer.CurrentCulture)
                .ToArray();
        }
    }

    public void Append(ChatMessage message)
    {
        var key = KeyFor(message);
        if (string.IsNullOrEmpty(key))
        {
            return;
        }

        lock (_gate)
        {
            var bucket = BucketLocked(key);
            bucket.Add(message);
            if (bucket.Count > MaxMessages)
            {
                bucket.RemoveRange(0, bucket.Count - MaxMessages);
            }

            SaveLocked(key, bucket);
        }
    }

    public void Clear(string key)
    {
        lock (_gate)
        {
            _buckets.Remove(key);
            TryDelete(key);
        }
    }

    public void ClearAll()
    {
        lock (_gate)
        {
            _buckets.Clear();
            try
            {
                foreach (var file in Directory.EnumerateFiles(_directory, "*.json"))
                {
                    File.Delete(file);
                }
            }
            catch (Exception)
            {
                // 删不掉就留着，不影响使用。
            }
        }
    }

    private List<ChatMessage> BucketLocked(string key)
    {
        if (_buckets.TryGetValue(key, out var bucket))
        {
            return bucket;
        }

        bucket = new List<ChatMessage>();
        _buckets[key] = bucket;
        LoadFileLocked(key, bucket);
        return bucket;
    }

    private void LoadAllLocked()
    {
        try
        {
            if (!Directory.Exists(_directory))
            {
                return;
            }

            foreach (var file in Directory.EnumerateFiles(_directory, "*.json"))
            {
                var key = Unescape(Path.GetFileNameWithoutExtension(file));
                if (!string.IsNullOrEmpty(key))
                {
                    BucketLocked(key);
                }
            }
        }
        catch (Exception)
        {
            // 目录读不出来就当没有历史记录。
        }
    }

    private void LoadFileLocked(string key, List<ChatMessage> bucket)
    {
        try
        {
            var path = FilePathFor(key);
            if (!File.Exists(path))
            {
                return;
            }

            var list = JsonSerializer.Deserialize<List<ChatMessage>>(File.ReadAllText(path), JsonOptions);
            if (list is null)
            {
                return;
            }

            bucket.AddRange(list.OrderBy(message => message.Date));
            if (bucket.Count > MaxMessages)
            {
                bucket.RemoveRange(0, bucket.Count - MaxMessages);
            }
        }
        catch (Exception)
        {
            // 损坏的会话文件按空处理，不能因为一条坏记录起不来。
            bucket.Clear();
        }
    }

    private void SaveLocked(string key, List<ChatMessage> bucket)
    {
        try
        {
            Directory.CreateDirectory(_directory);
            var path = FilePathFor(key);
            var json = JsonSerializer.Serialize(bucket, JsonOptions);
            var temp = path + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception)
        {
            // 磁盘异常时忽略，避免打断收发。
        }
    }

    private string FilePathFor(string key) => Path.Combine(_directory, Sanitize(key) + ".json");

    private void TryDelete(string key)
    {
        try
        {
            var path = FilePathFor(key);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception)
        {
            // 忽略。
        }
    }

    /// <summary>
    /// 设备 ID 一般是 UUID，但旧会话的键是 legacy:&lt;名字&gt;，必须能还原回去，
    /// 所以用 %XX 转义而不是简单替换成下划线——否则重启后键名对不上，历史就找不回来了。
    /// </summary>
    private static string Sanitize(string key)
    {
        var builder = new StringBuilder(key.Length + 8);
        foreach (var character in key)
        {
            if (char.IsLetterOrDigit(character) || character is '-' or '_' or '.')
            {
                builder.Append(character);
            }
            else
            {
                builder.Append('%').Append(((int)character).ToString("X2"));
            }
        }

        return builder.Length == 0 ? "empty" : builder.ToString();
    }

    private static string Unescape(string name)
    {
        var builder = new StringBuilder(name.Length);
        for (var index = 0; index < name.Length; index++)
        {
            if (name[index] == '%'
                && index + 2 < name.Length
                && byte.TryParse(name.AsSpan(index + 1, 2), System.Globalization.NumberStyles.HexNumber, null, out var code))
            {
                builder.Append((char)code);
                index += 2;
            }
            else
            {
                builder.Append(name[index]);
            }
        }

        return builder.ToString();
    }

    /// <summary>
    /// 把旧版单文件 chat.json 拆成按设备的会话，然后把原文件改名留底。
    /// 旧消息没有 PeerId，只能按 PeerName 分堆；等设备上线后按名字对上。
    /// </summary>
    private void MigrateLegacy(string legacyChatFile)
    {
        try
        {
            if (!File.Exists(legacyChatFile))
            {
                return;
            }

            var list = JsonSerializer.Deserialize<List<ChatMessage>>(File.ReadAllText(legacyChatFile), JsonOptions);
            if (list is not null)
            {
                foreach (var message in list.OrderBy(item => item.Date))
                {
                    var key = KeyFor(message);
                    if (string.IsNullOrEmpty(key))
                    {
                        continue;
                    }

                    var bucket = BucketLocked(key);
                    bucket.Add(message);
                    if (bucket.Count > MaxMessages)
                    {
                        bucket.RemoveRange(0, bucket.Count - MaxMessages);
                    }
                }

                foreach (var pair in _buckets.ToArray())
                {
                    if (pair.Value.Count > 0)
                    {
                        SaveLocked(pair.Key, pair.Value);
                    }
                }
            }

            File.Move(legacyChatFile, legacyChatFile + ".migrated", overwrite: true);
        }
        catch (Exception)
        {
            // 迁移失败就当没有旧记录，原来的 chat.json 保持不动，下次启动再试。
        }
    }
}

/// <summary>记住过的设备：devices.json，一台设备一条。</summary>
internal sealed class KnownDeviceRecord
{
    public string Id { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public DateTime LastSeenUtc { get; set; }
}

/// <summary>
/// 设备名册。写入时机只有两个：配对成功、收发过消息——所以列表里不会
/// 堆满匆匆路过的设备，但「配对过的」和「有过来往的」一定留得住。
/// </summary>
internal sealed class DeviceStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly string _filePath;
    private readonly object _gate = new();
    private readonly Dictionary<string, KnownDeviceRecord> _devices = new(StringComparer.Ordinal);

    public DeviceStore(string filePath)
    {
        _filePath = filePath;
        Load();
    }

    public IReadOnlyList<KnownDeviceRecord> Snapshot()
    {
        lock (_gate)
        {
            return _devices.Values
                .OrderByDescending(record => record.LastSeenUtc)
                .ToArray();
        }
    }

    public void Upsert(string id, string name)
    {
        if (string.IsNullOrEmpty(id))
        {
            return;
        }

        lock (_gate)
        {
            var changed = false;
            if (_devices.TryGetValue(id, out var record))
            {
                if (!string.IsNullOrEmpty(name) && !string.Equals(record.Name, name, StringComparison.Ordinal))
                {
                    record.Name = name;
                    changed = true;
                }

                record.LastSeenUtc = DateTime.UtcNow;
            }
            else
            {
                _devices[id] = new KnownDeviceRecord
                {
                    Id = id,
                    Name = name,
                    LastSeenUtc = DateTime.UtcNow,
                };
                changed = true;
            }

            // 广播每两秒来一次，名字没变就不要反复写盘。
            if (changed)
            {
                SaveLocked();
            }
        }
    }

    public void Remove(string id)
    {
        lock (_gate)
        {
            if (_devices.Remove(id))
            {
                SaveLocked();
            }
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

            var list = JsonSerializer.Deserialize<List<KnownDeviceRecord>>(File.ReadAllText(_filePath), JsonOptions);
            if (list is null)
            {
                return;
            }

            foreach (var record in list)
            {
                if (!string.IsNullOrEmpty(record.Id))
                {
                    _devices[record.Id] = record;
                }
            }
        }
        catch (Exception)
        {
            _devices.Clear();
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

            var json = JsonSerializer.Serialize(_devices.Values.OrderBy(record => record.Name, StringComparer.CurrentCulture).ToArray(), JsonOptions);
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception)
        {
            // 忽略。
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