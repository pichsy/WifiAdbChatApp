using Avalonia.Media.Imaging;
using ADBTypeLink.Core;

namespace ADBTypeLink.App.ViewModels;

/// <summary>手机文件浏览窗口中的一行 / 一个网格卡片。</summary>
public sealed class FileBrowserItem : ObservableObject
{
    private Bitmap? _thumbnail;
    private bool _thumbnailLoading;
    private bool _thumbnailFailed;
    private bool _isSelected;

    public FileBrowserItem(DeviceFileEntry entry)
    {
        Entry = entry;
    }

    public DeviceFileEntry Entry { get; }

    public string Name => Entry.Name;
    public string Path => Entry.Path;
    public bool IsDirectory => Entry.IsDirectory;
    public bool IsSymlink => Entry.IsSymlink;
    public string SizeText => Entry.SizeText;
    public string Modified => Entry.Modified;
    public string Permissions => Entry.Permissions;
    public string? LinkTarget => Entry.LinkTarget;

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    public Bitmap? Thumbnail
    {
        get => _thumbnail;
        set => SetProperty(ref _thumbnail, value);
    }

    public bool ThumbnailLoading
    {
        get => _thumbnailLoading;
        set => SetProperty(ref _thumbnailLoading, value);
    }

    public bool ThumbnailFailed
    {
        get => _thumbnailFailed;
        set => SetProperty(ref _thumbnailFailed, value);
    }

    public bool Media => ThumbnailLoader.Supports(Entry);

    public string Icon
    {
        get
        {
            if (IsDirectory) return IsSymlink ? "🔗" : "📁";
            var ext = System.IO.Path.GetExtension(Name).TrimStart('.').ToLowerInvariant();
            return ext switch
            {
                "png" or "jpg" or "jpeg" or "gif" or "webp" or "heic" or "bmp" or "tif" or "tiff" or "avif" => "🖼",
                "mp4" or "mov" or "mkv" or "webm" or "avi" or "m4v" or "3gp" => "🎬",
                "mp3" or "wav" or "m4a" or "flac" or "aac" => "🎵",
                "apk" or "zip" or "rar" or "7z" or "gz" or "tar" => "📦",
                "txt" or "log" or "json" or "xml" or "md" or "conf" or "ini" or "yml" or "yaml" => "📄",
                "pdf" => "📕",
                _ => "📄"
            };
        }
    }

    public async Task LoadThumbnailAsync(DeviceFileService service, string serial, CancellationToken cancellationToken = default)
    {
        if (!Media || Thumbnail is not null || ThumbnailLoading) return;
        ThumbnailLoading = true;
        try
        {
            var bitmap = await ThumbnailLoader.LoadAsync(service, serial, Entry, cancellationToken).ConfigureAwait(true);
            Thumbnail = bitmap;
            ThumbnailFailed = bitmap is null;
        }
        catch (Exception)
        {
            ThumbnailFailed = true;
        }
        finally
        {
            ThumbnailLoading = false;
        }
    }
}
