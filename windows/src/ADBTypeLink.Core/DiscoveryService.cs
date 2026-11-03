using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace ADBTypeLink.Core;

/// <summary>
/// UDP 设备发现（§2）：每 2 秒向 255.255.255.255 与 127.0.0.1 的 52730 端口广播本机信息，
/// 同时监听 0.0.0.0:52730 收集其它设备的广播。
/// </summary>
internal sealed class DiscoveryService : IDisposable
{
    private readonly string _deviceId;
    private readonly string _deviceName;
    private Action<string>? _log;
    private readonly object _gate = new();

    private Socket? _receiveSocket;
    private Socket? _sendSocket;
    private Timer? _announceTimer;
    private CancellationTokenSource? _cts;
    private int _tcpPort;
    private bool _started;

    /// <summary>各网卡对应的子网定向广播地址（见 <see cref="GetSubnetBroadcasts"/>）。</summary>
    private List<IPAddress> _subnetBroadcasts = new();

    private DateTime _broadcastsRefreshedUtc = DateTime.MinValue;

    /// <summary>网卡地址变化不快，10 秒刷新一次就够。</summary>
    private static readonly TimeSpan BroadcastRefreshInterval = TimeSpan.FromSeconds(10);

    public DiscoveryService(string deviceId, string deviceName, Action<string>? log = null)
    {
        _deviceId = deviceId;
        _deviceName = deviceName;
        _log = log;
    }

    /// <summary>运行期替换日志出口（应用启动后再挂文件日志时用）。</summary>
    public void SetLog(Action<string>? log) => _log = log;

    /// <summary>收到一条合法广播。</summary>
    public event EventHandler<LinkPeer>? PeerSeen;

    /// <summary>发现服务无法启动（例如端口被占用）。</summary>
    public event EventHandler<string>? Failed;

    public void Start(int tcpPort)
    {
        lock (_gate)
        {
            if (_started)
            {
                return;
            }

            _started = true;
            _tcpPort = tcpPort;
            _cts = new CancellationTokenSource();
        }

        try
        {
            _receiveSocket = CreateReceiveSocket();
        }
        catch (Exception ex)
        {
            _log?.Invoke($"bound discovery failed: {ex.Message}");
            Failed?.Invoke(this, $"端口 {LinkProtocol.DiscoveryPort} 被占用，无法启动局域网发现");
            return;
        }

        try
        {
            _sendSocket = CreateSendSocket();
        }
        catch (Exception ex)
        {
            _log?.Invoke($"discovery send socket failed: {ex.Message}");
        }

        _ = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        _announceTimer = new Timer(_ => Announce(), null, TimeSpan.FromMilliseconds(200), LinkProtocol.AnnounceInterval);
    }

