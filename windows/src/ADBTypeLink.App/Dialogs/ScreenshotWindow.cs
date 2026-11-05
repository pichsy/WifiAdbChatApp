using System;
using System.IO;
using System.Threading.Tasks;
using ADBTypeLink.App.Helpers;
using ADBTypeLink.App.ViewModels;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace ADBTypeLink.App.Dialogs;

/// <summary>
/// 「手机截屏」窗口：独立可缩放窗口，滚轮/拖拽缩放，1:1 恢复适应窗口，保存到指定目录。
/// 对应 macOS 端 ScreenshotSheet + ScreenshotWindow。
/// </summary>
public sealed class ScreenshotWindow : Window
{
    private const double MinZoom = 1;
    private const double MaxZoom = 5;

    private static ScreenshotWindow? _current;

    private readonly MobileDeviceViewModel _mobile;
    private readonly Image _image = new();
    private readonly ScaleTransform _scale = new(1, 1);
    private readonly TranslateTransform _translate = new();
    private readonly TextBlock _percentText = new();
    private readonly TextBlock _statusText = new();
    private readonly TextBlock _pathText = new();
    private readonly TextBlock _dateText = new();
    private readonly Border _preview;
    private readonly Border _toast;
    private readonly ProgressBar _progress;
    private readonly Button _refreshButton;
    private readonly Button _saveButton;
    private readonly Button _resetButton;
    private readonly DispatcherTimer _toastTimer = new() { Interval = TimeSpan.FromSeconds(2) };

    private Bitmap? _bitmap;
    private byte[]? _png;
    private string _saveDir;
    private bool _busy;
    private bool _dragging;
    private Point _dragStart;
    private double _dragBaseX;
    private double _dragBaseY;
    private double _zoom = 1;

    private ScreenshotWindow(MobileDeviceViewModel mobile)
    {
        _mobile = mobile;
        _saveDir = LoadSaveDir();

        Title = "手机截屏";
        Width = 900;
        Height = 720;
        MinWidth = 780;
        MinHeight = 500;
        CanResize = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        _image.Stretch = Stretch.Uniform;
        _image.HorizontalAlignment = HorizontalAlignment.Stretch;
        _image.VerticalAlignment = VerticalAlignment.Stretch;
        _image.RenderTransformOrigin = new RelativePoint(0.5, 0.5, RelativeUnit.Relative);
        var transform = new TransformGroup();
        transform.Children.Add(_scale);
        transform.Children.Add(_translate);
        _image.RenderTransform = transform;

        _progress = new ProgressBar
        {
            IsIndeterminate = true,
            Width = 180,
            Height = 4,
            IsVisible = false,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var previewGrid = new Grid();
        previewGrid.Children.Add(_image);
        previewGrid.Children.Add(_progress);

        _preview = new Border
        {
            Background = Brushes.Black,
            ClipToBounds = true,
            Child = previewGrid,
        };
        _preview.PointerWheelChanged += OnPreviewWheel;
        _preview.PointerPressed += OnPreviewPressed;
        _preview.PointerMoved += OnPreviewMoved;
        _preview.PointerReleased += OnPreviewReleased;
        _preview.PointerCaptureLost += (_, _) => _dragging = false;
        SizeChanged += (_, _) => ClampPan();

        _refreshButton = MakeButton("刷新截屏", () => _ = CaptureAsync());
        _saveButton = MakeButton("保存截屏", SaveScreenshot);
        _resetButton = MakeButton("1:1", ResetZoom);
        _saveButton.IsEnabled = false;
        _resetButton.IsEnabled = false;
        var chooseButton = MakeButton("保存位置…", () => _ = ChooseFolderAsync());
        var closeButton = MakeButton("关闭", () => Close());

        _percentText.Text = "100%";
        _percentText.FontSize = 9;
        _percentText.HorizontalAlignment = HorizontalAlignment.Center;
        _percentText.Foreground = Brush(0x88, 0x88, 0x88);

        _dateText.FontSize = 11;
        _dateText.Foreground = Brush(0x88, 0x88, 0x88);
        _dateText.VerticalAlignment = VerticalAlignment.Center;

        _pathText.FontSize = 11;
        _pathText.Foreground = Brush(0x88, 0x88, 0x88);
        _pathText.TextTrimming = TextTrimming.CharacterEllipsis;
        _pathText.Text = $"保存到：{_saveDir}";

        _statusText.FontSize = 11;
        _statusText.Foreground = Brush(0x88, 0x88, 0x88);
        _statusText.TextWrapping = TextWrapping.Wrap;

        var header = BuildHeader(chooseButton, closeButton);
        var footer = new StackPanel
        {
            Spacing = 4,
            Margin = new Thickness(16, 10),
            Children = { _pathText, _statusText },
        };

        var grid = new Grid
        {
            RowDefinitions = new RowDefinitions("Auto,*,Auto"),
        };
        Grid.SetRow(header, 0);
        Grid.SetRow(_preview, 1);
        Grid.SetRow(footer, 2);
        grid.Children.Add(header);
        grid.Children.Add(_preview);
        grid.Children.Add(footer);

        var toastText = new TextBlock
        {
            Text = "✓  截屏已保存",
            Foreground = Brushes.White,
            FontSize = 12,
            FontWeight = FontWeight.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _toast = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(235, 32, 32, 32)),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(18, 10),
            Child = toastText,
            IsVisible = false,
            IsHitTestVisible = false,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 58),
        };

