using System.Collections.ObjectModel;
using ADBTypeLink.Core;
using Avalonia.Threading;

namespace ADBTypeLink.App.ViewModels;

/// <summary>
/// 主窗口 ViewModel：封装 LinkEngine，并把引擎在 UDP/TCP 线程上抛出的所有事件
/// 通过 Dispatcher.UIThread.Post 切回 UI 线程后再改 ObservableCollection。
/// </summary>
public sealed class MainViewModel : ObservableObject, IAsyncDisposable
{
    private readonly Dispatcher _dispatcher;
    private readonly LinkEngine _engine;
    private readonly ObservableCollection<PeerItemViewModel> _peers = new();
    private readonly ObservableCollection<MessageItemViewModel> _messages = new();
    private readonly ObservableCollection<StagedFileViewModel> _stagedFiles = new();

    private PeerItemViewModel? _selectedPeer;
    private string _deviceName = string.Empty;
    private string _pairingCode = string.Empty;
    private string _receiveDir = string.Empty;
    private int _pairedCount;
    private string? _pendingPairName;
    private string? _pendingPairPeerId;
    private string _statusText = "正在搜索局域网内的设备…";
    private LinkStatusKind _statusKind = LinkStatusKind.Idle;
    private bool _busy;
    private double _sendProgress;
    private string _sendLabel = string.Empty;
    private string _draftText = string.Empty;
    private bool _isDragOver;
    private bool _initialized;
    private DispatcherTimer? _presenceTimer;
    private CancellationTokenSource? _sendCts;
    private string? _sendError;
    private bool _probeInFlight;
    private DateTime _lastProbeUtc = DateTime.MinValue;

    public MainViewModel(LinkEngine? engine = null)
    {
        _dispatcher = Dispatcher.UIThread;
        _engine = engine ?? new LinkEngine();
        _engine.LogSink = AppLog.Write;
    }

    public LinkEngine Engine => _engine;

    /// <summary>「移动设备」页（adb 文字注入 / 文件推送）。</summary>
    public MobileDeviceViewModel Mobile { get; } = new();

    public ObservableCollection<PeerItemViewModel> Peers => _peers;

    public ObservableCollection<MessageItemViewModel> Messages => _messages;

    public ObservableCollection<StagedFileViewModel> StagedFiles => _stagedFiles;

    // MARK: - 生命周期

    public async Task InitializeAsync()
    {
        if (_initialized)
        {
            return;
        }

        _initialized = true;

        // 所有引擎事件都可能在后台线程触发，统一 Post 回 UI 线程。
        _engine.StatusChanged += (_, status) => OnUi(() => ApplyStatus(status));
        _engine.PeersChanged += (_, peers) => OnUi(() => ApplyPeers(peers));
        _engine.MessageAdded += (_, message) => OnUi(() => AddMessage(message));
        _engine.ConversationCleared += (_, peerId) => OnUi(() =>
        {
            if (_selectedPeer is not null && string.Equals(_selectedPeer.Id, peerId, StringComparison.Ordinal))
            {
                ClearMessageCollection();
            }
        });
        _engine.PairingChanged += (_, _) => OnUi(RefreshPairing);
        _engine.PairRequested += (_, eventArgs) => OnUi(() => ApplyPairRequest(eventArgs));

        DeviceName = _engine.DeviceName;
        PairingCode = _engine.PairingCode;
        ReceiveDir = _engine.ReceiveDir;
        PairedCount = _engine.PairedCount;
        ApplyStatus(_engine.Status);
        // 名册里的设备在 ApplyPeers 里恢复成「离线」行，并自动选中第一台，
        // 会话由此加载，不需要再把全部消息塞进一个列表。
        ApplyPeers(_engine.Peers);

        OnPropertyChanged(nameof(MessagesEmpty));

        await _engine.StartAsync();
        await Mobile.InitializeAsync();

        // 每 2 秒刷新一次在线状态：引擎只负责「18 秒没广播就移除」，
        // 而「超过 6 秒没广播」这个更早的掉线信号要靠界面自己显示出来，
        // 这样用户能看到「连接中断，正在重连…」，而不是设备凭空消失。
        _presenceTimer = new DispatcherTimer(
            TimeSpan.FromSeconds(2),
            DispatcherPriority.Background,
            (_, _) => RefreshPresence());
        _presenceTimer.Start();
    }

