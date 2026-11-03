using ADBTypeLink.Core;
using Avalonia.Layout;
using Avalonia.Media;

namespace ADBTypeLink.App.ViewModels;

/// <summary>聊天区里的一条消息（文字或文件卡片）。</summary>
public sealed class MessageItemViewModel : ObservableObject
{
    private bool _fileMissing;

    public MessageItemViewModel(ChatMessage message)
    {
        Message = message;
        RefreshFileState();
    }

    /// <summary>
    /// 记录里的文件还在不在。文件被移走或删掉之后，这条记录要能看出来——
    /// 否则点「打开」毫无反应，用户不知道是程序坏了还是文件没了。
    /// </summary>
    public bool FileMissing
    {
        get => _fileMissing;
        private set
        {
            if (SetProperty(ref _fileMissing, value))
            {
                OnPropertyChanged(nameof(FileNameDecorations));
                OnPropertyChanged(nameof(FileIconOpacity));
                OnPropertyChanged(nameof(FileTextOpacity));
                OnPropertyChanged(nameof(FileMeta));
            }
        }
    }

    /// <summary>文件没了就给文件名加删除线。</summary>
    public TextDecorationCollection? FileNameDecorations =>
        _fileMissing ? TextDecorations.Strikethrough : null;

    /// <summary>删掉的文件整行淡一点，一眼能看出这条记录已经失效。</summary>
    public double FileIconOpacity => _fileMissing ? 0.35 : 1;

    public double FileTextOpacity => _fileMissing ? 0.6 : 1;

    /// <summary>重新检查磁盘上的文件（右键菜单弹出前、切换会话时各调一次）。</summary>
    public void RefreshFileState()
    {
        if (!IsFile)
        {
            FileMissing = false;
            return;
        }

        FileMissing = string.IsNullOrEmpty(Message.FilePath) || !File.Exists(Message.FilePath);
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

            if (_fileMissing)
            {
                parts.Add("文件已删除");
            }
            else
            {
                parts.Add(IsOutgoing ? "已发送" : "已保存");
            }

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
