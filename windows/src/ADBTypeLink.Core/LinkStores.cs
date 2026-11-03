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

    public IReadOnlyList<string> Snapshot()
    {
        lock (_gate)
        {
            return _ids.ToArray();
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
/// Swift 的 Date 在 JSON 里是「自 2001-01-01 UTC 起的秒数」。这里也接受 ISO 8601 字符串，
/// 方便读上一版 Windows 写下的文件（那时用的是字符串）。
/// </summary>
internal sealed class AppleDateConverter : JsonConverter<double>
{
    private static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public override double Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number)
        {
            return reader.GetDouble();
        }

        if (reader.TokenType == JsonTokenType.String)
        {
            var text = reader.GetString();
            if (DateTimeOffset.TryParse(
                    text,
                    System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.AssumeUniversal,
                    out var parsed))
            {
                return (parsed.UtcDateTime - AppleEpoch).TotalSeconds;
            }
        }

        reader.Skip();
        return 0;
    }

    public override void Write(Utf8JsonWriter writer, double value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value);

    private static double Skip() => 0;
}

/// <summary>
/// 按设备分开的聊天记录：chats/&lt;设备ID&gt;.json，格式与 macOS 端完全一致
/// （LANTransfer.swift 的 LANMessage：id / direction / peerName / date / kind /
/// text / fileName / filePath / fileSize，没有 peerId 字段——归属由文件名决定）。
///
/// 时间沿用 Swift 的 Date 编码：JSON 里是**自 2001-01-01 UTC 起的秒数**（double），
/// 不是 ISO 字符串；可选字段为 nil 时整个键不出现。
/// </summary>
internal sealed class ConversationStore
{
    public const int MaxMessages = 500;

