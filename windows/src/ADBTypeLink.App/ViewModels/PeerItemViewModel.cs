using System.Globalization;
using ADBTypeLink.Core;

namespace ADBTypeLink.App.ViewModels;

/// <summary>左侧「附近设备」里的一行。</summary>
public sealed class PeerItemViewModel : ObservableObject
{
    /// <summary>超过这个时间没收到广播，就认为链路已经断了（引擎 18 秒才真正移除）。</summary>
    private static readonly TimeSpan OnlineWindow = TimeSpan.FromSeconds(6);

    /// <summary>TCP 探测成功后，这段时间内都显示在线（探测每 5 秒一次）。</summary>
    private static readonly TimeSpan ProbeWindow = TimeSpan.FromSeconds(9);

    private LinkPeer _peer;
    private DateTime _lastSeenUtc;
    private bool _hasHistory;
    private bool _isSelected;
    private bool _isPaired;
    private bool _isOnline = true;
    private DateTime _probeOkUtc = DateTime.MinValue;
    private bool _isProbing;
    private string? _alias;

    public PeerItemViewModel(LinkPeer peer)
    {
        _peer = peer;
        _lastSeenUtc = peer.LastSeenUtc;
        _isOnline = IsFresh(peer.LastSeenUtc, DateTime.UtcNow);
    }

    /// <summary>
    /// 名册里的设备：此刻没广播到，但配对过或者有过来往。
    /// 它必须留在列表里——历史记录还在，只是连接状态不同。
    /// </summary>
    public static PeerItemViewModel FromKnown(Friend friend)
    {
        var item = new PeerItemViewModel(new LinkPeer
        {
            Id = friend.Id,
            Name = friend.Name,
            Host = friend.Host,
            Port = friend.Port,
            LastSeenUtc = friend.LastSeenUtc,
        })
        {
            IsKnown = true,
            Alias = friend.Alias,
        };

        item.IsOnline = false;
        return item;
    }

    /// <summary>本地别名（friends.json 里的 alias），优先于设备名显示。</summary>
    public string? Alias
    {
        get => _alias;
        set
        {
            if (SetProperty(ref _alias, value))
            {
                OnPropertyChanged(nameof(DisplayName));
                OnPropertyChanged(nameof(AvatarText));
            }
        }
    }

    /// <summary>界面上显示的名字：有别名用别名。</summary>
    public string DisplayName => string.IsNullOrWhiteSpace(_alias) ? _peer.Name : _alias!;

    /// <summary>是不是从名册里恢复出来的（持久化过）。</summary>
    public bool IsKnown { get; init; }

    /// <summary>跟这台设备有没有聊过。</summary>
    public bool HasHistory
    {
        get => _hasHistory;
        set
        {
            if (SetProperty(ref _hasHistory, value))
            {
                OnPropertyChanged(nameof(PresenceText));
            }
        }
    }

    /// <summary>最近一次有来往的时间（离线时用来显示「上次 …」）。</summary>
    public DateTime LastSeenUtc => _lastSeenUtc;

    /// <summary>掉线但设备仍然留着。</summary>
    public void MarkOffline() => IsOnline = false;

    /// <summary>
    /// 链路是否还活着。原来界面上「在线」两个字是写死的，
    /// 设备其实早就掉线了也照样显示在线，用户完全无从判断。
    /// </summary>
    public bool IsOnline
    {
        get => _isOnline;
        private set
        {
            if (SetProperty(ref _isOnline, value))
            {
                OnPropertyChanged(nameof(PresenceText));
                OnPropertyChanged(nameof(CanPairNow));
            }
        }
    }

    /// <summary>
    /// 设备行里显示的链路状态。在线就写在线；不在线但配对过/有记录，
    /// 就写「离线 · 上次 …」——不能写成「正在重连」，那会让人以为它还活着。
    /// </summary>
    public string PresenceText
    {
        get
        {
            if (_isProbing)
            {
                return "正在重连…";
            }

            if (_isOnline)
            {
                return "在线";
            }

            if (IsKnown || HasHistory)
            {
                var last = LastSeenText;
                return string.IsNullOrEmpty(last) ? "离线" : $"离线 · 上次 {last}";
            }

            return "连接中断，正在重连…";
        }
    }

    public string LastSeenText
    {
        get
        {
            if (_lastSeenUtc == DateTime.MinValue)
            {
                return string.Empty;
            }

            var local = _lastSeenUtc.ToLocalTime();
            var today = DateTime.Now.Date;
            if (local.Date == today)
            {
                return local.ToString("HH:mm", CultureInfo.CurrentCulture);
            }

            if (local.Date == today.AddDays(-1))
            {
                return "昨天 " + local.ToString("HH:mm", CultureInfo.CurrentCulture);
            }

            return local.ToString("M月d日 HH:mm", CultureInfo.CurrentCulture);
        }
    }

    /// <summary>按最近一次广播时间刷新在线状态（由 UI 定时器驱动）。</summary>
    public void RefreshPresence(DateTime utcNow)
    {
        IsOnline = IsFresh(_peer.LastSeenUtc, utcNow)
            || utcNow - _probeOkUtc <= ProbeWindow;
    }

    /// <summary>TCP 探测成功：UDP 广播可能是丢的，但链路其实是通的。</summary>
    public void MarkReachable(DateTime utcNow)
    {
        _probeOkUtc = utcNow;
        IsOnline = true;
    }

    /// <summary>最近一次 TCP 探测成功的时间（用来决定要不要再探）。</summary>
    public DateTime ProbeOkUtc => _probeOkUtc;

    public bool IsProbing
    {
        get => _isProbing;
        set
        {
            if (SetProperty(ref _isProbing, value))
            {
                OnPropertyChanged(nameof(PresenceText));
            }
        }
    }

    private static bool IsFresh(DateTime lastSeenUtc, DateTime utcNow) =>
        utcNow - lastSeenUtc <= OnlineWindow;

    public string Id => _peer.Id;

    public string Name => _peer.Name;

    public string Host => _peer.Host;

    public int Port => _peer.Port;

    /// <summary>头像里的首字（支持 emoji / 代理对）。</summary>
    public string AvatarText => FirstTextElement(DisplayName);

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    public bool IsPaired
    {
        get => _isPaired;
        set
        {
            if (SetProperty(ref _isPaired, value))
            {
                OnPropertyChanged(nameof(CanPair));
                OnPropertyChanged(nameof(CanPairNow));
                OnPropertyChanged(nameof(PairBadgeText));
            }
        }
    }

    public bool CanPair => !IsPaired;

    /// <summary>离线设备没法发起配对，别给个点了必然失败的按钮。</summary>
    public bool CanPairNow => !IsPaired && IsOnline;

    public string PairBadgeText => IsPaired ? "已配对" : "未配对";

    public string EndpointText => $"{Host}:{Port}";

    public void Update(LinkPeer peer)
    {
        _peer = peer;
        _lastSeenUtc = peer.LastSeenUtc;
        RefreshPresence(DateTime.UtcNow);
        OnPropertyChanged(nameof(LastSeenUtc));
        OnPropertyChanged(nameof(LastSeenText));
        OnPropertyChanged(nameof(Name));
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(Port));
        OnPropertyChanged(nameof(AvatarText));
        OnPropertyChanged(nameof(EndpointText));
    }

    public LinkPeer ToPeer() => _peer;

    internal static string FirstTextElement(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "?";
        }

        try
        {
            var element = StringInfo.GetNextTextElement(value.Trim());
            return string.IsNullOrEmpty(element) ? "?" : element.ToUpperInvariant();
        }
        catch (Exception)
        {
            return "?";
        }
    }
}
