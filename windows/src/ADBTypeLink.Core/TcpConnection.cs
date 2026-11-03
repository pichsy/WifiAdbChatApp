using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ADBTypeLink.Core;

/// <summary>
/// 一条 TCP 连接上的帧读写（§3）：4 字节大端长度 + UTF-8 JSON 正文。
/// <para>
/// 超时分成两级：控制帧（hello / text / ok / bye）走 <see cref="LinkProtocol.IoTimeout"/>，
/// 文件数据块走 <see cref="LinkProtocol.FileIoTimeout"/>。原来两者共用一个 30 秒超时，
/// 在慢速 Wi-Fi 上传大文件时，只要单个 256 KiB 块没在 30 秒内写完就会整条连接报废。
/// </para>
/// </summary>
internal sealed class TcpConnection : IAsyncDisposable
{
    private readonly Socket _socket;
    private readonly NetworkStream _stream;
    private readonly TimeSpan _controlTimeout;
    private readonly TimeSpan _dataTimeout;

    public TcpConnection(Socket socket)
        : this(socket, LinkProtocol.IoTimeout, LinkProtocol.FileIoTimeout)
    {
    }

    public TcpConnection(Socket socket, TimeSpan controlTimeout, TimeSpan dataTimeout)
    {
        _socket = socket;
        _socket.NoDelay = true;
        EnableKeepAlive(_socket);
        _stream = new NetworkStream(socket, ownsSocket: false);
        _controlTimeout = controlTimeout;
        _dataTimeout = dataTimeout;
    }

    public EndPoint? RemoteEndPoint => _socket.RemoteEndPoint;

    /// <summary>读一帧 JSON 对象；连接断开、超时或超长都返回 null。</summary>
    public async Task<JsonElement?> ReadJsonAsync(CancellationToken cancellationToken)
    {
        var header = new byte[4];
        if (!await ReadExactCoreAsync(header.AsMemory(), _controlTimeout, cancellationToken).ConfigureAwait(false))
        {
            return null;
        }

        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length <= 0 || length > LinkProtocol.MaxFrameBytes)
        {
            return null;
        }

        var body = new byte[length];
        if (!await ReadExactCoreAsync(body.AsMemory(), _dataTimeout, cancellationToken).ConfigureAwait(false))
        {
            return null;
        }

        return LinkProtocol.ParseObject(body);
    }

    /// <summary>写一帧 JSON 对象；失败返回 false。</summary>
    public async Task<bool> WriteJsonAsync(JsonObject message, CancellationToken cancellationToken)
    {
        byte[] body;
        try
        {
            body = LinkProtocol.Serialize(message);
        }
        catch (Exception)
        {
            return false;
        }

        if (body.Length == 0 || body.Length > LinkProtocol.MaxFrameBytes)
        {
            return false;
        }

        var frame = new byte[4 + body.Length];
        BinaryPrimitives.WriteInt32BigEndian(frame, body.Length);
        body.CopyTo(frame, 4);
        return await WriteCoreAsync(frame.AsMemory(), _controlTimeout, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>循环读满指定字节数（文件数据用长超时）。</summary>
    public Task<bool> ReadExactAsync(Memory<byte> buffer, CancellationToken cancellationToken) =>
        ReadExactCoreAsync(buffer, _dataTimeout, cancellationToken);

    /// <summary>写满整个缓冲区（文件数据用长超时）。</summary>
    public Task<bool> WriteAsync(ReadOnlyMemory<byte> data, CancellationToken cancellationToken) =>
        WriteCoreAsync(data, _dataTimeout, cancellationToken);

    private async Task<bool> ReadExactCoreAsync(Memory<byte> buffer, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            int read;
            try
            {
                using var timeoutSource = CreateTimeout(cancellationToken, timeout);
                read = await _stream.ReadAsync(buffer[offset..], timeoutSource.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return false;
            }
            catch (IOException)
            {
                return false;
            }
            catch (ObjectDisposedException)
            {
                return false;
            }

            if (read <= 0)
            {
                return false;
            }

            offset += read;
        }

        return true;
    }

    private async Task<bool> WriteCoreAsync(ReadOnlyMemory<byte> data, TimeSpan timeout, CancellationToken cancellationToken)
    {
        try
        {
            using var timeoutSource = CreateTimeout(cancellationToken, timeout);
            await _stream.WriteAsync(data, timeoutSource.Token).ConfigureAwait(false);
            await _stream.FlushAsync(timeoutSource.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch (IOException)
        {
            return false;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
    }

    private static CancellationTokenSource CreateTimeout(CancellationToken cancellationToken, TimeSpan timeout)
    {
        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(timeout);
        return cts;
    }

    /// <summary>
    /// 打开 TCP keepalive：Wi-Fi 掉线属于「半开连接」，不设 keepalive 时
    /// 本地 socket 察觉不到对端已经消失，只能干等到读写超时。
    /// </summary>
    private static void EnableKeepAlive(Socket socket)
    {
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 15);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 5);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
        }
        catch (Exception)
        {
            // 个别平台不支持这组选项，退化成系统默认 keepalive 也能用。
        }
    }

    public ValueTask DisposeAsync()
    {
        try
        {
            _stream.Dispose();
        }
        catch (Exception)
        {
            // 忽略关闭异常。
        }

        try
        {
            _socket.Dispose();
        }
        catch (Exception)
        {
            // 忽略关闭异常。
        }

        return ValueTask.CompletedTask;
    }
}