    public async ValueTask DisposeAsync()
    {
        _presenceTimer?.Stop();
        _presenceTimer = null;
        Mobile.Dispose();
        await _engine.DisposeAsync();
    }

    private void RefreshPresence()
    {
        var utcNow = DateTime.UtcNow;
        foreach (var peer in _peers)
        {
            peer.RefreshPresence(utcNow);
        }

        RaiseHeaderProperties();
        MaybeAutoProbe(utcNow);
    }

    /// <summary>
    /// 自动重连：UDP 广播丢了不代表链路断了，所以对「看起来掉线」的选中设备
    /// 每 5 秒做一次轻量 TCP 探测，通了就把状态改回在线。
    /// </summary>
    private void MaybeAutoProbe(DateTime utcNow)
    {
        var peer = SelectedPeer;
        // Port 为 0 说明它从来没在局域网里出现过（比如只有历史记录的旧设备），探了也没意义。
        if (peer is null || Busy || _probeInFlight || peer.IsOnline || peer.Port <= 0)
        {
            return;
        }

        if (utcNow - _lastProbeUtc < TimeSpan.FromSeconds(5))
        {
            return;
        }

        _lastProbeUtc = utcNow;
        _ = ProbePeerAsync(peer, announce: false);
    }

    /// <summary>手动「重新连接」：不管当前状态，立即探一次并给出明确结果。</summary>
    public async Task<bool> ReconnectSelectedAsync()
    {
        var peer = SelectedPeer;
        if (peer is null)
        {
            SetLocalFailure("先在左侧选择设备");
            return false;
        }

        if (_probeInFlight)
        {
            return false;
        }

        if (peer.Port <= 0)
        {
            SetLocalFailure($"「{peer.Name}」暂时没有出现在局域网里，等它上线后会自动连上");
            return false;
        }

        SetLocalFailure("正在重新连接…");
        return await ProbePeerAsync(peer, announce: true);
    }

    private async Task<bool> ProbePeerAsync(PeerItemViewModel peer, bool announce)
    {
        if (_probeInFlight)
        {
            return false;
        }

        _probeInFlight = true;
        peer.IsProbing = true;
        try
        {
            var reachable = await _engine.ProbeAsync(peer.ToPeer()).ConfigureAwait(true);
            if (reachable)
            {
                peer.MarkReachable(DateTime.UtcNow);
            }

            if (announce)
            {
                if (reachable)
                {
                    ApplyStatus(new LinkStatus(LinkStatusKind.Success, $"已重新连上 {peer.Name}"));
                }
                else
                {
                    ApplyStatus(new LinkStatus(
                        LinkStatusKind.Failure,
                        $"连不上 {peer.Name}：对方可能已经退出，或两台机器不在同一个网络"));
                }
            }

            RaiseHeaderProperties();
            return reachable;
        }
        catch (Exception exception)
        {
            if (announce)
            {
                ApplyStatus(new LinkStatus(LinkStatusKind.Failure, $"重新连接失败：{exception.Message}"));
            }

            return false;
        }
        finally
        {
            peer.IsProbing = false;
            _probeInFlight = false;
        }
    }

    private void OnUi(Action action)
    {
        if (_dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            _dispatcher.Post(action);
        }
    }

    // MARK: - 本机信息

    public string DeviceName
    {
        get => _deviceName;
        private set => SetProperty(ref _deviceName, value);
    }

    public string PairingCode
    {
        get => _pairingCode;
        private set
        {
            if (SetProperty(ref _pairingCode, value))
            {
                OnPropertyChanged(nameof(PairingCodeDisplay));
                OnPropertyChanged(nameof(PendingPairDetail));
            }
        }
    }

    // 两两分组，例如 483 920：既方便口述，也能在 260px 侧栏里完整显示 6 位数字。
    public string PairingCodeDisplay => _pairingCode.Length == 6
        ? $"{_pairingCode[..3]} {_pairingCode[3..]}"
        : _pairingCode;

    public string ReceiveDir
    {
        get => _receiveDir;
        private set => SetProperty(ref _receiveDir, value);
    }

    public int PairedCount
    {
        get => _pairedCount;
        private set
        {
            if (SetProperty(ref _pairedCount, value))
            {
                OnPropertyChanged(nameof(PairedSummary));
                OnPropertyChanged(nameof(HasPaired));
            }
        }
    }

