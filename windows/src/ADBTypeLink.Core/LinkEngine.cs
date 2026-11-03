using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ADBTypeLink.Core;

/// <summary>
/// 局域网传输引擎：UDP 发现 + TCP 握手/配对 + 文字/文件收发 + 本机状态持久化。
/// 协议细节见 docs/LAN-transfer-spec.md，与 macOS 端 macos/Sources/LANTransfer.swift 互通。
/// </summary>
public sealed class LinkEngine : IAsyncDisposable
{
    private readonly LinkPaths _paths;
    private readonly PairedStore _paired;
    private readonly ConversationStore _chats;
    private readonly DeviceStore _devices;
    private readonly SettingsStore _settings;
    private readonly object _peersGate = new();
    private readonly Dictionary<string, LinkPeer> _peers = new(StringComparer.Ordinal);
    private Action<string>? _log;

    private TcpListener? _listener;
    private Task? _acceptTask;
    private DiscoveryService? _discovery;
    private LocalInstanceRegistry? _localRegistry;
    private Timer? _pruneTimer;
    private CancellationTokenSource? _cts;
    private int _started;
    private volatile string _pairingCode;
    private volatile string _receiveDir;
    private volatile LinkStatus _status = new(LinkStatusKind.Idle, "正在搜索局域网内的设备…");

    public LinkEngine(LinkEngineOptions? options = null)
    {
        Options = options ?? new LinkEngineOptions();
        _log = Options.Log;
        _paths = new LinkPaths(Options.DataDirectory ?? LinkPaths.DefaultDataDirectory());
        DeviceId = Options.DeviceId ?? DeviceIdStore.LoadOrCreate(_paths.DeviceIdFile);
        DeviceName = Options.DeviceName ?? DeviceNameProvider.GetDefaultName();
        _paired = new PairedStore(_paths.PairedFile);
        _chats = new ConversationStore(_paths.ChatsDirectory, _paths.ChatFile);
        _devices = new DeviceStore(_paths.KnownDevicesFile);
        _settings = new SettingsStore(_paths.SettingsFile);
        _settings.Load();
        _receiveDir = Options.ReceiveDirectory ?? _settings.ReceiveDir ?? LinkPaths.DefaultReceiveDirectory();
        _pairingCode = Options.PairingCode ?? GeneratePairingCode();
    }

    public LinkEngineOptions Options { get; }

    /// <summary>
    /// 运行日志出口。应用启动后可以再设一遍（构造时的 Options.Log 只是初始值），
    /// 出问题时把日志写入文件，用户把文件发回来就能定位。
    /// </summary>
    public Action<string>? LogSink
    {
        get => _log;
        set
        {
            _log = value;
            _discovery?.SetLog(value);
            _localRegistry?.SetLog(value);
        }
    }

    /// <summary>本机设备 ID（持久化，重启不变）。</summary>
    public string DeviceId { get; }

    /// <summary>本机展示名。</summary>
    public string DeviceName { get; }

    /// <summary>本机 6 位配对码。</summary>
    public string PairingCode => _pairingCode;

    /// <summary>接收目录。</summary>
    public string ReceiveDir => _receiveDir;

    /// <summary>TCP 监听端口（随广播一起发布）。</summary>
    public int ListenPort { get; private set; }

    /// <summary>数据目录（Windows 为 %APPDATA%\\ADBTypeLink）。</summary>
    public string DataDirectory => _paths.DataDirectory;

    public bool IsRunning => Volatile.Read(ref _started) == 1;

    public int PairedCount => _paired.Count;

    public LinkStatus Status => _status;

    /// <summary>
    /// 某台设备的会话快照。每台设备一份独立缓存，切设备只换数据源，
    /// 跟别的设备互不影响。
    /// </summary>
    public IReadOnlyList<ChatMessage> GetConversation(string peerId, string peerName) =>
        _chats.SnapshotForPeer(peerId, peerName);

    /// <summary>这台设备有没有留下过记录（决定它是否留在列表里）。</summary>
    public bool HasConversation(string peerId, string peerName) =>
        _chats.SnapshotForPeer(peerId, peerName).Count > 0;