    private static Socket CreateReceiveSocket()
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try
        {
            if (OperatingSystem.IsWindows())
            {
                // Windows 上关掉独占模式 + 打开重用，允许多个实例同时监听同一端口。
                socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ExclusiveAddressUse, false);
            }

            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            TrySetReusePort(socket);
            socket.Bind(new IPEndPoint(IPAddress.Any, LinkProtocol.DiscoveryPort));
            return socket;
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    /// <summary>
    /// .NET 没有公开 SO_REUSEPORT，用原始 socket 选项设置，让 macOS / Linux 上同一端口能被多个进程绑定。
    /// </summary>
    private static void TrySetReusePort(Socket socket)
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }

        try
        {
            var enable = BitConverter.GetBytes(1);
            if (OperatingSystem.IsMacOS() || OperatingSystem.IsFreeBSD())
            {
                // Darwin: SOL_SOCKET = 0xffff, SO_REUSEPORT = 0x0200
                socket.SetRawSocketOption(0xffff, 0x0200, enable);
            }
            else
            {
                // Linux: SOL_SOCKET = 1, SO_REUSEPORT = 15
                socket.SetRawSocketOption(1, 15, enable);
            }
        }
        catch (Exception ex)
        {
            _ = ex;
            // 设置失败也能跑，只是同机多实例可能收不到广播。
        }
    }

    private static Socket CreateSendSocket()
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
        {
            EnableBroadcast = true,
        };
        socket.Bind(new IPEndPoint(IPAddress.Any, 0));
        return socket;
    }

    private void Announce()
    {
        var socket = _sendSocket;
        if (socket is null || _tcpPort <= 0)
        {
            return;
        }

        byte[] payload;
        try
        {
            payload = LinkProtocol.Serialize(LinkMessages.Announce(_deviceId, _deviceName, _tcpPort));
        }
        catch (Exception)
        {
            return;
        }

        SendTo(socket, payload, new IPEndPoint(IPAddress.Broadcast, LinkProtocol.DiscoveryPort));
        // 回环广播：同一台电脑跑两个实例（联调 / 冒烟测试）也能互相发现。
        SendTo(socket, payload, new IPEndPoint(IPAddress.Loopback, LinkProtocol.DiscoveryPort));

        // 关键补充：255.255.255.255 只从「首选网卡」发出。机器上只要装了 Docker / VMware /
        // VPN / Hyper-V 虚拟网卡，广播就可能走错网卡，Wi-Fi 上的对端一个包都收不到，
        // 表现就是设备列表里的设备周期性消失。这里再按每块网卡各发一份子网定向广播。
        foreach (var target in GetSubnetBroadcasts())
        {
            SendTo(socket, payload, new IPEndPoint(target, LinkProtocol.DiscoveryPort));
        }
    }

    /// <summary>
    /// 枚举所有已启用网卡的 IPv4 子网定向广播地址（例如 192.168.1.255）。
    /// 结果缓存 10 秒，避免每 2 秒的广播都去查一遍网卡。
    /// </summary>
    private IReadOnlyList<IPAddress> GetSubnetBroadcasts()
    {
        lock (_gate)
        {
            if (DateTime.UtcNow - _broadcastsRefreshedUtc < BroadcastRefreshInterval)
            {
                return _subnetBroadcasts;
            }

            _broadcastsRefreshedUtc = DateTime.UtcNow;
        }

        var targets = new List<IPAddress>();
        try
        {
            foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (network.OperationalStatus != OperationalStatus.Up)
                {
                    continue;
                }

                if (network.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                IPInterfaceProperties properties;
                try
                {
                    properties = network.GetIPProperties();
                }
                catch (Exception)
                {
                    continue;
                }

                foreach (var unicast in properties.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork)
                    {
                        continue;
                    }

                    if (IPAddress.IsLoopback(unicast.Address))
                    {
                        continue;
                    }

                    var mask = unicast.IPv4Mask;
                    if (mask is null)
                    {
                        continue;
                    }

                    var addressBytes = unicast.Address.GetAddressBytes();
                    var maskBytes = mask.GetAddressBytes();
                    if (addressBytes.Length != 4 || maskBytes.Length != 4)
                    {
                        continue;
                    }

                    var broadcastBytes = new byte[4];
                    for (var index = 0; index < 4; index++)
                    {
                        broadcastBytes[index] = (byte)(addressBytes[index] | ~maskBytes[index]);
                    }

                    var broadcast = new IPAddress(broadcastBytes);
                    // 点对点网卡（掩码 255.255.255.255）算出来的广播地址就是它自己，发过去没意义。
                    if (broadcast.Equals(unicast.Address) || broadcast.Equals(IPAddress.Broadcast))
                    {
                        continue;
                    }

                    targets.Add(broadcast);
                }
            }
        }
        catch (Exception ex)
        {
            _log?.Invoke($"enumerate interfaces failed: {ex.Message}");
        }

        lock (_gate)
        {
            _subnetBroadcasts = targets;
        }

        return targets;
    }

    private void SendTo(Socket socket, byte[] payload, IPEndPoint endpoint)
    {
        try
        {
            socket.SendTo(payload, endpoint);
        }
        catch (SocketException ex)
        {
            _log?.Invoke($"announce to {endpoint} failed: {ex.SocketErrorCode}");
        }
        catch (ObjectDisposedException)
        {
            // 正在关闭。
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        EndPoint remote = new IPEndPoint(IPAddress.Any, 0);

        while (!cancellationToken.IsCancellationRequested)
        {
            SocketReceiveFromResult result;
            try
            {
                result = await _receiveSocket!
                    .ReceiveFromAsync(buffer.AsMemory(), SocketFlags.None, remote, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            catch (SocketException ex)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                _log?.Invoke($"discovery receive failed: {ex.SocketErrorCode}");
                try
                {
                    await Task.Delay(100, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }

                continue;
            }

            if (result.ReceivedBytes <= 0 || result.RemoteEndPoint is not IPEndPoint from)
            {
                continue;
            }

            HandlePacket(buffer.AsSpan(0, result.ReceivedBytes).ToArray(), from);
        }
    }

    private void HandlePacket(byte[] payload, IPEndPoint from)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            return;
        }

        if (LinkProtocol.GetString(root, "app") != LinkProtocol.AppTag)
        {
            return;
        }

        var peerId = LinkProtocol.GetString(root, "id");
        var name = LinkProtocol.GetString(root, "name");
        var port = LinkProtocol.GetInt64(root, "port");
        if (string.IsNullOrEmpty(peerId) || peerId == _deviceId || string.IsNullOrEmpty(name))
        {
            return;
        }

        if (port is null or <= 0 or > 65535)
        {
            return;
        }

        var version = LinkProtocol.GetInt64(root, "v");
        if (version != LinkProtocol.ProtocolVersion)
        {
            // 向前兼容：版本不同仍接受，只记录日志。
            _log?.Invoke($"peer {name} uses protocol v{version?.ToString() ?? "?"}");
        }

        var peer = new LinkPeer
        {
            Id = peerId,
            Name = name,
            Host = from.Address.ToString(),
            Port = (int)port.Value,
            LastSeenUtc = DateTime.UtcNow,
        };

        PeerSeen?.Invoke(this, peer);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (!_started)
            {
                return;
            }

            _started = false;
        }

        try
        {
            _announceTimer?.Dispose();
        }
        catch (Exception)
        {
            // 忽略关闭异常。
        }

        _announceTimer = null;

        try
        {
            _cts?.Cancel();
        }
        catch (Exception)
        {
            // 忽略关闭异常。
        }

        _cts?.Dispose();
        _cts = null;

        _receiveSocket?.Dispose();
        _receiveSocket = null;
        _sendSocket?.Dispose();
        _sendSocket = null;
    }
}