    public string PairedSummary => $"已配对 {PairedCount} 台";

    public bool HasPaired => PairedCount > 0;

    public string? PendingPairName
    {
        get => _pendingPairName;
        private set
        {
            if (SetProperty(ref _pendingPairName, value))
            {
                OnPropertyChanged(nameof(HasPendingPair));
                OnPropertyChanged(nameof(PendingPairTitle));
                OnPropertyChanged(nameof(PendingPairDetail));
            }
        }
    }

    public bool HasPendingPair => !string.IsNullOrEmpty(PendingPairName);

    public string PendingPairTitle => $"「{PendingPairName}」正在请求配对";

    public string PendingPairDetail => $"把本机配对码 {PairingCode} 告诉对方，对方输入后即可互传";

    // MARK: - 设备列表

    public bool HasPeers => _peers.Count > 0;

    public bool NoPeers => _peers.Count == 0;

    public string PeerCountText
    {
        get
        {
            var offline = _peers.Count(peer => !peer.IsOnline);
            return offline == 0 ? $"{_peers.Count} 台" : $"{_peers.Count - offline} 在线 · {offline} 离线";
        }
    }

    public PeerItemViewModel? SelectedPeer
    {
        get => _selectedPeer;
        set
        {
            if (ReferenceEquals(_selectedPeer, value))
            {
                return;
            }

            if (_selectedPeer is not null)
            {
                _selectedPeer.IsSelected = false;
            }

            _selectedPeer = value;

            if (_selectedPeer is not null)
            {
                _selectedPeer.IsSelected = true;
            }

            OnPropertyChanged();
            RaiseComposeProperties();
            RaiseHeaderProperties();
            LoadConversation();
        }
    }

    public bool HasSelectedPeer => SelectedPeer is not null;

    public string HeaderTitle => SelectedPeer?.Name ?? "文件互传助手";

    public string HeaderStatusText
    {
        get
        {
            var peer = SelectedPeer;
            if (peer is null)
            {
                return "先在左侧选择设备";
            }

            var presence = peer.IsOnline
                ? "在线"
                : (peer.IsKnown || peer.HasHistory ? "离线，历史记录可查看" : "连接中断");
            return peer.IsPaired ? $"已配对 · {presence}" : $"未配对 · {presence}";
        }
    }

    public string TargetHint
    {
        get
        {
            var peer = SelectedPeer;
            if (peer is null)
            {
                return "先在左侧选择设备";
            }

            return peer.IsPaired
                ? $"发给 {peer.Name}"
                : $"发给 {peer.Name} · 首次发送需输入对方配对码";
        }
    }

    public bool ShowPairButton => SelectedPeer is { IsPaired: false };

    // MARK: - 消息

    public bool MessagesEmpty => _messages.Count == 0;

    public string MessageCountText => $"{_messages.Count} 条";

    // MARK: - 状态 / 发送状态

    public string StatusText
    {
        get => _statusText;
        private set => SetProperty(ref _statusText, value);
    }

    public LinkStatusKind StatusKind
    {
        get => _statusKind;
        private set
        {
            if (SetProperty(ref _statusKind, value))
            {
                OnPropertyChanged(nameof(StatusIsSuccess));
                OnPropertyChanged(nameof(StatusIsFailure));
                OnPropertyChanged(nameof(StatusSymbol));
            }
        }
    }

    public bool StatusIsSuccess => _statusKind == LinkStatusKind.Success;

    public bool StatusIsFailure => _statusKind == LinkStatusKind.Failure;

    public string StatusSymbol => _statusKind switch
    {
        LinkStatusKind.Success => "✓",
        LinkStatusKind.Failure => "⚠",
        _ => "ⓘ",
    };

    public bool Busy
    {
        get => _busy;
        private set
        {
            if (SetProperty(ref _busy, value))
            {
                RaiseComposeProperties();
            }
        }
    }

    public double SendProgress
    {
        get => _sendProgress;
        private set
        {
            if (SetProperty(ref _sendProgress, Math.Clamp(value, 0, 1)))
            {
                OnPropertyChanged(nameof(SendPercentText));
            }
        }
    }

    /// <summary>进度百分比，界面上直接显示成 46%。</summary>
    public string SendPercentText => $"{Math.Round(_sendProgress * 100):0}%";