        var root = new Panel();
        root.Children.Add(grid);
        root.Children.Add(_toast);
        Content = root;

        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            _toast.IsVisible = false;
        };

        Opened += (_, _) =>
        {
            WindowEffects.ApplyRoundedCorners(this);
            _ = CaptureAsync();
        };
        Closed += (_, _) =>
        {
            _toastTimer.Stop();
            _bitmap?.Dispose();
            _bitmap = null;
            if (ReferenceEquals(_current, this))
            {
                _current = null;
            }
        };
    }

    /// <summary>打开截屏窗口；已经打开时刷新当前屏幕并把窗口提到前台。</summary>
    public static void Present(MobileDeviceViewModel mobile)
    {
        if (_current is { } existing)
        {
            existing.Activate();
            _ = existing.CaptureAsync();
            return;
        }

        var window = new ScreenshotWindow(mobile);
        _current = window;
        window.Show();
        window.Activate();
    }

    private Control BuildHeader(Button chooseButton, Button closeButton)
    {
        var title = new TextBlock
        {
            Text = "手机截屏",
            FontSize = 16,
            FontWeight = FontWeight.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var titlePanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { title, _dateText },
        };

        var zoomPanel = new StackPanel
        {
            Spacing = 1,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _percentText, _resetButton },
        };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _refreshButton, zoomPanel, _saveButton, chooseButton, closeButton },
        };

        var header = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
            Margin = new Thickness(16, 10),
        };
        Grid.SetColumn(buttons, 1);
        header.Children.Add(titlePanel);
        header.Children.Add(buttons);
        return header;
    }

    private static Button MakeButton(string text, Action action)
    {
        var button = new Button { Content = text };
        button.Click += (_, _) => action();
        return button;
    }

    private async Task CaptureAsync()
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        SetBusy(true);
        _statusText.Text = "正在截取手机屏幕…";
        _statusText.Foreground = Brush(0x88, 0x88, 0x88);

        try
        {
            var (data, error) = await _mobile.CaptureScreenshotAsync();
            if (data is null || data.Length == 0)
            {
                _statusText.Text = error ?? "截屏失败";
                _statusText.Foreground = Brush(0xD1, 0x5B, 0x4A);
                return;
            }

            SetImage(data);
            _png = data;
            ResetZoom();
            _dateText.Text = DateTime.Now.ToString("HH:mm:ss");
            _statusText.Text = $"已截取 {_mobile.SelectedDevice?.DisplayName ?? "手机"} 的屏幕";
            _statusText.Foreground = Brush(0x88, 0x88, 0x88);
        }
        finally
        {
            _busy = false;
            SetBusy(false);
        }
    }

    private void SetBusy(bool busy)
    {
        _progress.IsVisible = busy;
        _refreshButton.IsEnabled = !busy;
        _saveButton.IsEnabled = !busy && _png is not null;
        _resetButton.IsEnabled = !busy && _png is not null;
    }


    private void SetImage(byte[] data)
    {
        _bitmap?.Dispose();
        using var stream = new MemoryStream(data);
        _bitmap = new Bitmap(stream);
        _image.Source = _bitmap;
    }

    private void ResetZoom()
    {
        _zoom = 1;
        _scale.ScaleX = 1;
        _scale.ScaleY = 1;
        _translate.X = 0;
        _translate.Y = 0;
        _percentText.Text = "100%";
    }

    private void ApplyZoom(double zoom)
    {
        _zoom = Math.Clamp(zoom, MinZoom, MaxZoom);
        _scale.ScaleX = _zoom;
        _scale.ScaleY = _zoom;
        _percentText.Text = $"{(int)Math.Round(_zoom * 100)}%";
        if (_zoom <= 1.001)
        {
            _translate.X = 0;
            _translate.Y = 0;
        }

        ClampPan();
    }

    private void ClampPan()
    {
        if (_zoom <= 1.001 || _preview.Bounds.Width <= 0 || _preview.Bounds.Height <= 0)
        {
            _translate.X = 0;
            _translate.Y = 0;
            return;
        }

        var maxX = Math.Max(0, (_preview.Bounds.Width * (_zoom - 1)) / 2);
        var maxY = Math.Max(0, (_preview.Bounds.Height * (_zoom - 1)) / 2);
        _translate.X = Math.Clamp(_translate.X, -maxX, maxX);
        _translate.Y = Math.Clamp(_translate.Y, -maxY, maxY);
    }

    private void OnPreviewWheel(object? sender, PointerWheelEventArgs e)
    {
        if (_png is null)
        {
            return;
        }

        var factor = Math.Exp(e.Delta.Y * 0.14);
        ApplyZoom(_zoom * factor);
        e.Handled = true;
    }

    private void OnPreviewPressed(object? sender, PointerPressedEventArgs e)
    {
        if (_png is null || _zoom <= 1.001)
        {
            return;
        }

        _dragging = true;
        _dragStart = e.GetPosition(_preview);
        _dragBaseX = _translate.X;
        _dragBaseY = _translate.Y;
        e.Pointer.Capture(_preview);
        e.Handled = true;
    }

    private void OnPreviewMoved(object? sender, PointerEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        var position = e.GetPosition(_preview);
        _translate.X = _dragBaseX + (position.X - _dragStart.X);
        _translate.Y = _dragBaseY + (position.Y - _dragStart.Y);
        ClampPan();
        e.Handled = true;
    }

    private void OnPreviewReleased(object? sender, PointerReleasedEventArgs e)
    {
        _dragging = false;
        e.Pointer.Capture(null!);
        e.Handled = true;
    }

    private void SaveScreenshot()
    {
        if (_png is null)
        {
            _statusText.Text = "还没有截屏可保存";
            _statusText.Foreground = Brush(0xD1, 0x5B, 0x4A);
            return;
        }

        try
        {
            if (!Directory.Exists(_saveDir))
            {
                _saveDir = DefaultSaveDir();
                SaveSaveDir(_saveDir);
                _pathText.Text = $"保存到：{_saveDir}";
            }

            Directory.CreateDirectory(_saveDir);
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var path = Path.Combine(_saveDir, $"截屏-{stamp}.png");
            var index = 2;
            while (File.Exists(path))
            {
                path = Path.Combine(_saveDir, $"截屏-{stamp} ({index}).png");
                index++;
            }

            File.WriteAllBytes(path, _png);
            _statusText.Text = $"截屏已保存到 {path}";
            _statusText.Foreground = Brush(0x88, 0x88, 0x88);
            ShowToast();
        }
        catch (Exception ex)
        {
            _statusText.Text = $"保存截屏失败：{ex.Message}";
            _statusText.Foreground = Brush(0xD1, 0x5B, 0x4A);
        }
    }

    private async Task ChooseFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "选择截屏保存目录",
            AllowMultiple = false,
        });
        if (folders.Count == 0)
        {
            return;
        }

        var path = folders[0].Path.LocalPath;
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        _saveDir = path;
        SaveSaveDir(path);
        _pathText.Text = $"保存到：{_saveDir}";
        _statusText.Text = $"截屏保存目录已改为 {_saveDir}";
        _statusText.Foreground = Brush(0x88, 0x88, 0x88);
    }

    private void ShowToast()
    {
        _toast.IsVisible = true;
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    private static SolidColorBrush Brush(byte r, byte g, byte b) => new(Color.FromRgb(r, g, b));

    private static string DefaultSaveDir()
    {
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        if (Directory.Exists(downloads))
        {
            return downloads;
        }

        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        return string.IsNullOrWhiteSpace(documents) ? downloads : documents;
    }

    private static string SettingsFile() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ADBTypeLink",
        "screenshot-dir.txt");

    private static string LoadSaveDir()
    {
        try
        {
            var file = SettingsFile();
            if (File.Exists(file))
            {
                var saved = File.ReadAllText(file).Trim();
                if (!string.IsNullOrWhiteSpace(saved))
                {
                    return saved;
                }
            }
        }
        catch (Exception)
        {
            // 读不到就用默认目录。
        }

        return DefaultSaveDir();
    }

    private static void SaveSaveDir(string directory)
    {
        try
        {
            var file = SettingsFile();
            var parent = Path.GetDirectoryName(file);
            if (!string.IsNullOrEmpty(parent))
            {
                Directory.CreateDirectory(parent);
            }

            File.WriteAllText(file, directory);
        }
        catch (Exception)
        {
            // 保存目录持久化失败不影响本次保存。
        }
    }
}