    private static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new AppleDateConverter() },
    };

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly Dictionary<string, List<ChatMessage>> _buckets = new(StringComparer.Ordinal);

    public ConversationStore(string directory)
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
    }

    public static double ToAppleSeconds(DateTime utc) => (utc - AppleEpoch).TotalSeconds;

    public static DateTime FromAppleSeconds(double seconds) => AppleEpoch.AddSeconds(seconds);

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

    /// <summary>所有会话键（等于 chats/ 下的文件名，也就是设备 ID）。</summary>
    public IReadOnlyList<string> Keys()
    {
        lock (_gate)
        {
            LoadAllLocked();
            return _buckets.Keys.ToArray();
        }
    }

    public void Append(string key, ChatMessage message)
    {
        if (string.IsNullOrEmpty(key))
        {
            return;
        }

        message.PeerId = key;
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

    /// <summary>
    /// 把老版本的单文件 chat.json 拆成按设备的会话。规则与 macOS 一致：
    /// 只有一份 chats 时，落给唯一的好友；多个好友时按 peerName 匹配数量最多的那台；
    /// 没有任何好友则保持原样不动（下次启动再试），绝不丢数据。
    ///
    /// 多出来的改进：peerName 匹配不到任何好友的消息，按名字各自存一份，
    /// 而不是强行并进第一台设备——否则「发给测试端」的记录会出现在别人的会话里。
    /// </summary>
    public void MigrateLegacy(string legacyChatFile, IReadOnlyList<(string Id, string Name, string? Alias)> friends)
    {
        try
        {
            if (!File.Exists(legacyChatFile))
            {
                return;
            }

            var messages = LoadArray(legacyChatFile);
            if (messages is null || messages.Count == 0)
            {
                File.Move(legacyChatFile, legacyChatFile + ".migrated", overwrite: true);
                return;
            }

            var groups = new Dictionary<string, List<ChatMessage>>(StringComparer.Ordinal);
            var leftovers = new List<ChatMessage>();
            foreach (var message in messages.OrderBy(item => item.Date))
            {
                var match = friends.FirstOrDefault(friend =>
                    string.Equals(friend.Name, message.PeerName, StringComparison.OrdinalIgnoreCase)
                    || (!string.IsNullOrEmpty(friend.Alias)
                        && string.Equals(friend.Alias, message.PeerName, StringComparison.OrdinalIgnoreCase)));
                if (match.Id is null)
                {
                    leftovers.Add(message);
                    continue;
                }

                if (!groups.TryGetValue(match.Id, out var list))
                {
                    list = new List<ChatMessage>();
                    groups[match.Id] = list;
                }

                list.Add(message);
            }

            if (friends.Count == 1 && leftovers.Count > 0)
            {
                // 只有一个好友：剩下的都归它（与 macOS 行为一致）。
                if (!groups.TryGetValue(friends[0].Id, out var list))
                {
                    list = new List<ChatMessage>();
                    groups[friends[0].Id] = list;
                }

                list.AddRange(leftovers);
                leftovers.Clear();
            }

            foreach (var group in leftovers.GroupBy(message => message.PeerName))
            {
                if (string.IsNullOrWhiteSpace(group.Key))
                {
                    continue;
                }

                groups[group.Key] = group.ToList();
            }

            if (groups.Count == 0)
            {
                // 什么都没有可归档的（比如没有任何好友），原文件留着，下次再试。
                return;
            }

            lock (_gate)
            {
                foreach (var pair in groups)
                {
                    foreach (var message in pair.Value)
                    {
                        message.PeerId = pair.Key;
                    }

                    var bucket = BucketLocked(pair.Key);
                    bucket.AddRange(pair.Value);
                    bucket.Sort((left, right) => left.Date.CompareTo(right.Date));
                    if (bucket.Count > MaxMessages)
                    {
                        bucket.RemoveRange(0, bucket.Count - MaxMessages);
                    }

                    SaveLocked(pair.Key, bucket);
                }
            }

            File.Move(legacyChatFile, legacyChatFile + ".migrated", overwrite: true);
        }
        catch (Exception)
        {
            // 迁移失败不动原文件，下次启动重试。
        }
    }

    /// <summary>
    /// 上一版 Windows 用 legacy:&lt;名字&gt; 当会话键、文件名做过 %XX 转义。
    /// 这里把它并回正常结构：能对上好友的并进去，对不上的用它自己的名字当键。
    /// </summary>
    public void MigrateLegacyKeys(IReadOnlyList<(string Id, string Name, string? Alias)> friends)
    {
        try
        {
            if (!Directory.Exists(_directory))
            {
                return;
            }

            foreach (var file in Directory.EnumerateFiles(_directory, "*.json").ToArray())
            {
                var name = Path.GetFileNameWithoutExtension(file);
                var decoded = Unescape(name);
                var name2 = decoded.StartsWith("legacy:", StringComparison.Ordinal)
                    ? decoded["legacy:".Length..]
                    : null;
                if (name2 is null)
                {
                    continue;
                }

                var messages = LoadArray(file);
                if (messages is null)
                {
                    continue;
                }

                var match = friends.FirstOrDefault(friend =>
                    string.Equals(friend.Name, name2, StringComparison.OrdinalIgnoreCase)
                    || (!string.IsNullOrEmpty(friend.Alias)
                        && string.Equals(friend.Alias, name2, StringComparison.OrdinalIgnoreCase)));

                lock (_gate)
                {
                    var targetKey = string.IsNullOrEmpty(match.Id) ? name2 : match.Id;
                    foreach (var message in messages)
                    {
                        message.PeerId = targetKey;
                    }

                    var bucket = BucketLocked(targetKey);
                    bucket.AddRange(messages);
                    bucket.Sort((left, right) => left.Date.CompareTo(right.Date));
                    SaveLocked(targetKey, bucket);
                    _buckets.Remove(decoded);
                }

                TryDeleteRaw(file);
            }
        }
        catch (Exception)
        {
            // 忽略：迁移失败不影响启动。
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
                // 文件名就是会话键，不做解码——要和 FilePathFor 的写法严格对得上。
                var key = Path.GetFileNameWithoutExtension(file);
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

            var list = LoadArray(path);
            if (list is null)
            {
                return;
            }

            foreach (var message in list)
            {
                message.PeerId = key;
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
            var dtos = bucket.Select(ToDto).ToList();
            var json = JsonSerializer.Serialize(dtos, JsonOptions);
            var temp = path + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception)
        {
            // 磁盘异常时忽略，避免打断收发。
        }
    }

    private static List<ChatMessage>? LoadArray(string path)
    {
        try
        {
            var dtos = JsonSerializer.Deserialize<List<MessageDto>>(File.ReadAllText(path), JsonOptions);
            if (dtos is null)
            {
                return null;
            }

            var list = new List<ChatMessage>(dtos.Count);
            foreach (var dto in dtos)
            {
                if (dto is null || string.IsNullOrEmpty(dto.Id))
                {
                    continue;
                }

                list.Add(FromDto(dto));
            }

            return list;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static MessageDto ToDto(ChatMessage message) => new()
    {
        Id = message.Id,
        Direction = message.Direction == MessageDirection.Incoming ? "incoming" : "outgoing",
        PeerName = message.PeerName,
        Date = ToAppleSeconds(message.Date.UtcDateTime),
        Kind = message.Kind == MessageKind.File ? "file" : "text",
        Text = message.Text,
        FileName = message.FileName,
        FilePath = message.FilePath,
        FileSize = message.FileSize,
    };

    private static ChatMessage FromDto(MessageDto dto) => new()
    {
        Id = dto.Id,
        Direction = string.Equals(dto.Direction, "outgoing", StringComparison.Ordinal)
            ? MessageDirection.Outgoing
            : MessageDirection.Incoming,
        PeerName = dto.PeerName ?? string.Empty,
        Date = new DateTimeOffset(FromAppleSeconds(dto.Date), TimeSpan.Zero).ToLocalTime(),
        Kind = string.Equals(dto.Kind, "file", StringComparison.Ordinal) ? MessageKind.File : MessageKind.Text,
        Text = dto.Text,
        FileName = dto.FileName,
        FilePath = dto.FilePath,
        FileSize = dto.FileSize,
    };

    /// <summary>与 macOS 一致：只把路径分隔符换成下划线，其余原样（Windows 再补上非法字符）。</summary>
    private static string Sanitize(string key)
    {
        var builder = new StringBuilder(key.Length + 8);
        foreach (var character in key)
        {
            builder.Append(character switch
            {
                '/' or ':' => '_',
                '\\' or '*' or '?' or '"' or '<' or '>' or '|' => '_',
                _ => character,
            });
        }

        return builder.Length == 0 ? "empty" : builder.ToString();
    }

    /// <summary>上一版把「:」之类写成了 %XX，这里还原成设备名（新格式不再需要）。</summary>
    private static string Unescape(string name)
    {
        if (!name.Contains('%'))
        {
            return name;
        }

        var bytes = new List<byte>(name.Length);
        var text = new StringBuilder(name.Length);
        for (var index = 0; index < name.Length; index++)
        {
            if (name[index] == '%'
                && index + 2 < name.Length
                && int.TryParse(
                    name.AsSpan(index + 1, 2),
                    System.Globalization.NumberStyles.HexNumber,
                    System.Globalization.CultureInfo.InvariantCulture,
                    out var value))
            {
                bytes.Add((byte)value);
                index += 2;
                continue;
            }

            Flush();
            text.Append(name[index]);
        }

        Flush();
        return text.ToString();

        void Flush()
        {
            if (bytes.Count == 0)
            {
                return;
            }

            text.Append(Encoding.UTF8.GetString(bytes.ToArray()));
            bytes.Clear();
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

    private static void TryDeleteRaw(string path)
    {
        try
        {
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

    /// <summary>与 macOS LANMessage 一致的消息结构（可选字段为 nil 时不出现）。</summary>
    private sealed class MessageDto
    {
        public string Id { get; set; } = string.Empty;

        public string? Direction { get; set; }

        public string? PeerName { get; set; }

        public double Date { get; set; }

        public string? Kind { get; set; }

        public string? Text { get; set; }

        public string? FileName { get; set; }

        public string? FilePath { get; set; }

        public long? FileSize { get; set; }
    }
}

/// <summary>
/// 好友名册（friends.json）：与 macOS 的 StoredFriend 一致——数组，
/// 字段 id / name / host / port / lastSeen / alias，lastSeen 同样是 2001 基准的秒数。
/// host/port 一并存下来，设备离线时也能直接重连。
/// </summary>
internal sealed class FriendStore
{
    private static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new AppleDateConverter() },
    };

    private readonly string _filePath;
    private readonly object _gate = new();
    private readonly List<FriendRecord> _friends = new();

    public FriendStore(string filePath)
    {
        _filePath = filePath;
        Load();
        if (_friends.Count == 0)
        {
            ImportLegacyDevices();
        }
    }

    /// <summary>
    /// 上一版 Windows 用的是 devices.json（PascalCase、只有 Id/Name/LastSeenUtc）。
    /// 首次升级时并进 friends.json，原文件改名留底——设备名不能丢，
    /// 否则旧会话就找不回主人了。
    /// </summary>
    private void ImportLegacyDevices()
    {
        var directory = Path.GetDirectoryName(_filePath);
        if (string.IsNullOrEmpty(directory))
        {
            return;
        }

        var legacyPath = Path.Combine(directory, "devices.json");
        if (!File.Exists(legacyPath))
        {
            return;
        }

        try
        {
            var list = JsonSerializer.Deserialize<List<LegacyDeviceDto>>(
                File.ReadAllText(legacyPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (list is null)
            {
                return;
            }

            foreach (var dto in list)
            {
                if (dto is null || string.IsNullOrEmpty(dto.Id))
                {
                    continue;
                }

                var lastSeen = DateTimeOffset.TryParse(dto.LastSeenUtc, out var parsed)
                    ? parsed.UtcDateTime
                    : DateTime.MinValue;
                _friends.Add(new FriendRecord
                {
                    Id = dto.Id,
                    Name = dto.Name ?? string.Empty,
                    LastSeenUtc = lastSeen,
                });
            }

            if (_friends.Count > 0)
            {
                SaveLocked();
            }

            File.Move(legacyPath, legacyPath + ".migrated", overwrite: true);
        }
        catch (Exception)
        {
            // 迁移失败就保持原样，下次启动再试。
        }
    }

    private sealed class LegacyDeviceDto
    {
        public string? Id { get; set; }

        public string? Name { get; set; }

        public string? LastSeenUtc { get; set; }
    }

    public IReadOnlyList<FriendRecord> Snapshot()
    {
        lock (_gate)
        {
            return _friends
                .OrderByDescending(friend => friend.LastSeenUtc)
                .ToArray();
        }
    }

    public FriendRecord? Find(string id)
    {
        lock (_gate)
        {
            return _friends.FirstOrDefault(friend => friend.Id == id);
        }
    }

    /// <summary>更新设备信息（名字、地址、最近在线时间）。名字和地址没变就不写盘。</summary>
    public void Upsert(string id, string name, string host, int port)
    {
        if (string.IsNullOrEmpty(id))
        {
            return;
        }

        lock (_gate)
        {
            var record = _friends.FirstOrDefault(friend => friend.Id == id);
            var changed = false;
            if (record is null)
            {
                record = new FriendRecord { Id = id };
                _friends.Add(record);
                changed = true;
            }

            if (!string.IsNullOrEmpty(name) && !string.Equals(record.Name, name, StringComparison.Ordinal))
            {
                record.Name = name;
                changed = true;
            }

            if (!string.IsNullOrEmpty(host) && !string.Equals(record.Host, host, StringComparison.Ordinal))
            {
                record.Host = host;
                changed = true;
            }

            if (port > 0 && record.Port != port)
            {
                record.Port = port;
                changed = true;
            }

            record.LastSeenUtc = DateTime.UtcNow;
            if (changed)
            {
                SaveLocked();
            }
        }
    }

    public void SetAlias(string id, string? alias)
    {
        lock (_gate)
        {
            var record = _friends.FirstOrDefault(friend => friend.Id == id);
            if (record is null)
            {
                return;
            }

            var trimmed = alias?.Trim();
            var next = string.IsNullOrEmpty(trimmed) ? null : trimmed;
            if (string.Equals(record.Alias, next, StringComparison.Ordinal))
            {
                return;
            }

            record.Alias = next;
            SaveLocked();
        }
    }

    public bool ClearAliases()
    {
        lock (_gate)
        {
            var any = false;
            foreach (var record in _friends)
            {
                if (record.Alias is not null)
                {
                    record.Alias = null;
                    any = true;
                }
            }

            if (any)
            {
                SaveLocked();
            }

            return any;
        }
    }

    public void Remove(string id)
    {
        lock (_gate)
        {
            if (_friends.RemoveAll(friend => friend.Id == id) > 0)
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

            var list = JsonSerializer.Deserialize<List<FriendDto>>(File.ReadAllText(_filePath), JsonOptions);
            if (list is null)
            {
                return;
            }

            foreach (var dto in list)
            {
                if (dto is null || string.IsNullOrEmpty(dto.Id))
                {
                    continue;
                }

                _friends.Add(new FriendRecord
                {
                    Id = dto.Id,
                    Name = dto.Name ?? string.Empty,
                    Host = dto.Host ?? string.Empty,
                    Port = dto.Port,
                    LastSeenUtc = AppleEpoch.AddSeconds(dto.LastSeen),
                    Alias = string.IsNullOrWhiteSpace(dto.Alias) ? null : dto.Alias,
                });
            }
        }
        catch (Exception)
        {
            _friends.Clear();
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

            var dtos = _friends
                .OrderBy(friend => friend.Name, StringComparer.CurrentCulture)
                .Select(friend => new FriendDto
                {
                    Id = friend.Id,
                    Name = friend.Name,
                    Host = friend.Host,
                    Port = friend.Port,
                    LastSeen = (friend.LastSeenUtc - AppleEpoch).TotalSeconds,
                    Alias = friend.Alias,
                })
                .ToArray();

            var json = JsonSerializer.Serialize(dtos, JsonOptions);
            var temp = _filePath + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, _filePath, overwrite: true);
        }
        catch (Exception)
        {
            // 忽略。
        }
    }

    /// <summary>与 macOS StoredFriend 一致的字段结构。</summary>
    private sealed class FriendDto
    {
        public string Id { get; set; } = string.Empty;

        public string? Name { get; set; }

        public string? Host { get; set; }

        public int Port { get; set; }

        public double LastSeen { get; set; }

        public string? Alias { get; set; }
    }
}

/// <summary>名册里的一台设备（内存模型）。</summary>
internal sealed class FriendRecord
{
    public string Id { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public string Host { get; set; } = string.Empty;

    public int Port { get; set; }

    public DateTime LastSeenUtc { get; set; }

    public string? Alias { get; set; }

    /// <summary>显示名：有别名优先别名，与 macOS 一致。</summary>
    public string DisplayName => string.IsNullOrWhiteSpace(Alias) ? Name : Alias;
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