    public string SendLabel
    {
        get => _sendLabel;
        private set
        {
            if (SetProperty(ref _sendLabel, value))
            {
                OnPropertyChanged(nameof(SendLabelText));
            }
        }
    }

    public string SendLabelText => string.IsNullOrEmpty(SendLabel) ? "正在发送…" : $"正在发送 {SendLabel}";

    /// <summary>发送失败时的醒目提示：原来失败只写进角落的状态行，用户以为「点了没反应」。</summary>
    public string? SendErrorText
    {
        get => _sendError;
        private set
        {
            if (SetProperty(ref _sendError, value))
            {
                OnPropertyChanged(nameof(HasSendError));
            }
        }
    }

    public bool HasSendError => !string.IsNullOrEmpty(_sendError);

    public void DismissSendError() => SendErrorText = null;

    public string DraftText
    {
        get => _draftText;
        set
        {
            if (SetProperty(ref _draftText, value))
            {
                OnPropertyChanged(nameof(CanSendText));
            }
        }
    }

    public bool CanCompose => SelectedPeer is not null && !Busy;

    public bool CanSendText => CanCompose && !string.IsNullOrWhiteSpace(DraftText);

    public bool IsDragOver
    {
        get => _isDragOver;
        set => SetProperty(ref _isDragOver, value);
    }

    // MARK: - 待发送文件

    public bool HasStagedFiles => _stagedFiles.Count > 0;

    public string StagedSummary => $"{_stagedFiles.Count} 个文件待发送";

    public string StagedButtonText => _stagedFiles.Count <= 1 ? "发送文件" : $"发送 {_stagedFiles.Count} 个文件";

    // MARK: - 本机操作

    public void RegeneratePairingCode()
    {
        _engine.RegeneratePairingCode();
        PairingCode = _engine.PairingCode;
    }

    public void ForgetAllPairs()
    {
        _engine.ForgetAllPairs();
        PairedCount = _engine.PairedCount;
        foreach (var peer in _peers)
        {
            peer.IsPaired = _engine.IsPaired(peer.Id);
        }

        RaiseHeaderProperties();
    }

    public void ForgetPeer(PeerItemViewModel peer)
    {
        _engine.ForgetPair(peer.Id, peer.Name);
        PairedCount = _engine.PairedCount;
        foreach (var item in _peers)
        {
            item.IsPaired = _engine.IsPaired(item.Id);
        }

        RaiseHeaderProperties();
    }

    /// <summary>只清当前这台设备的记录，别的设备一个字都不动。</summary>
    public void ClearMessages()
    {
        var peer = SelectedPeer;
        if (peer is null)
        {
            return;
        }

        _engine.ClearConversation(peer.Id, peer.Name);
        peer.HasHistory = false;
    }

    public void SetReceiveDir(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        _engine.SetReceiveDir(path);
        ReceiveDir = _engine.ReceiveDir;
    }

    public void ClearPendingPair()
    {
        PendingPairName = null;
        _pendingPairPeerId = null;
    }

    public void ReportCopied() => _engine.ReportCopied();

    public void ReportMissingFile(string path) => _engine.ReportMissingFile(path);

    public void SetLocalFailure(string message) => ApplyStatus(new LinkStatus(LinkStatusKind.Failure, message));

    // MARK: - 待发送文件操作

    public void AddStagedFiles(IEnumerable<string> paths)
    {
        if (Busy)
        {
            return;
        }

        var seen = new HashSet<string>(_stagedFiles.Select(item => item.Path), StringComparer.OrdinalIgnoreCase);
        foreach (var path in paths)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                continue;
            }

