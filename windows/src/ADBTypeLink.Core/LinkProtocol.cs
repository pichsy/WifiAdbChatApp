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

    /// <summary>TCP 连接超时 6 秒。</summary>
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(6);

    /// <summary>已建立连接上的读写超时 30 秒。</summary>
    public static readonly TimeSpan IoTimeout = TimeSpan.FromSeconds(30);

    /// <summary>文件分块 256 KiB。</summary>
    public const int FileChunkBytes = 256 * 1024;

    /// <summary>广播间隔 2 秒。</summary>
    public static readonly TimeSpan AnnounceInterval = TimeSpan.FromSeconds(2);

    /// <summary>设备 8 秒没有广播就从附近设备列表移除。</summary>
    public static readonly TimeSpan PeerTimeout = TimeSpan.FromSeconds(8);

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
