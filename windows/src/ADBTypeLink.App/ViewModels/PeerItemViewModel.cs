using System.Globalization;
using ADBTypeLink.Core;

namespace ADBTypeLink.App.ViewModels;

/// <summary>左侧「附近设备」里的一行。</summary>
public sealed class PeerItemViewModel : ObservableObject
{
    private LinkPeer _peer;
    private bool _isSelected;
    private bool _isPaired;

    public PeerItemViewModel(LinkPeer peer)
    {
        _peer = peer;
    }

    public string Id => _peer.Id;

    public string Name => _peer.Name;

    public string Host => _peer.Host;

    public int Port => _peer.Port;

    /// <summary>头像里的首字（支持 emoji / 代理对）。</summary>
    public string AvatarText => FirstTextElement(Name);

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
                OnPropertyChanged(nameof(PairBadgeText));
            }
        }
    }

    public bool CanPair => !IsPaired;

    public string PairBadgeText => IsPaired ? "已配对" : "未配对";

    public string EndpointText => $"{Host}:{Port}";

    public void Update(LinkPeer peer)
    {
        _peer = peer;
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