            var fullPath = Path.GetFullPath(path);
            if (seen.Add(fullPath))
            {
                _stagedFiles.Add(new StagedFileViewModel(fullPath));
            }
        }

        RaiseStagedProperties();
    }

    public void RemoveStagedFile(StagedFileViewModel item)
    {
        if (Busy)
        {
            return;
        }

        _stagedFiles.Remove(item);
        RaiseStagedProperties();
    }

    public void ClearStagedFiles()
    {
        if (Busy)
        {
            return;
        }

        _stagedFiles.Clear();
        RaiseStagedProperties();
    }

    private void RaiseStagedProperties()
    {
        OnPropertyChanged(nameof(HasStagedFiles));
        OnPropertyChanged(nameof(StagedSummary));
        OnPropertyChanged(nameof(StagedButtonText));
    }

    // MARK: - 发送

    public async Task<SendOutcome> SendTextAsync(string? pairingCode)
    {
        var peer = SelectedPeer;
        if (peer is null)
        {
            return SendOutcome.Failure("先在左侧选择设备");
        }

        var text = DraftText;
        if (string.IsNullOrWhiteSpace(text))
        {
            return SendOutcome.Failure("先输入要发送的文字");
        }

        var target = peer.ToPeer();
        AppLog.Write($"send text -> {peer.Name} ({text.Length} chars, pairing={pairingCode is not null})");
        return await RunSendAsync((progress, token) => _engine.SendTextAsync(target, text, pairingCode, progress, token));
    }

    public async Task<SendOutcome> SendFilesAsync(IReadOnlyList<string> paths, string? pairingCode)
    {
        var peer = SelectedPeer;
        if (peer is null)
        {
            return SendOutcome.Failure("先在左侧选择设备");
        }

        if (paths.Count == 0)
        {
            return SendOutcome.Failure("先选择文件");
        }

        var target = peer.ToPeer();
        AppLog.Write($"send files -> {peer.Name} ({paths.Count} file(s), pairing={pairingCode is not null}): "
            + string.Join(", ", paths.Select(path => $"{Path.GetFileName(path)}={SafeLength(path)}")));
        return await RunSendAsync((progress, token) => _engine.SendFilesAsync(target, paths, pairingCode, progress, token));
    }

    public async Task<SendOutcome> PairSelectedPeerAsync(string pairingCode)
    {
        var peer = SelectedPeer;
        if (peer is null)
        {
            return SendOutcome.Failure("先在左侧选择设备");
        }

        return await PairPeerAsync(peer, pairingCode);
    }

    public async Task<SendOutcome> PairPeerAsync(PeerItemViewModel peer, string pairingCode)
    {
        var target = peer.ToPeer();
        return await RunSendAsync((progress, token) => _engine.PairAsync(target, pairingCode, progress, token));
    }

    public void ClearDraft() => DraftText = string.Empty;

    /// <summary>用户点进度条右边的 ✕：中断本次发送。</summary>
    public void CancelSend()
    {
        try
        {
            _sendCts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // 已经结束了。
        }
    }

    private async Task<SendOutcome> RunSendAsync(
        Func<IProgress<SendProgress>, CancellationToken, Task<SendOutcome>> action)
    {
        if (Busy)
        {
            return SendOutcome.Failure("正在发送，请稍候");
        }

        using var cts = new CancellationTokenSource();
        _sendCts = cts;
        Busy = true;
        SendErrorText = null;
        SendProgress = 0;
        SendLabel = string.Empty;

        var progress = new Progress<SendProgress>(value =>
        {
            OnUi(() =>
            {
                SendProgress = value.Fraction;
                if (!string.IsNullOrEmpty(value.Label))
                {
                    SendLabel = value.Label;
                }
            });
        });

        try
        {
            var outcome = await action(progress, cts.Token);
            AppLog.Write($"send result: {outcome.Status} {outcome.Message}");
            if (!outcome.IsOk && !outcome.IsCancelled && !string.IsNullOrEmpty(outcome.Message))
            {
                SendErrorText = outcome.Message;
            }

            return outcome;
        }
        catch (OperationCanceledException)
        {
            var cancelled = SendOutcome.Cancelled();
            ApplyStatus(new LinkStatus(LinkStatusKind.Idle, "已取消发送"));
            return cancelled;
        }
        catch (Exception exception)
        {
            var message = $"发送失败：{exception.Message}";
            SetLocalFailure(message);
            SendErrorText = message;
            return SendOutcome.Failure(message);
        }
        finally
        {
            _sendCts = null;
            Busy = false;
            SendProgress = 0;
            SendLabel = string.Empty;
        }
    }

    // MARK: - 引擎事件（均在 UI 线程执行）

    private void ApplyStatus(LinkStatus status)
    {
        StatusKind = status.Kind;
        StatusText = status.Text;
    }

    private void ApplyPeers(IReadOnlyList<LinkPeer> snapshot)
    {
        var incoming = new Dictionary<string, LinkPeer>(StringComparer.Ordinal);
        foreach (var peer in snapshot)
        {
            incoming[peer.Id] = peer;
        }

        // 名册：配对过的、有过来往的。它们即使此刻没广播到，也要留在列表里，
        // 只是状态显示为离线——历史记录仍然能打开。
        var known = new Dictionary<string, KnownDevice>(StringComparer.Ordinal);
        foreach (var device in _engine.KnownDevices)
        {
            known[device.Id] = device;
        }

        // 先把所有行标记为离线，再由下面的发现结果点亮。
        foreach (var item in _peers)
        {
            item.MarkOffline();
        }

        // 更新 / 新增在线设备
        foreach (var peer in snapshot)
        {
            var index = IndexOfPeer(peer.Id);
            if (index >= 0)
            {
                _peers[index].Update(peer);
                _peers[index].IsPaired = _engine.IsPaired(peer.Id);
                _peers[index].HasHistory = _engine.HasConversation(peer.Id, peer.Name);
            }
            else
            {
                _peers.Add(new PeerItemViewModel(peer)
                {
                    IsPaired = _engine.IsPaired(peer.Id),
                    HasHistory = _engine.HasConversation(peer.Id, peer.Name),
                });
            }
        }

        // 名册里但没广播到的：补成离线设备
        foreach (var device in known.Values)
        {
            var index = IndexOfPeer(device.Id);
            if (index >= 0)
            {
                _peers[index].IsPaired = _engine.IsPaired(device.Id);
                _peers[index].HasHistory = _engine.HasConversation(device.Id, device.Name);
                continue;
            }

            var item = PeerItemViewModel.FromKnown(device);
            item.IsPaired = _engine.IsPaired(device.Id);
            item.HasHistory = _engine.HasConversation(device.Id, device.Name);
            _peers.Add(item);
        }

        // 只有「既不在广播里、也不在名册里」的才移除
        for (var index = _peers.Count - 1; index >= 0; index--)
        {
            var item = _peers[index];
            if (!incoming.ContainsKey(item.Id) && !known.ContainsKey(item.Id))
            {
                if (ReferenceEquals(_selectedPeer, item))
                {
                    item.IsSelected = false;
                    _selectedPeer = null;
                    OnPropertyChanged(nameof(SelectedPeer));
                }

                _peers.RemoveAt(index);
            }
        }

        SortPeers();

        if (_selectedPeer is null && _peers.Count > 0)
        {
            // 优先选在线的；全离线时选最近有来往的那台，历史记录能直接看到。
            SelectedPeer = _peers.FirstOrDefault(item => item.IsOnline) ?? _peers[0];
        }
        else if (_selectedPeer is not null)
        {
            _selectedPeer.IsSelected = true;
        }

        OnPropertyChanged(nameof(HasPeers));
        OnPropertyChanged(nameof(NoPeers));
        OnPropertyChanged(nameof(PeerCountText));
        RaiseHeaderProperties();
    }

    /// <summary>在线的排前面，其次按最近有来往的时间。</summary>
    private void SortPeers()
    {
        var ordered = _peers
            .OrderByDescending(item => item.IsOnline)
            .ThenByDescending(item => item.LastSeenUtc)
            .ThenBy(item => item.Name, StringComparer.CurrentCulture)
            .ToArray();

        for (var target = 0; target < ordered.Length; target++)
        {
            var current = _peers.IndexOf(ordered[target]);
            if (current >= 0 && current != target)
            {
                _peers.Move(current, target);
            }
        }
    }

    /// <summary>
    /// 切换设备 = 换一份会话缓存。每台设备各自一份，互不串台；
    /// 离线设备照样能翻历史记录。
    /// </summary>
    private void LoadConversation()
    {
        _messages.Clear();

        var peer = _selectedPeer;
        if (peer is not null)
        {
            foreach (var message in _engine.GetConversation(peer.Id, peer.Name))
            {
                _messages.Add(new MessageItemViewModel(message));
            }
        }

        OnPropertyChanged(nameof(MessagesEmpty));
        OnPropertyChanged(nameof(MessageCountText));
    }

    private int IndexOfPeer(string id)
    {
        for (var index = 0; index < _peers.Count; index++)
        {
            if (string.Equals(_peers[index].Id, id, StringComparison.Ordinal))
            {
                return index;
            }
        }

        return -1;
    }

    private void AddMessage(ChatMessage message)
    {
        var peer = _selectedPeer;

        // 消息已经落到它自己那台设备的缓存里了；这里只负责刷新当前正在看的会话，
        // 别的设备发来的消息不该出现在这个窗口里。
        var belongs = peer is not null
            && (!string.IsNullOrEmpty(message.PeerId)
                ? string.Equals(message.PeerId, peer.Id, StringComparison.Ordinal)
                : string.Equals(message.PeerName, peer.Name, StringComparison.Ordinal));
        if (!belongs)
        {
            return;
        }

        peer!.HasHistory = true;
        _messages.Add(new MessageItemViewModel(message));
        OnPropertyChanged(nameof(MessagesEmpty));
        OnPropertyChanged(nameof(MessageCountText));
    }

    private void ClearMessageCollection()
    {
        _messages.Clear();
        OnPropertyChanged(nameof(MessagesEmpty));
        OnPropertyChanged(nameof(MessageCountText));
    }

    private void RefreshPairing()
    {
        PairedCount = _engine.PairedCount;
        foreach (var peer in _peers)
        {
            peer.IsPaired = _engine.IsPaired(peer.Id);
        }

        if (_pendingPairPeerId is not null && _engine.IsPaired(_pendingPairPeerId))
        {
            PendingPairName = null;
            _pendingPairPeerId = null;
        }

        RaiseHeaderProperties();
    }

    private void ApplyPairRequest(PairRequestEventArgs eventArgs)
    {
        _pendingPairPeerId = eventArgs.PeerId;
        PendingPairName = eventArgs.PeerName;
    }

    /// <summary>日志用：文件大小，读不到就打个问号，绝不能因为日志把发送搞挂。</summary>
    private static string SafeLength(string path)
    {
        try
        {
            return new FileInfo(path).Length.ToString();
        }
        catch (Exception)
        {
            return "?";
        }
    }

    private void RaiseHeaderProperties()
    {
        OnPropertyChanged(nameof(HeaderTitle));
        OnPropertyChanged(nameof(HeaderStatusText));
        OnPropertyChanged(nameof(TargetHint));
        OnPropertyChanged(nameof(ShowPairButton));
        OnPropertyChanged(nameof(HasSelectedPeer));
    }

    private void RaiseComposeProperties()
    {
        OnPropertyChanged(nameof(CanCompose));
        OnPropertyChanged(nameof(CanSendText));
        OnPropertyChanged(nameof(ShowPairButton));
    }

    // MARK: - 演示数据（--demo / --screenshot 用，不启动网络）

    public static MainViewModel CreateDemo(bool heavy = false)
    {
        var demoEngine = new LinkEngine(new LinkEngineOptions
        {
            DataDirectory = Path.Combine(Path.GetTempPath(), "ADBTypeLink-demo"),
            ReceiveDirectory = @"C:\Users\pichs\Downloads\ADBType 接收",
            DeviceName = "DESKTOP-WIN11",
            DeviceId = "demo-windows-device",
            PairingCode = "483920",
        });

        var viewModel = new MainViewModel(demoEngine);
        viewModel.LoadDemoData(heavy);

        // 截图 / 演示模式也让「移动设备」页拿到真实设备列表，界面上不会空着。
        _ = viewModel.Mobile.InitializeAsync();
        return viewModel;
    }

    private void LoadDemoData(bool heavy)
    {
        DeviceName = "DESKTOP-WIN11";
        PairingCode = "483920";
        ReceiveDir = @"C:\Users\pichs\Downloads\ADBType 接收";
        PairedCount = 1;

        var mac = new PeerItemViewModel(new LinkPeer
        {
            Id = "demo-mac",
            Name = "pichs 的 MacBook Pro",
            Host = "192.168.1.23",
            Port = 52810,
            LastSeenUtc = DateTime.UtcNow,
        })
        {
            IsPaired = true,
        };

        var studio = new PeerItemViewModel(new LinkPeer
        {
            Id = "demo-studio",
            Name = "Studio Mac mini",
            Host = "192.168.1.31",
            Port = 52844,
            LastSeenUtc = DateTime.UtcNow,
        });

        // 演示：一台离线但有历史记录的设备，验证它仍然留在列表里、状态不同。
        var offline = PeerItemViewModel.FromKnown(new KnownDevice
        {
            Id = "demo-imac",
            Name = "家里的 iMac",
            LastSeenUtc = DateTime.UtcNow.AddHours(-5),
        });
        offline.IsPaired = true;
        offline.HasHistory = true;

        _peers.Add(mac);
        _peers.Add(studio);
        _peers.Add(offline);
        OnPropertyChanged(nameof(HasPeers));
        OnPropertyChanged(nameof(NoPeers));
        OnPropertyChanged(nameof(PeerCountText));

        var now = DateTimeOffset.Now;
        _messages.Add(new MessageItemViewModel(new ChatMessage
        {
            Direction = MessageDirection.Incoming,
            PeerName = "pichs 的 MacBook Pro",
            Kind = MessageKind.Text,
            Text = "在吗？我把 Windows 端的设计稿发你一下",
            Date = now.AddMinutes(-18),
        }));
        _messages.Add(new MessageItemViewModel(new ChatMessage
        {
            Direction = MessageDirection.Outgoing,
            PeerName = "pichs 的 MacBook Pro",
            Kind = MessageKind.Text,
            Text = "好的，发过来吧 👍",
            Date = now.AddMinutes(-17),
        }));
        _messages.Add(new MessageItemViewModel(new ChatMessage
        {
            Direction = MessageDirection.Outgoing,
            PeerName = "pichs 的 MacBook Pro",
            Kind = MessageKind.File,
            FileName = "文件互传助手-windows-v1.2.zip",
            FilePath = @"C:\Users\pichs\Downloads\ADBType 接收\文件互传助手-windows-v1.2.zip",
            FileSize = 12_700_000,
            Date = now.AddMinutes(-15),
        }));
        _messages.Add(new MessageItemViewModel(new ChatMessage
        {
            Direction = MessageDirection.Incoming,
            PeerName = "pichs 的 MacBook Pro",
            Kind = MessageKind.File,
            FileName = "产品截图 2026-11-02.png",
            FilePath = @"C:\Users\pichs\Downloads\ADBType 接收\产品截图 2026-11-02.png",
            FileSize = 848_000,
            Date = now.AddMinutes(-12),
        }));
        _messages.Add(new MessageItemViewModel(new ChatMessage
        {
            Direction = MessageDirection.Outgoing,
            PeerName = "pichs 的 MacBook Pro",
            Kind = MessageKind.Text,
            Text = "收到了，中文、emoji 😀 和文件都正常。这条是右对齐的气泡，长文本会自动换行，超过一行的内容也不会把窗口撑宽。",
            Date = now.AddMinutes(-9),
        }));

        if (heavy)
        {
            // 塞满聊天区，验证「新消息自动滚到底部」。
            for (var index = 24; index >= 1; index--)
            {
                var outgoing = index % 2 == 0;
                _messages.Add(new MessageItemViewModel(new ChatMessage
                {
                    Direction = outgoing ? MessageDirection.Outgoing : MessageDirection.Incoming,
                    PeerName = "pichs 的 MacBook Pro",
                    Kind = MessageKind.Text,
                    Text = $"演示消息 #{index}：这是一条用于验证自动滚动的内容，长度不一但都会自动换行。",
                    Date = now.AddMinutes(-index * 2),
                }));
            }

            _messages.Add(new MessageItemViewModel(new ChatMessage
            {
                Direction = MessageDirection.Incoming,
                PeerName = "pichs 的 MacBook Pro",
                Kind = MessageKind.Text,
                Text = "最后一条：列表应该已经自动滚动到底部，输入框仍固定在窗口底部。",
                Date = now,
            }));
        }

        OnPropertyChanged(nameof(MessagesEmpty));
        OnPropertyChanged(nameof(MessageCountText));

        _stagedFiles.Add(new StagedFileViewModel(@"C:\Users\pichs\Desktop\发票.pdf", "发票.pdf", "220 KB"));
        _stagedFiles.Add(new StagedFileViewModel(@"C:\Users\pichs\Desktop\会议纪要.docx", "会议纪要.docx", "36 KB"));
        RaiseStagedProperties();

        SelectedPeer = mac;
        PendingPairName = "Studio Mac mini";
        _pendingPairPeerId = "demo-studio";
        StatusKind = LinkStatusKind.Idle;
        StatusText = "发现 2 台设备";
        RefreshHeaderOnly();
    }

    private void RefreshHeaderOnly()
    {
        OnPropertyChanged(nameof(HeaderTitle));
        OnPropertyChanged(nameof(HeaderStatusText));
        OnPropertyChanged(nameof(TargetHint));
        OnPropertyChanged(nameof(ShowPairButton));
        OnPropertyChanged(nameof(HasSelectedPeer));
    }
}
