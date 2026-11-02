using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ADBTypeLink.Core;

/// <summary>
/// 一条 TCP 连接上的帧读写（§3）：4 字节大端长度 + UTF-8 JSON 正文。
/// 读写都按 30 秒超时处理，异常一律转成 false / null，由调用方决定提示。
/// </summary>
internal sealed class TcpConnection : IAsyncDisposable
{
    private readonly Socket _socket;
    private readonly NetworkStream _stream;

    public TcpConnection(Socket socket)
    {
        _socket = socket;
        _socket.NoDelay = true;
        _stream = new NetworkStream(socket, ownsSocket: false);
    }

    public EndPoint? RemoteEndPoint => _socket.RemoteEndPoint;

    /// <summary>读一帧 JSON 对象；连接断开、超时或超长都返回 null。</summary>
    public async Task<JsonElement?> ReadJsonAsync(CancellationToken cancellationToken)
    {
        var header = new byte[4];
        if (!await ReadExactAsync(header.AsMemory(), cancellationToken).ConfigureAwait(false))
        {
            return null;
        }

        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length <= 0 || length > LinkProtocol.MaxFrameBytes)
        {
            return null;
        }

        var body = new byte[length];
        if (!await ReadExactAsync(body.AsMemory(), cancellationToken).ConfigureAwait(false))
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
        return await WriteAsync(frame.AsMemory(), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>循环读满指定字节数。</summary>
    public async Task<bool> ReadExactAsync(Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            int read;
            try
            {
                using var timeout = CreateTimeout(cancellationToken);
                read = await _stream.ReadAsync(buffer[offset..], timeout.Token).ConfigureAwait(false);
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

    /// <summary>写满整个缓冲区。</summary>
    public async Task<bool> WriteAsync(ReadOnlyMemory<byte> data, CancellationToken cancellationToken)
    {
        try
        {
            using var timeout = CreateTimeout(cancellationToken);
            await _stream.WriteAsync(data, timeout.Token).ConfigureAwait(false);
            await _stream.FlushAsync(timeout.Token).ConfigureAwait(false);
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

    private static CancellationTokenSource CreateTimeout(CancellationToken cancellationToken)
    {
        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(LinkProtocol.IoTimeout);
        return cts;
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