    /// <summary>
    /// 记住过的设备：配对过的、有过来往的。即使此刻离线也要显示，
    /// 只是状态不同，历史记录照常可看。
    /// </summary>
    public IReadOnlyList<KnownDevice> KnownDevices
    {
        get
        {
            var known = new List<KnownDevice>();
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var record in _devices.Snapshot())
            {
                names.Add(record.Name);
                known.Add(new KnownDevice
                {
                    Id = record.Id,
                    Name = record.Name,
                    LastSeenUtc = record.LastSeenUtc,
                });
            }

            // 已经在广播里出现的同名设备，它自己会带着旧记录展示
            //（GetConversation 按名字合并），不能再补一台重复的设备。
            foreach (var peer in Peers)
            {
                names.Add(peer.Name);
            }

            // 旧版本遗留的会话（没有设备 ID），按名字补成一台「离线设备」，
            // 这样升级前收到的消息不会从列表里凭空消失。
            foreach (var name in _chats.LegacyNames())
            {
                if (string.IsNullOrWhiteSpace(name) || !names.Add(name))
                {
                    continue;
                }

                var messages = _chats.Snapshot(ConversationStore.LegacyPrefix + name);
                known.Add(new KnownDevice
                {
                    Id = ConversationStore.LegacyPrefix + name,
                    Name = name,
                    LastSeenUtc = messages.Count == 0
                        ? DateTime.UtcNow
                        : messages[^1].Date.UtcDateTime,
                    IsLegacy = true,
                });
            }

            return known;
        }
    }

    /// <summary>附近设备快照（按名称排序）。</summary>
    public IReadOnlyList<LinkPeer> Peers
    {
        get
        {
            lock (_peersGate)
            {
                return _peers.Values.OrderBy(peer => peer.Name, StringComparer.CurrentCulture).ToArray();
            }
        }
    }

    public event EventHandler<LinkStatus>? StatusChanged;

    public event EventHandler<IReadOnlyList<LinkPeer>>? PeersChanged;

    public event EventHandler<ChatMessage>? MessageAdded;

    /// <summary>某台设备的消息记录被清空（参数是 peerId）。</summary>
    public event EventHandler<string>? ConversationCleared;


    /// <summary>已配对集合变化（新增 / 移除 / 清空）。</summary>
    public event EventHandler? PairingChanged;

    /// <summary>对方正在请求配对（没带正确配对码）。</summary>
    public event EventHandler<PairRequestEventArgs>? PairRequested;

    public bool IsPaired(string peerId) => !string.IsNullOrEmpty(peerId) && _paired.Contains(peerId);

    public static string GeneratePairingCode() => Random.Shared.Next(0, 1_000_000).ToString("D6");

    // MARK: - 生命周期

    /// <summary>打开 TCP 监听与 UDP 发现。失败只影响对应能力，不抛异常。</summary>
    public Task StartAsync()
    {
        if (Interlocked.Exchange(ref _started, 1) == 1)
        {
            return Task.CompletedTask;
        }

        try
        {
            _listener = new TcpListener(IPAddress.Any, 0);
            _listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _listener.Start(16);
            ListenPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        }
        catch (Exception ex)
        {
            _listener = null;
            Log($"tcp listen failed: {ex.Message}");
            SetStatus(LinkStatusKind.Failure, "无法开始监听传输连接");
            return Task.CompletedTask;
        }

        _cts = new CancellationTokenSource();
        _acceptTask = Task.Run(() => AcceptLoopAsync(_cts.Token));

        _discovery = new DiscoveryService(DeviceId, DeviceName, _log);
        _discovery.PeerSeen += OnPeerSeen;
        _discovery.Failed += OnDiscoveryFailed;
        _discovery.Start(ListenPort);

        // 同机多实例兜底：临时目录心跳文件（不改变网络报文）。
        _localRegistry = new LocalInstanceRegistry(DeviceId, DeviceName, () => ListenPort, _log);
        _localRegistry.Start();
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(300).ConfigureAwait(false);
            }
            catch (Exception)
            {
                return;
            }

            ScanLocalInstances();
        });

        _pruneTimer = new Timer(_ => PrunePeers(), null, LinkProtocol.PruneInterval, LinkProtocol.PruneInterval);
        SetStatus(LinkStatusKind.Idle, "本机已上线，正在查找附近的设备…");
        return Task.CompletedTask;
    }

    public async Task StopAsync()
    {
        if (Interlocked.Exchange(ref _started, 0) == 0)
        {
            return;
        }

        try
        {
            _cts?.Cancel();
        }
        catch (Exception)
        {
            // 忽略关闭异常。
        }

        _pruneTimer?.Dispose();
        _pruneTimer = null;

        var discovery = _discovery;
        _discovery = null;
        discovery?.Dispose();

        var registry = _localRegistry;
        _localRegistry = null;
        registry?.Dispose();

        try
        {
            _listener?.Stop();
        }
        catch (Exception)
        {
            // 忽略关闭异常。
        }

        _listener = null;

        if (_acceptTask is not null)
        {
            try
            {
                await _acceptTask.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // 超时或已结束都无所谓。
            }

            _acceptTask = null;
        }

        _cts?.Dispose();
        _cts = null;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
    }

    // MARK: - 配对 / 本机状态

    public void RegeneratePairingCode()
    {
        _pairingCode = GeneratePairingCode();
        SetStatus(LinkStatusKind.Idle, $"已换新配对码：{_pairingCode}");
    }

    public void SetReceiveDir(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        _receiveDir = path;
        _settings.Save(path);
        SetStatus(LinkStatusKind.Idle, $"接收目录已改为 {path}");
    }

    public void ForgetPair(string peerId, string peerName)
    {
        _paired.Remove(peerId);
        PairingChanged?.Invoke(this, EventArgs.Empty);
        SetStatus(LinkStatusKind.Idle, $"已取消与「{peerName}」的配对，下次发送需要重新输入配对码");
    }

    public void ForgetAllPairs()
    {
        _paired.Clear();
        PairingChanged?.Invoke(this, EventArgs.Empty);
        SetStatus(LinkStatusKind.Idle, "已清除配对记录，下次发送需要重新输入配对码");
    }

    /// <summary>清空某台设备的消息记录，不影响别的设备。</summary>
    public void ClearConversation(string peerId, string peerName)
    {
        if (!string.IsNullOrEmpty(peerId))
        {
            _chats.Clear(peerId);
        }

        if (!string.IsNullOrEmpty(peerName))
        {
            _chats.Clear(ConversationStore.LegacyPrefix + peerName);
        }

        ConversationCleared?.Invoke(this, peerId ?? string.Empty);
        SetStatus(LinkStatusKind.Idle, $"已清空与「{peerName}」的消息记录，已收到的文件不会被删除");
    }

    /// <summary>彻底忘掉一台设备：取消配对 + 删掉名册记录。</summary>
    public void ForgetDevice(string peerId, string peerName)
    {
        if (string.IsNullOrEmpty(peerId))
        {
            return;
        }

        _paired.Remove(peerId);
        _devices.Remove(peerId);
        PairingChanged?.Invoke(this, EventArgs.Empty);
        SetStatus(LinkStatusKind.Idle, $"已取消与「{peerName}」的配对");
    }

    public void ReportCopied()
    {
        SetStatus(LinkStatusKind.Success, "已复制到剪贴板");
    }

    /// <summary>报告某个文件已经不在磁盘上（UI 打开文件失败时用）。</summary>
    public void ReportMissingFile(string path)
    {
        SetStatus(LinkStatusKind.Failure, $"文件已经不在了：{path}");
    }

    // MARK: - 发送

    public async Task<SendOutcome> SendTextAsync(
        LinkPeer peer,
        string text,
        string? pairingCode = null,
        IProgress<SendProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return FinishFailure("先输入要发送的文字");
        }

        SetStatus(LinkStatusKind.Idle, "正在连接…");
        progress?.Report(new SendProgress(0, "文字"));

        var session = await OpenSessionAsync(peer, pairingCode, cancellationToken).ConfigureAwait(false);
        if (!session.IsOk)
        {
            return session.Failure!;
        }

        await using var connection = session.Connection!;
        try
        {
            if (!await connection.WriteJsonAsync(LinkMessages.Text(text), cancellationToken).ConfigureAwait(false))
            {
                return FailOrCancel(cancellationToken, "连接已断开，文字没发出去，可以再点一次发送");
            }

            var response = await connection.ReadJsonAsync(cancellationToken).ConfigureAwait(false);
            if (response is null)
            {
                return FailOrCancel(cancellationToken, "对方没有确认收到文字，网络中断了");
            }

            if (LinkProtocol.GetString(response.Value, "type") != "ok")
            {
                return FailOrCancel(cancellationToken, "对方没有确认收到文字");
            }

            await connection.WriteJsonAsync(LinkMessages.Bye(), cancellationToken).ConfigureAwait(false);
            AppendOutgoingText(peer.Id, peer.Name, text);
            return FinishOk(peer.Name, $"已把文字发送给 {peer.Name}");
        }
        catch (OperationCanceledException)
        {
            return FinishCancelled();
        }
        catch (Exception ex)
        {
            Log($"send text failed: {ex.Message}");
            return FailOrCancel(cancellationToken, "发送文字失败，网络中断了");
        }
    }

    public async Task<SendOutcome> SendFilesAsync(
        LinkPeer peer,
        IReadOnlyList<string> filePaths,
        string? pairingCode = null,
        IProgress<SendProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (filePaths is null || filePaths.Count == 0)
        {
            return FinishFailure("先选择文件");
        }

        // 先校验一遍文件，避免连上了才发现第三个文件读不到，白跑一趟。
        foreach (var path in filePaths)
        {
            if (GetFileSize(path) <= 0)
            {
                return FinishFailure($"读不到文件：{Path.GetFileName(path)}");
            }
        }

        SetStatus(LinkStatusKind.Idle, "正在连接…");

        // 一次发送动作只建一条连接。原实现是每个文件单独连一次、单独握手一次，
        // 批量发 10 个文件要建 10 条 TCP 连接，任何一次抖动整批都失败。
        var session = await OpenSessionAsync(peer, pairingCode, cancellationToken).ConfigureAwait(false);
        if (!session.IsOk)
        {
            return session.Failure!;
        }

        var connection = session.Connection!;
        Log($"session open -> {peer.Name} {peer.Host}:{peer.Port}");
        try
        {
            for (var index = 0; index < filePaths.Count; index++)
            {
                var path = filePaths[index];
                var name = Path.GetFileName(path);
                if (string.IsNullOrEmpty(name))
                {
                    name = "文件";
                }

                var size = GetFileSize(path);
                if (size <= 0)
                {
                    return FinishFailure($"读不到文件：{name}");
                }

                var label = filePaths.Count > 1 ? $"{index + 1}/{filePaths.Count} {name}" : name;
                var delivered = false;

                for (var attempt = 1; attempt <= LinkProtocol.FileAttempts; attempt++)
                {
                    if (attempt > 1)
                    {
                        var reopened = await ReopenForRetryAsync(peer, pairingCode, name, attempt, cancellationToken)
                            .ConfigureAwait(false);
                        if (reopened is null)
                        {
                            return FailOrCancel(cancellationToken, $"连接断了，「{name}」重连失败，没发完");
                        }

                        await connection.DisposeAsync().ConfigureAwait(false);
                        connection = reopened;
                    }

                    progress?.Report(new SendProgress(
                        filePaths.Count > 1 ? (double)index / filePaths.Count : 0,
                        attempt == 1 ? label : $"{label}（重传 {attempt - 1}）"));

                    if (!await connection.WriteJsonAsync(LinkMessages.File(name, size), cancellationToken).ConfigureAwait(false))
                    {
                        Log($"file header failed -> {name} attempt={attempt}");
                        continue;
                    }

                    var (sentOk, sentBytes, reason, retryable) = await SendFileBytesAsync(
                            connection, path, name, size, index, filePaths.Count, progress, cancellationToken)
                        .ConfigureAwait(false);
                    if (!sentOk)
                    {
                        Log($"file body aborted -> {name} {sentBytes}/{size} attempt={attempt}: {reason}");
                        if (cancellationToken.IsCancellationRequested)
                        {
                            return FinishCancelled();
                        }

                        if (!retryable || attempt == LinkProtocol.FileAttempts)
                        {
                            return FailOrCancel(cancellationToken, $"「{name}」没发完：{reason}");
                        }

                        continue;
                    }

                    var response = await connection.ReadJsonAsync(cancellationToken).ConfigureAwait(false);
                    if (response is null || LinkProtocol.GetString(response.Value, "type") != "ok")
                    {
                        Log($"file ack missing -> {name} attempt={attempt}");
                        if (attempt == LinkProtocol.FileAttempts)
                        {
                            return FailOrCancel(cancellationToken, "对方没有确认收到文件，网络可能中断了");
                        }

                        continue;
                    }

                    Log($"file ack ok -> {name} attempt={attempt}");
                    delivered = true;
                    break;
                }

                if (!delivered)
                {
                    return FailOrCancel(cancellationToken, $"「{name}」重传 {LinkProtocol.FileAttempts} 次仍未发完");
                }
            }

            await connection.WriteJsonAsync(LinkMessages.Bye(), cancellationToken).ConfigureAwait(false);

            foreach (var path in filePaths)
            {
                AppendOutgoingFile(peer.Id, peer.Name, path);
            }

            var successText = filePaths.Count == 1
                ? $"已把「{Path.GetFileName(filePaths[0])}」发送给 {peer.Name}"
                : $"已把 {filePaths.Count} 个文件发送给 {peer.Name}";
            progress?.Report(new SendProgress(1, filePaths.Count == 1 ? Path.GetFileName(filePaths[0]) : "完成"));
            return FinishOk(peer.Name, successText);
        }
        catch (OperationCanceledException)
        {
            return FinishCancelled();
        }
        catch (Exception ex)
        {
            Log($"send files failed: {ex.Message}");
            return FailOrCancel(cancellationToken, "网络中断，文件没发完");
        }
        finally
        {
            await connection.DisposeAsync().ConfigureAwait(false);
        }
    }

    /// <summary>文件传输出错后，重开一条会话继续重传。</summary>
    private async Task<TcpConnection?> ReopenForRetryAsync(
        LinkPeer peer,
        string? code,
        string fileName,
        int attempt,
        CancellationToken cancellationToken)
    {
        SetStatus(LinkStatusKind.Idle, $"连接中断，正在重传「{fileName}」…");
        try
        {
            await Task.Delay(400 * (attempt - 1), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return null;
        }

        var session = await OpenSessionAsync(peer, code, cancellationToken).ConfigureAwait(false);
        if (!session.IsOk)
        {
            return null;
        }

        Log($"session reopened -> {peer.Name} attempt={attempt}");
        return session.Connection;
    }

    /// <summary>主动配对：只握手，不发送内容。</summary>
    public async Task<SendOutcome> PairAsync(
        LinkPeer peer,
        string pairingCode,
        IProgress<SendProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var value = (pairingCode ?? string.Empty).Trim();
        if (value.Length != 6 || !value.All(char.IsAsciiDigit))
        {
            return FinishFailure("配对码是 6 位数字");
        }

        SetStatus(LinkStatusKind.Idle, "正在连接…");
        progress?.Report(new SendProgress(0, "配对"));

        try
        {
            var session = await OpenSessionAsync(peer, value, cancellationToken).ConfigureAwait(false);
            if (!session.IsOk)
            {
                // 配对流程里 NeedsPairing 就是「码不对」，换成这句更直接。
                var failure = session.Failure!;
                return failure.Status == SendStatus.NeedsPairing
                    ? FinishFailure("配对码不对，再看一眼对方屏幕上显示的数字")
                    : failure;
            }

            await using var connection = session.Connection!;
            await connection.WriteJsonAsync(LinkMessages.Bye(), cancellationToken).ConfigureAwait(false);
            return FinishOk(peer.Name, $"已与「{peer.Name}」配对，可以直接发送文字和文件");
        }
        catch (Exception ex)
        {
            Log($"pair failed: {ex.Message}");
            return FinishFailure("对方没有响应");
        }
    }

    // MARK: - 握手

    private enum HandshakeKind
    {
        Ok,
        NeedsPairing,
        Failure,
    }

    private readonly record struct HandshakeResult(HandshakeKind Kind, string Message, string PeerName)
    {
        /// <summary>
        /// 断链类失败（写不出去 / 等不到回应）值得重连一次；
        /// 配对码不对、协议不匹配这类重连也没用，不能白白让用户多等。
        /// </summary>
        public bool Retryable { get; init; }
    }

    private async Task<HandshakeResult> HandshakeAsync(
        TcpConnection connection,
        LinkPeer peer,
        string? code,
        CancellationToken cancellationToken)
    {
        if (!await connection.WriteJsonAsync(LinkMessages.Hello(DeviceId, DeviceName, code), cancellationToken).ConfigureAwait(false))
        {
            return new HandshakeResult(HandshakeKind.Failure, "对方没有响应", string.Empty) { Retryable = true };
        }

        var response = await connection.ReadJsonAsync(cancellationToken).ConfigureAwait(false);
        if (response is null)
        {
            return new HandshakeResult(HandshakeKind.Failure, "对方没有响应", string.Empty) { Retryable = true };
        }

        var type = LinkProtocol.GetString(response.Value, "type");
        switch (type)
        {
            case "hello_ok":
                RememberPaired(peer.Id, peer.Name);
                return new HandshakeResult(HandshakeKind.Ok, string.Empty, peer.Name);

            case "pair_required":
                var peerName = LinkProtocol.GetString(response.Value, "name");
                return new HandshakeResult(
                    HandshakeKind.NeedsPairing,
                    string.Empty,
                    string.IsNullOrEmpty(peerName) ? peer.Name : peerName);

            case "error":
                var message = LinkProtocol.GetString(response.Value, "message");
                return new HandshakeResult(
                    HandshakeKind.Failure,
                    string.IsNullOrEmpty(message) ? "对方拒绝了连接" : message,
                    string.Empty);

            default:
                return new HandshakeResult(HandshakeKind.Failure, "协议不匹配，请确认两端版本一致", string.Empty);
        }
    }

    private enum ConnectFailure
    {
        None,
        Refused,
        Timeout,
        InvalidTarget,
        Cancelled,
    }

    /// <summary>已建立并握手完成的会话；失败时带着可直接反馈给 UI 的结果。</summary>
    private readonly record struct SessionResult(TcpConnection? Connection, SendOutcome? Failure)
    {
        public bool IsOk => Connection is not null;

        public static SessionResult Ok(TcpConnection connection) => new(connection, null);

        public static SessionResult Failed(SendOutcome failure) => new(null, failure);
    }

    /// <summary>
    /// 建立 TCP 连接，带重试与总预算。
    /// 原实现只连一次、单一 6 秒超时：Wi-Fi 抖一下、ARP 还没解析、对端刚重启，
    /// 用户立刻看到「连不上」，而且没有任何重连——这就是「动不动断链」的直接来源。
    /// </summary>
    private static async Task<(TcpConnection? Connection, ConnectFailure Reason)> ConnectAsync(
        LinkPeer peer,
        CancellationToken cancellationToken)
    {
        if (!IPAddress.TryParse(peer.Host, out var address) || peer.Port is <= 0 or > 65535)
        {
            return (null, ConnectFailure.InvalidTarget);
        }

        var endpoint = new IPEndPoint(address, peer.Port);
        var deadline = DateTime.UtcNow + LinkProtocol.ConnectBudget;
        var reason = ConnectFailure.Timeout;

        for (var attempt = 0; attempt < LinkProtocol.ConnectAttempts; attempt++)
        {
            var remaining = deadline - DateTime.UtcNow;
            if (remaining <= TimeSpan.Zero)
            {
                break;
            }

            var attemptTimeout = remaining < LinkProtocol.ConnectTimeout ? remaining : LinkProtocol.ConnectTimeout;
            var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutSource.CancelAfter(attemptTimeout);
                await socket.ConnectAsync(endpoint, timeoutSource.Token).ConfigureAwait(false);
                return (new TcpConnection(socket), ConnectFailure.None);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                socket.Dispose();
                return (null, ConnectFailure.Cancelled);
            }
            catch (SocketException ex)
            {
                socket.Dispose();
                reason = ex.SocketErrorCode == SocketError.ConnectionRefused
                    ? ConnectFailure.Refused
                    : ConnectFailure.Timeout;
            }
            catch (Exception)
            {
                socket.Dispose();
                reason = ConnectFailure.Timeout;
            }

            // 端口明确关闭只做一次很短的补试（应用重启通常就一两百毫秒）；
            // 再久就是真没开，不能把用户晾在「正在连接」上。
            if (reason == ConnectFailure.Refused && attempt >= 1)
            {
                break;
            }

            var backoff = TimeSpan.FromMilliseconds(150 * Math.Pow(2, attempt));
            if (DateTime.UtcNow + backoff >= deadline)
            {
                break;
            }

            try
            {
                await Task.Delay(backoff, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return (null, ConnectFailure.Cancelled);
            }
        }

        return (null, reason);
    }

    /// <summary>
    /// 建立一条已握手的会话。连接或握手阶段掉线会自动重连一轮；
    /// 配对码错误、协议不匹配这类「重试也没用」的失败立即返回。
    /// </summary>
    private async Task<SessionResult> OpenSessionAsync(
        LinkPeer peer,
        string? code,
        CancellationToken cancellationToken)
    {
        var lastReason = ConnectFailure.Timeout;
        var lastHandshake = default(HandshakeResult);
        var handshakeFailed = false;

        for (var round = 0; round < LinkProtocol.SendRounds; round++)
        {
            if (round > 0)
            {
                SetStatus(LinkStatusKind.Idle, $"连接中断，正在重连 {peer.Name}…");
            }

            var (connection, reason) = await ConnectAsync(peer, cancellationToken).ConfigureAwait(false);
            if (connection is null)
            {
                // ConnectAsync 内部已经重试过整轮了，这里再套一层只会让用户白等一倍时间。
                lastReason = reason;
                break;
            }

            var handshake = await HandshakeAsync(connection, peer, code, cancellationToken).ConfigureAwait(false);
            switch (handshake.Kind)
            {
                case HandshakeKind.Ok:
                    return SessionResult.Ok(connection);

                case HandshakeKind.NeedsPairing:
                    await connection.DisposeAsync().ConfigureAwait(false);
                    return SessionResult.Failed(FinishNeedsPairing(handshake.PeerName));

                default:
                    await connection.DisposeAsync().ConfigureAwait(false);
                    if (!handshake.Retryable)
                    {
                        return SessionResult.Failed(FinishFailure(handshake.Message));
                    }

                    lastHandshake = handshake;
                    handshakeFailed = true;
                    break;
            }
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return SessionResult.Failed(FinishCancelled());
        }

        Log($"session failed -> {peer.Name} {peer.Host}:{peer.Port} handshake={handshakeFailed} reason={lastReason}");
        return SessionResult.Failed(FinishFailure(
            handshakeFailed ? lastHandshake.Message : ConnectFailureText(peer, lastReason)));
    }

    /// <summary>
    /// 探测对端是否可达。只做一次 TCP 连接然后立刻关闭，**不发 hello**，
    /// 所以不会在对方屏幕上弹出配对提示，适合做「重新连接」和断线自动探测。
    /// </summary>
    public async Task<bool> ProbeAsync(LinkPeer peer, CancellationToken cancellationToken = default)
    {
        if (!IPAddress.TryParse(peer.Host, out var address) || peer.Port is <= 0 or > 65535)
        {
            return false;
        }

        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(LinkProtocol.ConnectTimeout);
            await socket.ConnectAsync(new IPEndPoint(address, peer.Port), timeout.Token).ConfigureAwait(false);
            return true;
        }
        catch (Exception)
        {
            // 探活失败是常态（对方没开、不在同一网段、超时），界面已经显示结果了，
            // 不写进日志——否则日志会被每 5 秒一次的探活刷满。
            return false;
        }
        finally
        {
            try
            {
                socket.Dispose();
            }
            catch (Exception)
            {
                // 忽略。
            }
        }
    }

    // MARK: - 接收（服务端）

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            Socket socket;
            try
            {
                var listener = _listener;
                if (listener is null)
                {
                    return;
                }

                socket = await listener.AcceptSocketAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            catch (InvalidOperationException)
            {
                return;
            }
            catch (SocketException ex)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                Log($"accept failed: {ex.SocketErrorCode}");
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

            _ = Task.Run(() => HandleClientAsync(socket), CancellationToken.None);
        }
    }

    private async Task HandleClientAsync(Socket socket)
    {
        await using var connection = new TcpConnection(socket);
        var cancellationToken = _cts?.Token ?? CancellationToken.None;

        try
        {
            var hello = await connection.ReadJsonAsync(cancellationToken).ConfigureAwait(false);
            if (hello is null)
            {
                return;
            }

            var app = LinkProtocol.GetString(hello.Value, "app");
            var peerId = LinkProtocol.GetString(hello.Value, "id");
            var peerName = LinkProtocol.GetString(hello.Value, "name");
            if (app != LinkProtocol.AppTag
                || string.IsNullOrEmpty(peerId)
                || peerId == DeviceId
                || string.IsNullOrEmpty(peerName))
            {
                Log("hello rejected: protocol mismatch");
                await connection.WriteJsonAsync(LinkMessages.Error("协议不匹配，请升级两端应用"), cancellationToken)
                    .ConfigureAwait(false);
                return;
            }

            if (!_paired.Contains(peerId))
            {
                var code = (LinkProtocol.GetString(hello.Value, "code") ?? string.Empty).Trim();
                if (code.Length == 0 || !string.Equals(code, PairingCode, StringComparison.Ordinal))
                {
                    Log($"pair required for {peerName}");
                    PairRequested?.Invoke(this, new PairRequestEventArgs(peerId, peerName));
                    SetStatus(LinkStatusKind.Idle, $"「{peerName}」正在请求配对，把配对码告诉对方即可");
                    await connection.WriteJsonAsync(LinkMessages.PairRequired(DeviceName), cancellationToken)
                        .ConfigureAwait(false);
                    return;
                }

                RememberPaired(peerId, peerName);
            }

            if (!await connection.WriteJsonAsync(LinkMessages.HelloOk(DeviceName, DeviceId), cancellationToken)
                    .ConfigureAwait(false))
            {
                return;
            }

            SetStatus(LinkStatusKind.Idle, $"{peerName} 已连接");

            while (!cancellationToken.IsCancellationRequested)
            {
                var frame = await connection.ReadJsonAsync(cancellationToken).ConfigureAwait(false);
                if (frame is null)
                {
                    return;
                }

                var type = LinkProtocol.GetString(frame.Value, "type");
                switch (type)
                {
                    case "text":
                    {
                        var text = LinkProtocol.GetString(frame.Value, "text");
                        if (text is null)
                        {
                            return;
                        }

                        AppendIncomingText(peerId, peerName, text);
                        SetStatus(LinkStatusKind.Success, $"收到 {peerName} 发来的文字");
                        if (!await connection.WriteJsonAsync(LinkMessages.Ok(), cancellationToken).ConfigureAwait(false))
                        {
                            return;
                        }

                        break;
                    }

                    case "file":
                    {
                        var rawName = LinkProtocol.GetString(frame.Value, "name");
                        var size = LinkProtocol.GetInt64(frame.Value, "size");
                        if (rawName is null || size is null || size < 0)
                        {
                            return;
                        }

                        SetStatus(LinkStatusKind.Idle, $"正在接收 {peerName} 发来的「{SafeDisplayName(rawName)}」…");
                        var savedPath = await ReceiveFileAsync(connection, rawName, size.Value, cancellationToken)
                            .ConfigureAwait(false);
                        if (savedPath is null)
                        {
                            SetStatus(LinkStatusKind.Failure, "保存文件失败");
                            await connection.WriteJsonAsync(LinkMessages.Error("保存文件失败"), cancellationToken)
                                .ConfigureAwait(false);
                            return;
                        }

                        AppendIncomingFile(peerId, peerName, savedPath, size.Value);
                        SetStatus(LinkStatusKind.Success, $"已收到「{Path.GetFileName(savedPath)}」，存在 {ReceiveDir}");
                        if (!await connection.WriteJsonAsync(LinkMessages.Ok(), cancellationToken).ConfigureAwait(false))
                        {
                            return;
                        }

                        break;
                    }

                    case "bye":
                        return;

                    default:
                        return;
                }
            }
        }
        catch (Exception ex)
        {
            Log($"client handling failed: {ex.Message}");
        }
    }

    private async Task<string?> ReceiveFileAsync(
        TcpConnection connection,
        string rawName,
        long size,
        CancellationToken cancellationToken)
    {
        var name = NormalizeFileName(rawName);
        if (name.Length == 0)
        {
            return null;
        }

        string directory;
        try
        {
            directory = ReceiveDir;
            Directory.CreateDirectory(directory);
        }
        catch (Exception ex)
        {
            Log($"create receive dir failed: {ex.Message}");
            return null;
        }

        var targetPath = BuildUniquePath(directory, name);
        FileStream stream;
        try
        {
            stream = new FileStream(targetPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true);
        }
        catch (Exception ex)
        {
            Log($"create receive file failed: {ex.Message}");
            return null;
        }

        var failed = false;
        try
        {
            var buffer = new byte[LinkProtocol.FileChunkBytes];
            var remaining = size;
            while (remaining > 0)
            {
                var want = (int)Math.Min(buffer.Length, remaining);
                if (!await connection.ReadExactAsync(buffer.AsMemory(0, want), cancellationToken).ConfigureAwait(false))
                {
                    failed = true;
                    break;
                }

                try
                {
                    await stream.WriteAsync(buffer.AsMemory(0, want), cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    Log($"write receive file failed: {ex.Message}");
                    failed = true;
                    break;
                }

                remaining -= want;
            }

            if (!failed)
            {
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            try
            {
                stream.Dispose();
            }
            catch (Exception)
            {
                // 忽略关闭异常。
            }
        }

        if (failed)
        {
            TryDelete(targetPath);
            return null;
        }

        return targetPath;
    }

    // MARK: - 发送文件数据

    /// <summary>
    /// 传一个文件的数据块。失败时返回「停在哪一步、发了多少字节」，
    /// 原来的实现只返回 bool，界面上只能给一句含糊的「网络中断」，
    /// 本地文件读不出来和对端断连根本分不清。
    /// </summary>
    private async Task<(bool Ok, long Sent, string Reason, bool Retryable)> SendFileBytesAsync(
        TcpConnection connection,
        string path,
        string name,
        long size,
        int index,
        int total,
        IProgress<SendProgress>? progress,
        CancellationToken cancellationToken)
    {
        FileStream stream;
        try
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, LinkProtocol.FileChunkBytes, useAsync: true);
        }
        catch (Exception ex)
        {
            return (false, 0, $"打不开本地文件：{ex.Message}", false);
        }

        long sent = 0;
        try
        {
            var buffer = new byte[LinkProtocol.FileChunkBytes];
            while (sent < size)
            {
                var want = (int)Math.Min(buffer.Length, size - sent);
                var read = await stream.ReadAsync(buffer.AsMemory(0, want), cancellationToken).ConfigureAwait(false);
                if (read <= 0)
                {
                    return (false, sent, $"本地文件只读到 {sent}/{size} 字节就结束了（云盘占位文件或文件被移动、锁定）", false);
                }

                if (!await connection.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false))
                {
                    return (false, sent, $"传到 {sent}/{size} 字节时连接被对方关闭", true);
                }

                sent += read;
                var fraction = total <= 0 ? 0 : (index + Math.Min(1.0, (double)sent / size)) / total;
                progress?.Report(new SendProgress(Math.Min(0.99, fraction), name));
            }

            return (true, sent, string.Empty, false);
        }
        catch (OperationCanceledException)
        {
            return (false, sent, "已取消", false);
        }
        catch (Exception ex)
        {
            return (false, sent, $"传了 {sent}/{size} 字节后出错：{ex.Message}", true);
        }
        finally
        {
            try
            {
                stream.Dispose();
            }
            catch (Exception)
            {
                // 忽略关闭异常。
            }
        }
    }

    // MARK: - 设备发现 / 清理

    private void OnPeerSeen(object? sender, LinkPeer peer)
    {
        // 已经配对过的设备一经发现就进名册：它之后离线了也要留在列表里，
        // 而不是等下一次收发消息才被记住。
        if (_paired.Contains(peer.Id))
        {
            _devices.Upsert(peer.Id, peer.Name);
        }

        var changed = false;
        var isNew = false;
        IReadOnlyList<LinkPeer>? snapshot = null;

        lock (_peersGate)
        {
            if (_peers.TryGetValue(peer.Id, out var existing))
            {
                var nameChanged = existing.Name != peer.Name;
                var endpointChanged = existing.Host != peer.Host || existing.Port != peer.Port;
                _peers[peer.Id] = peer;
                if (nameChanged || endpointChanged)
                {
                    changed = true;
                    snapshot = _peers.Values.OrderBy(item => item.Name, StringComparer.CurrentCulture).ToArray();
                }
            }
            else
            {
                _peers[peer.Id] = peer;
                isNew = true;
                changed = true;
                snapshot = _peers.Values.OrderBy(item => item.Name, StringComparer.CurrentCulture).ToArray();
            }
        }

        if (!changed)
        {
            return;
        }

        PeersChanged?.Invoke(this, snapshot!);
        if (isNew)
        {
            SetStatus(LinkStatusKind.Idle, $"发现 {snapshot!.Count} 台设备");
        }
    }

    private void OnDiscoveryFailed(object? sender, string message)
    {
        SetStatus(LinkStatusKind.Failure, message);
    }

    private void ScanLocalInstances()
    {
        var registry = _localRegistry;
        if (registry is null)
        {
            return;
        }

        foreach (var peer in registry.Scan())
        {
            OnPeerSeen(this, peer);
        }
    }

    private void PrunePeers()
    {
        // 先补扫本机其它实例，再清理过期设备。
        ScanLocalInstances();

        LinkPeer[]? snapshot = null;
        lock (_peersGate)
        {
            var now = DateTime.UtcNow;
            var expired = _peers.Values
                .Where(peer => (now - peer.LastSeenUtc) > LinkProtocol.PeerTimeout)
                .Select(peer => peer.Id)
                .ToArray();
            if (expired.Length == 0)
            {
                return;
            }

            foreach (var id in expired)
            {
                _peers.Remove(id);
            }

            snapshot = _peers.Values.OrderBy(item => item.Name, StringComparer.CurrentCulture).ToArray();
        }

        PeersChanged?.Invoke(this, snapshot);
        if (snapshot.Length == 0 && Status.Kind == LinkStatusKind.Idle)
        {
            SetStatus(LinkStatusKind.Idle, "正在搜索局域网内的设备…");
        }
    }

    // MARK: - 状态 / 消息

    private void SetStatus(LinkStatusKind kind, string text)
    {
        _status = new LinkStatus(kind, text);
        StatusChanged?.Invoke(this, _status);
    }

    private void RememberPaired(string peerId, string peerName)
    {
        // 配对成功就进名册：以后即使离线，这台设备也要留在列表里。
        _devices.Upsert(peerId, peerName);
        if (_paired.Add(peerId))
        {
            PairingChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private SendOutcome FinishOk(string peerName, string message)
    {
        SetStatus(LinkStatusKind.Success, message);
        return SendOutcome.Ok(peerName, message);
    }

    private SendOutcome FinishFailure(string message)
    {
        SetStatus(LinkStatusKind.Failure, message);
        return SendOutcome.Failure(message);
    }

    /// <summary>用户取消时给出"已取消"，否则才报失败，避免把主动取消说成网络故障。</summary>
    private SendOutcome FailOrCancel(CancellationToken cancellationToken, string message) =>
        cancellationToken.IsCancellationRequested ? FinishCancelled() : FinishFailure(message);

    private SendOutcome FinishCancelled(string message = "已取消发送")
    {
        SetStatus(LinkStatusKind.Idle, message);
        return SendOutcome.Cancelled(message);
    }

    private SendOutcome FinishNeedsPairing(string peerName)
    {
        SetStatus(LinkStatusKind.Idle, $"首次给「{peerName}」发送，需要输入对方屏幕上显示的 6 位配对码");
        return SendOutcome.NeedsPairing(peerName);
    }

    private static string ConnectFailureText(LinkPeer peer, ConnectFailure reason) => reason switch
    {
        ConnectFailure.Refused => $"连不上 {peer.Name}：对方没有在监听，应用可能刚退出或正在重启",
        ConnectFailure.InvalidTarget => $"连不上 {peer.Name}：地址已失效，等它重新广播后再试",
        ConnectFailure.Cancelled => "已取消",
        _ => $"连不上 {peer.Name}：网络暂时不通，请确认两台设备在同一局域网、对方应用已打开",
    };

    private void AppendIncomingText(string peerId, string peerName, string text)
    {
        SaveMessage(new ChatMessage
        {
            PeerId = peerId,
            Direction = MessageDirection.Incoming,
            PeerName = peerName,
            Date = DateTimeOffset.Now,
            Kind = MessageKind.Text,
            Text = text,
        });
    }

    private void AppendIncomingFile(string peerId, string peerName, string savedPath, long size)
    {
        SaveMessage(new ChatMessage
        {
            PeerId = peerId,
            Direction = MessageDirection.Incoming,
            PeerName = peerName,
            Date = DateTimeOffset.Now,
            Kind = MessageKind.File,
            FileName = Path.GetFileName(savedPath),
            FilePath = savedPath,
            FileSize = size,
        });
    }

    private void AppendOutgoingText(string peerId, string peerName, string text)
    {
        SaveMessage(new ChatMessage
        {
            PeerId = peerId,
            Direction = MessageDirection.Outgoing,
            PeerName = peerName,
            Date = DateTimeOffset.Now,
            Kind = MessageKind.Text,
            Text = text,
        });
    }

    private void AppendOutgoingFile(string peerId, string peerName, string path)
    {
        SaveMessage(new ChatMessage
        {
            PeerId = peerId,
            Direction = MessageDirection.Outgoing,
            PeerName = peerName,
            Date = DateTimeOffset.Now,
            Kind = MessageKind.File,
            FileName = Path.GetFileName(path),
            FilePath = path,
            FileSize = GetFileSize(path),
        });
    }

    /// <summary>落到这台设备自己的会话文件里，并把设备记进名册。</summary>
    private void SaveMessage(ChatMessage message)
    {
        _chats.Append(message);
        try
        {
            _devices.Upsert(message.PeerId, message.PeerName);
        }
        catch (Exception ex)
        {
            Log($"device roster update failed: {ex.Message}");
        }

        MessageAdded?.Invoke(this, message);
    }

    // MARK: - 工具

    private static long GetFileSize(string path)
    {
        try
        {
            return new FileInfo(path).Length;
        }
        catch (Exception)
        {
            return 0;
        }
    }

    /// <summary>文件名只保留最后一段，并替换掉当前平台不允许的字符（§6.3）。</summary>
    internal static string NormalizeFileName(string rawName)
    {
        var name = rawName;
        var slash = name.LastIndexOfAny(new[] { '/', '\\' });
        if (slash >= 0)
        {
            name = name[(slash + 1)..];
        }

        name = name.Trim();
        if (name.Length == 0 || name == "." || name == "..")
        {
            return string.Empty;
        }

        var invalid = Path.GetInvalidFileNameChars();
        var builder = new System.Text.StringBuilder(name.Length);
        foreach (var character in name)
        {
            builder.Append(Array.IndexOf(invalid, character) >= 0 ? '_' : character);
        }

        name = builder.ToString().Trim();
        return name is "" or "." or ".." ? string.Empty : name;
    }

    private static string SafeDisplayName(string rawName)
    {
        var normalized = NormalizeFileName(rawName);
        return string.IsNullOrEmpty(normalized) ? rawName : normalized;
    }

    private static string BuildUniquePath(string directory, string fileName)
    {
        var candidate = Path.Combine(directory, fileName);
        if (!File.Exists(candidate))
        {
            return candidate;
        }

        var baseName = Path.GetFileNameWithoutExtension(fileName);
        var extension = Path.GetExtension(fileName);
        for (var index = 2; ; index++)
        {
            var candidateName = string.IsNullOrEmpty(extension)
                ? $"{baseName} ({index})"
                : $"{baseName} ({index}){extension}";
            candidate = Path.Combine(directory, candidateName);
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }
    }

    private static void TryDelete(string path)
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
            // 删除失败就留个半截文件，不影响主流程。
        }
    }

    private void Log(string message)
    {
        _log?.Invoke(message);
    }
}
