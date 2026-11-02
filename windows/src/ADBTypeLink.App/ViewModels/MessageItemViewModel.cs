using ADBTypeLink.Core;
using Avalonia.Layout;

namespace ADBTypeLink.App.ViewModels;

/// <summary>聊天区里的一条消息（文字或文件卡片）。</summary>
public sealed class MessageItemViewModel
{
    public MessageItemViewModel(ChatMessage message)
    {
        Message = message;
    }

    public ChatMessage Message { get; }

    public string Id => Message.Id;

    public bool IsOutgoing => Message.Direction == MessageDirection.Outgoing;

    public bool IsIncoming => !IsOutgoing;

    public bool IsText => Message.Kind == MessageKind.Text;

    public bool IsFile => !IsText;

    public string? Text => Message.Text;

    public string FileName => string.IsNullOrEmpty(Message.FileName) ? "文件" : Message.FileName!;

    public string TimeText => FormatTime(Message.Date);

    public string SenderLabel => IsOutgoing ? $"我 → {Message.PeerName}" : Message.PeerName;

    public string AvatarText => IsOutgoing ? "我" : PeerItemViewModel.FirstTextElement(Message.PeerName);

    public string OpenButtonText => IsOutgoing ? "打开" : "显示";

    public HorizontalAlignment BubbleAlignment => IsOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left;

    public string FileMeta
    {
        get
        {
            var parts = new List<string>();
            if (Message.FileSize is > 0)
            {
                parts.Add(FormatSize(Message.FileSize.Value));
            }

            parts.Add(IsOutgoing ? "已发送" : "已保存");
            return string.Join(" · ", parts);
        }
    }

    public static string FormatTime(DateTimeOffset date)
    {
        var local = date.ToLocalTime();
        var today = DateTimeOffset.Now.Date;
        return local.Date == today
            ? local.ToString("HH:mm")
            : local.ToString("M月d日 HH:mm");
    }

    public static string FormatSize(long bytes)
    {
        if (bytes < 1024)
        {
            return $"{bytes} B";
        }

        double value = bytes;
        string[] units = { "KB", "MB", "GB", "TB" };
        foreach (var unit in units)
        {
            value /= 1024;
            if (value < 1024)
            {
                return value >= 100 ? $"{value:F0} {unit}" : $"{value:F1} {unit}";
            }
        }

        return $"{value:F1} PB";
    }
}
