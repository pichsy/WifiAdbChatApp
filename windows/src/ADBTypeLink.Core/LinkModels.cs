using System.Text.Json.Serialization;

namespace ADBTypeLink.Core;

/// <summary>附近设备（由 UDP 广播维护）。</summary>
public sealed class LinkPeer
{
    /// <summary>设备唯一 ID（对端持久化的 UUID）。</summary>
    public string Id { get; init; } = string.Empty;

    /// <summary>展示名。</summary>
    public string Name { get; init; } = string.Empty;

    /// <summary>来源 IP（取自广播报文的实际来源地址，而不是 payload）。</summary>
    public string Host { get; init; } = string.Empty;

    /// <summary>对端 TCP 监听端口。</summary>
    public int Port { get; init; }

    /// <summary>最后一次收到广播的时间（UTC）。</summary>
    public DateTime LastSeenUtc { get; init; }

    public LinkPeer WithSeen(DateTime lastSeenUtc) => new()
    {
        Id = Id,
        Name = Name,
        Host = Host,
        Port = Port,
        LastSeenUtc = lastSeenUtc,
    };
}

public enum MessageDirection
{
    Incoming,
    Outgoing,
}

public enum MessageKind
{
    Text,
    File,
}

/// <summary>
/// 聊天记录条目。字段与 macOS 端 LANMessage 一致（§8），持久化到 chat.json。
/// </summary>
public sealed class ChatMessage
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("direction")]
    public MessageDirection Direction { get; set; }

    [JsonPropertyName("peerName")]
    public string PeerName { get; set; } = string.Empty;

    [JsonPropertyName("date")]
    public DateTimeOffset Date { get; set; } = DateTimeOffset.Now;

    [JsonPropertyName("kind")]
    public MessageKind Kind { get; set; }

    [JsonPropertyName("text")]
    public string? Text { get; set; }

    [JsonPropertyName("fileName")]
    public string? FileName { get; set; }

    [JsonPropertyName("filePath")]
    public string? FilePath { get; set; }

    [JsonPropertyName("fileSize")]
    public long? FileSize { get; set; }
}

public enum LinkStatusKind
{
    Idle,
    Success,
    Failure,
}

/// <summary>状态栏文案（与 macOS 端文案保持一致）。</summary>
public sealed record LinkStatus(LinkStatusKind Kind, string Text);

public enum SendStatus
{
    Ok,
    NeedsPairing,
    Failure,
}

/// <summary>一次发送动作的结果。</summary>
public sealed class SendOutcome
{
    public required SendStatus Status { get; init; }

    /// <summary>对端展示名（需要配对时用）。</summary>
    public string PeerName { get; init; } = string.Empty;

    /// <summary>失败原因或成功文案。</summary>
    public string? Message { get; init; }

    public bool IsOk => Status == SendStatus.Ok;

    public static SendOutcome Ok(string peerName, string message) => new()
    {
        Status = SendStatus.Ok,
        PeerName = peerName,
        Message = message,
    };

    public static SendOutcome NeedsPairing(string peerName) => new()
    {
        Status = SendStatus.NeedsPairing,
        PeerName = peerName,
    };

    public static SendOutcome Failure(string message) => new()
    {
        Status = SendStatus.Failure,
        Message = message,
    };
}

/// <summary>发送进度（0~1 与当前标签）。</summary>
public sealed record SendProgress(double Fraction, string Label);

/// <summary>对方正在请求配对（还没输入本机配对码）。</summary>
public sealed class PairRequestEventArgs : EventArgs
{
    public PairRequestEventArgs(string peerId, string peerName)
    {
        PeerId = peerId;
        PeerName = peerName;
    }

    public string PeerId { get; }

    public string PeerName { get; }
}

/// <summary>启动参数：测试和 App 都要用不同的数据目录。</summary>
public sealed class LinkEngineOptions
{
    /// <summary>数据目录；默认按平台选择（Windows 为 %APPDATA%\\ADBTypeLink）。</summary>
    public string? DataDirectory { get; set; }

    /// <summary>接收目录；默认为「下载/ADBType 接收」。</summary>
    public string? ReceiveDirectory { get; set; }

    /// <summary>设备展示名；默认取主机名。</summary>
    public string? DeviceName { get; set; }

    /// <summary>设备 ID；默认读取 / 生成设备文件。</summary>
    public string? DeviceId { get; set; }

    /// <summary>固定配对码（测试用）；默认随机生成 6 位。</summary>
    public string? PairingCode { get; set; }

    /// <summary>诊断日志回调。</summary>
    public Action<string>? Log { get; set; }
}
