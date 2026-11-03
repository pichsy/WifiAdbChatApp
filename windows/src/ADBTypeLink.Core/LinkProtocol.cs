using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ADBTypeLink.Core;

/// <summary>协议常量与帧编解码（与 macOS 端 LANTransfer.swift 位对位兼容）。</summary>
public static class LinkProtocol
{
    /// <summary>广播报文里的应用标识，用于过滤其它程序的 UDP 报文。</summary>
    public const string AppTag = "ADBTypeLink";

    /// <summary>协议版本，当前为 1。</summary>
    public const int ProtocolVersion = 1;

    /// <summary>设备发现 UDP 端口（固定）。</summary>
    public const int DiscoveryPort = 52730;

    /// <summary>单帧 JSON 上限 16 MiB。</summary>
    public const int MaxFrameBytes = 16 * 1024 * 1024;

    /// <summary>单次 TCP 连接尝试的超时（原来是 6 秒，抖一下就失败）。</summary>
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(2);

    /// <summary>一次发送动作里建立连接的总预算，含全部重试，超过就不再纠缠。</summary>
    public static readonly TimeSpan ConnectBudget = TimeSpan.FromSeconds(4);

    /// <summary>建立连接的最大尝试次数（含首次）。</summary>
    public const int ConnectAttempts = 4;

    /// <summary>握手/内容阶段整体重连的轮数：断了自动重连再试一次。</summary>
    public const int SendRounds = 2;

    /// <summary>已建立连接上控制帧（hello / text / ok / bye）的读写超时。</summary>
    public static readonly TimeSpan IoTimeout = TimeSpan.FromSeconds(15);

    /// <summary>文件数据块的读写超时：慢速 Wi-Fi 传大文件不能按控制帧的标准算。</summary>
    public static readonly TimeSpan FileIoTimeout = TimeSpan.FromSeconds(90);

    /// <summary>文件分块 256 KiB。</summary>
    public const int FileChunkBytes = 256 * 1024;

    /// <summary>广播间隔 2 秒。</summary>
    public static readonly TimeSpan AnnounceInterval = TimeSpan.FromSeconds(2);

    /// <summary>
    /// 设备多久没有广播才判定为掉线。原来是 8 秒——Wi-Fi 一次休眠/漫游/信道切换
    /// 就会让设备从列表里凭空消失，现在放宽到 18 秒，容忍 9 次连续丢包。
    /// </summary>
    // 原来 18 秒没广播就从列表里删掉，Wi-Fi 抖一下就「设备凭空消失」，
    // 用户既选不中也连不回来。现在保留 60 秒，在线状态改由界面上的
    // 「在线 / 连接中断，正在重连…」和 TCP 探活来体现。
    public static readonly TimeSpan PeerTimeout = TimeSpan.FromSeconds(60);

    /// <summary>
    /// 单个文件最多尝试几次。实测大文件会传到 97% 被对端断开（Wi-Fi 抖动 /
    /// 对端收完就关连接），断一次就整批失败太脆，按「文件」粒度重连重传。
    /// </summary>
    public const int FileAttempts = 3;

    /// <summary>同机实例心跳文件的过期时间（每 2 秒刷新）。</summary>
    public static readonly TimeSpan InstanceTimeout = TimeSpan.FromSeconds(8);

    /// <summary>清理过期设备的间隔 3 秒。</summary>
    public static readonly TimeSpan PruneInterval = TimeSpan.FromSeconds(3);

    /// <summary>JSON 序列化选项：中文不转义，与 macOS 的 UTF-8 JSON 保持字节友好。</summary>
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = false,
    };

    internal static byte[] Serialize(JsonNode node) =>
        Encoding.UTF8.GetBytes(node.ToJsonString(JsonOptions));

    /// <summary>把 JSON 帧正文解析成对象；不是合法 JSON 对象时返回 null。</summary>
    internal static JsonElement? ParseObject(byte[] bytes)
    {
        try
        {
            using var doc = JsonDocument.Parse(bytes);
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            // Clone 之后元素不再依赖 JsonDocument 的生命周期。
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static string? GetString(JsonElement element, string name)
    {
        return element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    internal static long? GetInt64(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number))
        {
            return number;
        }

        return null;
    }
}

/// <summary>各类协议消息的构造器，字段与规格 §2 / §5 完全一致。</summary>
internal static class LinkMessages
{
    public static JsonObject Announce(string deviceId, string deviceName, int port) => new()
    {
        ["app"] = LinkProtocol.AppTag,
        ["v"] = LinkProtocol.ProtocolVersion,
        ["id"] = deviceId,
        ["name"] = deviceName,
        ["port"] = port,
    };

    public static JsonObject Hello(string deviceId, string deviceName, string? code)
    {
        var hello = new JsonObject
        {
            ["app"] = LinkProtocol.AppTag,
            ["v"] = LinkProtocol.ProtocolVersion,
            ["id"] = deviceId,
            ["name"] = deviceName,
        };
        if (!string.IsNullOrEmpty(code))
        {
            hello["code"] = code;
        }

        return hello;
    }

    public static JsonObject HelloOk(string deviceName, string deviceId) => new()
    {
        ["type"] = "hello_ok",
        ["name"] = deviceName,
        ["id"] = deviceId,
    };

    public static JsonObject PairRequired(string deviceName) => new()
    {
        ["type"] = "pair_required",
        ["name"] = deviceName,
    };

    public static JsonObject Error(string message) => new()
    {
        ["type"] = "error",
        ["message"] = message,
    };

    public static JsonObject Text(string text) => new()
    {
        ["type"] = "text",
        ["text"] = text,
    };

    public static JsonObject File(string name, long size) => new()
    {
        ["type"] = "file",
        ["name"] = name,
        ["size"] = size,
    };

    public static JsonObject Ok() => new() { ["type"] = "ok" };

    public static JsonObject Bye() => new() { ["type"] = "bye" };
}
