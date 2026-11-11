using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using ADBTypeLink.App.Dialogs;
using ADBTypeLink.App.Helpers;
using ADBTypeLink.App.ViewModels;
using ADBTypeLink.Core;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Data;
using Avalonia.Data.Converters;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;

namespace ADBTypeLink.App;

/// <summary>
/// 手机文件浏览窗口：复刻 macOS 端的布局和交互。
/// 独立的 Avalonia Window，左侧常用目录，右侧列表/网格，支持多选、右键、上传下载和缩略图。
/// </summary>
public sealed class FileBrowserWindow : Window
{
    private static readonly Dictionary<string, FileBrowserWindow> Windows = new(StringComparer.Ordinal);
    private static readonly HashSet<string> RootHiddenLinks = new(StringComparer.Ordinal)
    {
        "bin", "bugreports", "cache", "d", "etc", "init"
    };

    private readonly MobileDeviceViewModel _mobile;
    private readonly AdbService _adb;
    private readonly DeviceFileService _service;
    private readonly string _serial;
    private readonly string _deviceName;
    private readonly ObservableCollection<FileBrowserItem> _items = new();
    private readonly Stack<string> _backStack = new();
    private readonly HashSet<string> _selectedPaths = new(StringComparer.Ordinal);

    private string _path = "/sdcard";
    private string? _pendingSelectPath;
    private bool _gridMode;
    private bool _showHidden;
    private bool _busy;
    private bool _syncingSelection;
    private string? _selectionAnchor;

    private readonly ListBox _listBox;
    private readonly ListBox _gridBox;
    private readonly TextBox _pathBox;
    private readonly TextBlock _statusText;
    private readonly TextBlock _countText;
    private readonly TextBlock _titleText;
    private readonly ProgressBar _busyBar;
    private readonly Button _openButton;
    private readonly Button _downloadButton;
    private readonly Button _deleteButton;
    private readonly Button _uploadButton;
    private readonly Button _toggleButton;
    private readonly Button _hiddenButton;
    private Button? _backButton;
    private readonly Grid _columnHeader;
    private readonly Dictionary<string, Button> _locationButtons = new(StringComparer.Ordinal);
    private readonly IBrush _selectedBrush;
    private readonly IBrush _transparent = Brushes.Transparent;

    private readonly (string Name, string Path, string Icon)[] _locations =
    {
        ("内部存储", "/sdcard", "📁"),
        ("下载", "/sdcard/Download", "⬇"),
        ("图片", "/sdcard/Pictures", "🖼"),
        ("相机", "/sdcard/DCIM", "📷"),
        ("临时目录", "/data/local/tmp", "🕘"),
        ("应用数据", "/data/data", "📦"),
        ("根目录", "/", "💾")
    };

    private FileBrowserWindow(MobileDeviceViewModel mobile, AdbDevice device)
    {
        _mobile = mobile;
        _serial = device.Serial;
        _deviceName = device.DisplayName;
        _adb = new AdbService(string.IsNullOrWhiteSpace(mobile.AdbPath) ? null : mobile.AdbPath);
        _service = new DeviceFileService(_adb);
        _selectedBrush = FindBrush("RowSelectedBrush", Color.FromArgb(80, 70, 130, 255));

        Title = $"设备文件 · {_deviceName}";
        Width = 1120;
        Height = 760;
        MinWidth = 820;
        MinHeight = 540;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        CanResize = true;
        Background = FindBrush("AppBackgroundBrush", Color.FromRgb(24, 24, 27));
        _ = _transparent;

        _pathBox = new TextBox
        {
            Text = _path,
            FontFamily = new FontFamily("Consolas, Menlo, monospace"),
            VerticalAlignment = VerticalAlignment.Center
        };
        _pathBox.KeyDown += OnPathBoxKeyDown;

        _statusText = new TextBlock
        {
            Text = "正在读取手机目录…",
            FontSize = 11,
            Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(150, 150, 155)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        _countText = new TextBlock
        {
            FontSize = 11,
            Foreground = FindBrush("TextTertiaryBrush", Color.FromRgb(130, 130, 135)),
            VerticalAlignment = VerticalAlignment.Center
        };
        _titleText = new TextBlock
        {
            Text = "手机文件",
            FontSize = 16,
            FontWeight = FontWeight.SemiBold,
            Foreground = FindBrush("TextPrimaryBrush", Colors.White),
            VerticalAlignment = VerticalAlignment.Center
        };
        _busyBar = new ProgressBar { IsIndeterminate = true, Width = 80, Height = 3, IsVisible = false };

        _listBox = BuildFileListBox();
        _gridBox = BuildFileGridBox();

        _openButton = MakeActionButton("打开", () => _ = OpenSelectionAsync());
        _downloadButton = MakeActionButton("下载", () => _ = DownloadSelectionAsync());
        _deleteButton = MakeActionButton("删除", () => _ = DeleteSelectionAsync());
        _uploadButton = MakeActionButton("上传", () => _ = UploadFilesAsync(null));
        _toggleButton = MakeIconButton("▦", () => ToggleView());
        _hiddenButton = MakeIconButton("👁", () => ToggleHidden());
        _columnHeader = BuildColumnHeader();

        Content = BuildRoot();
        UpdateActions();

        Opened += async (_, _) =>
        {
            WindowEffects.ApplyRoundedCorners(this);
            await LoadAsync(_path);
        };
        Closed += (_, _) =>
        {
            if (Windows.TryGetValue(_serial, out var existing) && ReferenceEquals(existing, this))
            {
                Windows.Remove(_serial);
            }
        };
    }

    public static void Present(MobileDeviceViewModel mobile)
    {
        var device = mobile.SelectedDevice;
        if (device is null) return;
        if (Windows.TryGetValue(device.Serial, out var existing))
        {
            existing.Activate();
            return;
        }

        var window = new FileBrowserWindow(mobile, device);
        Windows[device.Serial] = window;
        window.Show();
    }

    // MARK: - UI

    private Control BuildRoot()
    {
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };
        var header = BuildHeader();
        var pathBar = BuildPathBar();
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("190,*") };
        body.Children.Add(BuildSidebar());
        var content = BuildContent();
        Grid.SetColumn(content, 1);
        body.Children.Add(content);

        var footer = BuildFooter();

        Grid.SetRow(header, 0);
        Grid.SetRow(pathBar, 1);
        Grid.SetRow(body, 2);
        Grid.SetRow(footer, 3);
        root.Children.Add(header);
        root.Children.Add(pathBar);
        root.Children.Add(body);
        root.Children.Add(footer);
        return root;
    }

    private Control BuildHeader()
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(16, 12, 16, 10) };
        var titlePanel = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        titlePanel.Children.Add(_titleText);
        titlePanel.Children.Add(new TextBlock
        {
            Text = $"{_deviceName} · {_serial}",
            FontSize = 11,
            Foreground = FindBrush("TextTertiaryBrush", Color.FromRgb(140, 140, 145))
        });
        grid.Children.Add(titlePanel);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center
        };
        actions.Children.Add(_openButton);
        actions.Children.Add(_downloadButton);
        actions.Children.Add(_uploadButton);
        actions.Children.Add(_deleteButton);
        actions.Children.Add(_busyBar);
        actions.Children.Add(_hiddenButton);
        actions.Children.Add(MakeIconButton("↻", () => _ = LoadAsync(_path)));
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);
        return grid;
    }

    private Control BuildPathBar()
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto,Auto,Auto"),
            Margin = new Thickness(16, 0, 16, 10),
            ColumnSpacing = 6
        };
        var back = MakeIconButton("‹", GoBack);
        back.IsEnabled = false;
        back.Name = "BackButton";
        _backButton = back;
        var up = MakeIconButton("↑", () => _ = GoUpAsync());
        grid.Children.Add(back);
        Grid.SetColumn(up, 1);
        grid.Children.Add(up);
        Grid.SetColumn(_pathBox, 2);
        grid.Children.Add(_pathBox);
        var go = MakeActionButton("前往", () => _ = GoPathAsync());
        Grid.SetColumn(go, 3);
        grid.Children.Add(go);
        Grid.SetColumn(_toggleButton, 4);
        grid.Children.Add(_toggleButton);
        return grid;
    }

    private Control BuildSidebar()
    {
        var panel = new StackPanel { Spacing = 3, Margin = new Thickness(10, 12, 10, 12) };
        panel.Children.Add(new TextBlock
        {
            Text = "常用位置",
            FontSize = 11,
            FontWeight = FontWeight.SemiBold,
            Foreground = FindBrush("TextTertiaryBrush", Color.FromRgb(140, 140, 145)),
            Margin = new Thickness(4, 0, 0, 5)
        });

        foreach (var location in _locations)
        {
            var button = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(8, 6),
                CornerRadius = new CornerRadius(7),
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 7,
                    Children =
                    {
                        new TextBlock { Text = location.Icon, Width = 18, FontSize = 13 },
                        new TextBlock { Text = location.Name, FontSize = 12.5, Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(165, 165, 170)) }
                    }
                }
            };
            button.Click += (_, _) => _ = NavigateAsync(location.Path, pushHistory: true);
            _locationButtons[location.Path] = button;
            panel.Children.Add(button);
        }

        panel.Children.Add(new Border
        {
            Height = 1,
            Background = FindBrush("DividerBrush", Color.FromRgb(60, 60, 65)),
            Margin = new Thickness(4, 10, 4, 10)
        });
        panel.Children.Add(new TextBlock
        {
            Text = "设备",
            FontSize = 11,
            FontWeight = FontWeight.SemiBold,
            Foreground = FindBrush("TextTertiaryBrush", Color.FromRgb(140, 140, 145)),
            Margin = new Thickness(4, 0, 0, 4)
        });
        panel.Children.Add(new TextBlock
        {
            Text = _deviceName,
            FontSize = 11,
            Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(165, 165, 170)),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(4, 0, 0, 2)
        });
        panel.Children.Add(new TextBlock
        {
            Text = _serial,
            FontSize = 10,
            Foreground = FindBrush("TextTertiaryBrush", Color.FromRgb(130, 130, 135)),
            Margin = new Thickness(4, 0, 0, 0)
        });

        var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        return new Border
        {
            Background = FindBrush("SidebarBrush", Color.FromRgb(28, 28, 32)),
            BorderBrush = FindBrush("DividerBrush", Color.FromRgb(60, 60, 65)),
            BorderThickness = new Thickness(0, 0, 1, 0),
            Child = scroll
        };
    }

    private Control BuildContent()
    {
        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        grid.Children.Add(_columnHeader);
        Grid.SetRow(_columnHeader, 0);

        var host = new Grid();
        host.Children.Add(_listBox);
        host.Children.Add(_gridBox);
        Grid.SetRow(host, 1);
        grid.Children.Add(host);

        _gridBox.IsVisible = false;
        _columnHeader.IsVisible = true;
        return grid;
    }

    private Control BuildFooter()
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
            Margin = new Thickness(16, 7, 16, 7)
        };
        grid.Children.Add(_statusText);
        Grid.SetColumn(_countText, 1);
        grid.Children.Add(_countText);
        return new Border
        {
            BorderBrush = FindBrush("DividerBrush", Color.FromRgb(60, 60, 65)),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = grid
        };
    }

    private Grid BuildColumnHeader()
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("24,*,80,140,100"),
            Margin = new Thickness(14, 7, 14, 7)
        };
        AddHeader(grid, "名称", 1, HorizontalAlignment.Left);
        AddHeader(grid, "大小", 2, HorizontalAlignment.Right);
        AddHeader(grid, "修改时间", 3, HorizontalAlignment.Left);
        AddHeader(grid, "权限", 4, HorizontalAlignment.Left);
        return new Grid { Children = { grid } };
    }

    private static void AddHeader(Grid grid, string text, int column, HorizontalAlignment alignment)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = 10.5,
            FontWeight = FontWeight.SemiBold,
            Foreground = new SolidColorBrush(Color.FromRgb(140, 140, 145)),
            HorizontalAlignment = alignment,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(block, column);
        grid.Children.Add(block);
    }

    private ListBox BuildFileListBox()
    {
        var list = new ListBox
        {
            ItemsSource = _items,
            SelectionMode = SelectionMode.Multiple,
            Background = Brushes.Transparent,
            ItemTemplate = new FuncDataTemplate<FileBrowserItem>((item, _) => BuildListRow(item)),
        };
        list.SelectionChanged += OnSelectionChanged;
        list.PointerPressed += OnFilePointerPressed;
        list.ContextRequested += OnFileContextRequested;
        list.DoubleTapped += OnFileDoubleTapped;
        return list;
    }

    private ListBox BuildFileGridBox()
    {
        var list = new ListBox
        {
            ItemsSource = _items,
            SelectionMode = SelectionMode.Multiple,
            Background = Brushes.Transparent,
            ItemTemplate = new FuncDataTemplate<FileBrowserItem>((item, _) => BuildGridCard(item)),
            ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel
            {
                Orientation = Orientation.Horizontal,
                ItemWidth = 154,
                Margin = new Thickness(8)
            })
        };
        list.SelectionChanged += OnSelectionChanged;
        list.PointerPressed += OnFilePointerPressed;
        list.ContextRequested += OnFileContextRequested;
        list.DoubleTapped += OnFileDoubleTapped;
        return list;
    }

    private Control BuildListRow(FileBrowserItem item)
    {
        if (item is null) return new Border();
        var row = new Border
        {
            MinHeight = 30,
            Padding = new Thickness(14, 4),
            Background = _transparent,
            Cursor = new Cursor(StandardCursorType.Hand)
        };
        row.Bind(Border.BackgroundProperty, new Binding(nameof(FileBrowserItem.IsSelected))
        {
            Source = item,
            Converter = new FuncValueConverter<bool, IBrush?>(selected => selected ? _selectedBrush : _transparent)
        });

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("24,*,80,140,100") };
        var icon = new TextBlock { Text = item.Icon, FontSize = 16, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(icon);
        var name = new TextBlock
        {
            Text = item.Name,
            FontSize = 12.5,
            Foreground = FindBrush("TextPrimaryBrush", Colors.White),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        var size = new TextBlock
        {
            Text = item.SizeText,
            FontSize = 11,
            Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(160, 160, 165)),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(size, 2);
        grid.Children.Add(size);
        var modified = new TextBlock
        {
            Text = item.Modified,
            FontSize = 11,
            Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(160, 160, 165)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(modified, 3);
        grid.Children.Add(modified);
        var permissions = new TextBlock
        {
            Text = item.Permissions,
            FontSize = 10,
            FontFamily = new FontFamily("Consolas, Menlo, monospace"),
            Foreground = FindBrush("TextTertiaryBrush", Color.FromRgb(135, 135, 140)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(permissions, 4);
        grid.Children.Add(permissions);

        row.Child = grid;
        ToolTip.SetTip(row, item.Path);
        return row;
    }

    private Control BuildGridCard(FileBrowserItem item)
    {
        if (item is null) return new Border();
        var card = new Border
        {
            Width = 146,
            Height = 148,
            Margin = new Thickness(4),
            Padding = new Thickness(8),
            CornerRadius = new CornerRadius(10),
            ClipToBounds = true,
            Background = _transparent,
            Cursor = new Cursor(StandardCursorType.Hand)
        };
        card.Bind(Border.BackgroundProperty, new Binding(nameof(FileBrowserItem.IsSelected))
        {
            Source = item,
            Converter = new FuncValueConverter<bool, IBrush?>(selected => selected ? _selectedBrush : _transparent)
        });

        var stack = new StackPanel { Spacing = 5 };
        var thumb = new Border
        {
            Height = 92,
            CornerRadius = new CornerRadius(8),
            ClipToBounds = true,
            Background = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255))
        };
        var thumbGrid = new Grid();
        var icon = new TextBlock
        {
            Text = item.Icon,
            FontSize = 34,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        thumbGrid.Children.Add(icon);
        var image = new Image { Stretch = Stretch.UniformToFill };
        image.Bind(Image.SourceProperty, new Binding(nameof(FileBrowserItem.Thumbnail)) { Source = item });
        thumbGrid.Children.Add(image);
        thumb.Child = thumbGrid;
        stack.Children.Add(thumb);
        if (item.Media)
        {
            _ = item.LoadThumbnailAsync(_service, _serial);
        }

        var name = new TextBlock
        {
            Text = item.Name,
            FontSize = 11,
            Foreground = FindBrush("TextPrimaryBrush", Colors.White),
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        stack.Children.Add(name);
        var size = new TextBlock
        {
            Text = item.IsDirectory ? "—" : item.SizeText,
            FontSize = 10,
            Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(160, 160, 165)),
            HorizontalAlignment = HorizontalAlignment.Center
        };
        stack.Children.Add(size);
        card.Child = stack;
        ToolTip.SetTip(card, item.Path);
        return card;
    }

    private Button MakeActionButton(string content, Action action)
    {
        var button = new Button
        {
            Content = content,
            Padding = new Thickness(10, 4),
            FontSize = 11,
            CornerRadius = new CornerRadius(7)
        };
        button.Classes.Add("secondary");
        button.Click += (_, _) => action();
        return button;
    }

    private Button MakeIconButton(string content, Action action)
    {
        var button = new Button
        {
            Content = content,
            Padding = new Thickness(7, 3),
            FontSize = 14,
            MinWidth = 30,
            CornerRadius = new CornerRadius(7)
        };
        button.Classes.Add("icon");
        button.Click += (_, _) => action();
        return button;
    }

    private static IBrush FindBrush(string key, Color fallback)
    {
        return Application.Current?.FindResource(key) as IBrush ?? new SolidColorBrush(fallback);
    }

    // MARK: - 选择

    private void OnSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection || sender is not ListBox list) return;
        _selectedPaths.Clear();
        var selectedItems = list.SelectedItems?.OfType<FileBrowserItem>().ToList() ?? new List<FileBrowserItem>();
        foreach (var item in selectedItems) _selectedPaths.Add(item.Path);
        UpdateItemSelection();
        UpdateActions();
    }

    private void UpdateItemSelection()
    {
        foreach (var item in _items) item.IsSelected = _selectedPaths.Contains(item.Path);
    }

    private void ApplySelectionToLists()
    {
        _syncingSelection = true;
        try
        {
            foreach (var list in new[] { _listBox, _gridBox })
            {
                list.SelectedItems?.Clear();
                foreach (var item in _items.Where(item => _selectedPaths.Contains(item.Path)))
                {
                    list.SelectedItems?.Add(item);
                }
            }
        }
        finally
        {
            _syncingSelection = false;
        }
        UpdateItemSelection();
        UpdateActions();
    }

    private void SelectOnly(FileBrowserItem item)
    {
        _selectedPaths.Clear();
        _selectedPaths.Add(item.Path);
        _selectionAnchor = item.Path;
        ApplySelectionToLists();
    }

    private List<FileBrowserItem> SelectedItems =>
        _items.Where(item => _selectedPaths.Contains(item.Path)).ToList();

    private void UpdateActions()
    {
        var selected = SelectedItems;
        _openButton.IsEnabled = !_busy && selected.Count == 1;
        _downloadButton.IsEnabled = !_busy && selected.Count > 0;
        _deleteButton.IsEnabled = !_busy && selected.Count > 0;
        _uploadButton.IsEnabled = !_busy && !DevicePath.IsAppDataPath(_path);
        _toggleButton.IsEnabled = !_busy;
        _hiddenButton.IsEnabled = !_busy;
        _countText.Text = selected.Count > 0
            ? $"已选 {selected.Count} 项 · 共 {_items.Count} 项"
            : $"共 {_items.Count} 项";
        if (_backButton is not null) _backButton.IsEnabled = _backStack.Count > 0;
    }

    private static FileBrowserItem? ItemFromSource(object? source)
    {
        var visual = source as Visual;
        while (visual is not null)
        {
            if (visual is Control control && control.DataContext is FileBrowserItem item) return item;
            visual = visual.GetVisualParent();
        }
        return null;
    }

    private void OnFilePointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (sender is not ListBox list) return;
        var point = e.GetCurrentPoint(list);
        if (!point.Properties.IsLeftButtonPressed && !point.Properties.IsRightButtonPressed) return;
        var position = e.GetPosition(list);
        var item = ItemFromSource(list.InputHitTest(position));
        if (item is null) return;

        if (point.Properties.IsRightButtonPressed)
        {
            if (!_selectedPaths.Contains(item.Path)) SelectOnly(item);
            return;
        }

        if (e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            if (!_selectedPaths.Add(item.Path)) _selectedPaths.Remove(item.Path);
            _selectionAnchor = item.Path;
        }
        else if (e.KeyModifiers.HasFlag(KeyModifiers.Shift) && _selectionAnchor is not null)
        {
            var start = _items.ToList().FindIndex(entry => entry.Path == _selectionAnchor);
            var end = _items.ToList().FindIndex(entry => entry.Path == item.Path);
            if (start >= 0 && end >= 0)
            {
                _selectedPaths.Clear();
                var from = Math.Min(start, end);
                var to = Math.Max(start, end);
                for (var i = from; i <= to; i++) _selectedPaths.Add(_items[i].Path);
            }
        }
        else
        {
            _selectedPaths.Clear();
            _selectedPaths.Add(item.Path);
            _selectionAnchor = item.Path;
        }
        ApplySelectionToLists();
        e.Handled = true;
    }

    private void OnFileContextRequested(object? sender, ContextRequestedEventArgs e)
    {
        if (sender is not ListBox list) return;
        var position = e.TryGetPosition(list, out var point) ? point : new Point(0, 0);
        var item = ItemFromSource(list.InputHitTest(position));
        if (item is not null && !_selectedPaths.Contains(item.Path))
        {
            SelectOnly(item);
        }
        var menu = BuildContextMenu(item);
        menu.Placement = PlacementMode.Pointer;
        menu.PlacementTarget = list;
        menu.Open(list);
        e.Handled = true;
    }

    private void OnFileDoubleTapped(object? sender, TappedEventArgs e)
    {
        var item = ItemFromSource(e.Source);
        if (item is null) return;
        SelectOnly(item);
        _ = OpenItemAsync(item);
    }

    // MARK: - 右键菜单

    private ContextMenu BuildContextMenu(FileBrowserItem? clicked)
    {
        var menu = new ContextMenu();
        var multiple = clicked is not null && _selectedPaths.Count > 1 && _selectedPaths.Contains(clicked.Path);
        var targetDirectory = clicked?.IsDirectory == true ? clicked.Path : _path;
        var readOnly = DevicePath.IsAppDataPath(targetDirectory) || DevicePath.IsAppDataPath(_path);
        var actionTargets = clicked is not null && _selectedPaths.Contains(clicked.Path)
            ? SelectedItems
            : clicked is null ? new List<FileBrowserItem>() : new List<FileBrowserItem> { clicked };

        var newItem = new MenuItem { Header = "新建", IsEnabled = !_busy && !multiple && !readOnly };
        if (!_busy && !multiple && !readOnly)
        {
            var fileItem = new MenuItem { Header = "文件" };
            fileItem.Click += (_, _) => _ = CreateAsync(targetDirectory, isDirectory: false);
            var folderItem = new MenuItem { Header = "文件夹" };
            folderItem.Click += (_, _) => _ = CreateAsync(targetDirectory, isDirectory: true);
            newItem.Items.Add(fileItem);
            newItem.Items.Add(folderItem);
        }
        menu.Items.Add(newItem);

        var uploadItem = new MenuItem
        {
            Header = clicked?.IsDirectory == true ? "上传到此文件夹…" : "上传到当前目录…",
            IsEnabled = !_busy && !multiple && !readOnly
        };
        uploadItem.Click += (_, _) => _ = UploadFilesAsync(targetDirectory);
        menu.Items.Add(uploadItem);
        var uploadFolder = new MenuItem { Header = "上传文件夹…", IsEnabled = !_busy && !multiple && !readOnly };
        uploadFolder.Click += (_, _) => _ = UploadFolderAsync(targetDirectory);
        menu.Items.Add(uploadFolder);

        if (clicked is not null)
        {
            menu.Items.Add(new Separator());
            var open = new MenuItem
            {
                Header = clicked.IsDirectory ? "打开文件夹" : "打开文件",
                IsEnabled = !_busy && !multiple
            };
            open.Click += (_, _) => _ = OpenItemAsync(clicked);
            menu.Items.Add(open);

            var download = new MenuItem { Header = "下载到电脑…", IsEnabled = !_busy };
            download.Click += (_, _) => _ = DownloadItemsAsync(actionTargets);
            menu.Items.Add(download);

            menu.Items.Add(new Separator());
            var copy = new MenuItem { Header = "复制路径" };
            copy.Click += (_, _) => _ = CopyPathsAsync(actionTargets);
            menu.Items.Add(copy);
        }

        menu.Items.Add(new Separator());
        var refresh = new MenuItem { Header = "刷新", IsEnabled = !_busy };
        refresh.Click += (_, _) => _ = LoadAsync(_path);
        menu.Items.Add(refresh);

        if (clicked is not null)
        {
            menu.Items.Add(new Separator());
            var delete = new MenuItem { Header = "删除…", IsEnabled = !_busy };
            delete.Click += (_, _) => _ = DeleteItemsAsync(actionTargets);
            menu.Items.Add(delete);
        }

        return menu;
    }

    // MARK: - 导航

    private async Task NavigateAsync(string path, bool pushHistory)
    {
        if (_busy) return;
        var target = DevicePath.Normalize(path);
        if (pushHistory && target != _path) _backStack.Push(_path);
        await LoadAsync(target);
    }

    private void GoBack()
    {
        if (_busy || _backStack.Count == 0) return;
        var target = _backStack.Pop();
        _ = LoadAsync(target);
    }

    private async Task GoUpAsync()
    {
        if (_path == "/") return;
        await NavigateAsync(DevicePath.Parent(_path), pushHistory: true);
    }

    private async Task GoPathAsync()
    {
        if (_busy) return;
        var target = DevicePath.Normalize(_pathBox.Text);
        try
        {
            var isDir = await _service.IsDirectoryAsync(_serial, target);
            if (isDir)
            {
                await NavigateAsync(target, pushHistory: true);
            }
            else
            {
                var parent = DevicePath.Parent(target);
                _pendingSelectPath = target;
                await NavigateAsync(parent, pushHistory: true);
            }
        }
        catch (Exception ex)
        {
            SetStatus($"打开路径失败：{ex.Message}", error: true);
        }
    }

    private void OnPathBoxKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            _ = GoPathAsync();
        }
    }

    private async Task LoadAsync(string path)
    {
        var target = DevicePath.Normalize(path);
        _busy = true;
        _busyBar.IsVisible = true;
        UpdateActions();
        SetStatus("正在读取手机目录…");
        try
        {
            var (entries, error) = await _service.ListDirectoryAsync(_serial, target);
            if (entries is null)
            {
                SetStatus(error ?? "无法读取这个目录", error: true);
                _busy = false;
                _busyBar.IsVisible = false;
                UpdateActions();
                return;
            }

            _path = target;
            _pathBox.Text = target;
            _items.Clear();
            foreach (var entry in entries)
            {
                if (!_showHidden && entry.IsHidden) continue;
                if (target == "/")
                {
                    if (entry.IsSymlink && RootHiddenLinks.Contains(entry.Name)) continue;
                    if (entry.Permissions.Contains('?')) continue;
                }
                _items.Add(new FileBrowserItem(entry));
            }

            var select = _pendingSelectPath;
            _pendingSelectPath = null;
            _selectedPaths.Clear();
            if (select is not null)
            {
                var item = _items.FirstOrDefault(item => item.Path == select);
                if (item is not null) _selectedPaths.Add(item.Path);
            }
            ApplySelectionToLists();
            _statusText.Text = $"共 {_items.Count} 项";
            _statusText.Foreground = FindBrush("TextSecondaryBrush", Color.FromRgb(150, 150, 155));
            if (_gridMode) EnsureThumbnails();
        }
        catch (Exception ex)
        {
            SetStatus($"读取目录失败：{ex.Message}", error: true);
        }
        finally
        {
            _busy = false;
            _busyBar.IsVisible = false;
            UpdateActions();
            UpdateLocationButtons();
        }
    }

    private void EnsureThumbnails()
    {
        foreach (var item in _items.Where(item => item.Media))
        {
            _ = item.LoadThumbnailAsync(_service, _serial);
        }
    }

    private void ToggleView()
    {
        if (_busy) return;
        _gridMode = !_gridMode;
        _listBox.IsVisible = !_gridMode;
        _gridBox.IsVisible = _gridMode;
        _columnHeader.IsVisible = !_gridMode;
        _toggleButton.Content = _gridMode ? "☰" : "▦";
        ToolTip.SetTip(_toggleButton, _gridMode ? "切换为列表" : "切换为网格");
        ApplySelectionToLists();
        if (_gridMode) EnsureThumbnails();
    }

    private void ToggleHidden()
    {
        if (_busy) return;
        _showHidden = !_showHidden;
        _hiddenButton.Content = _showHidden ? "🙈" : "👁";
        ToolTip.SetTip(_hiddenButton, _showHidden ? "隐藏以 . 开头的文件" : "显示隐藏文件");
        _ = LoadAsync(_path);
    }

    private void UpdateLocationButtons()
    {
        foreach (var pair in _locationButtons)
        {
            pair.Value.Background = pair.Key == _path ? _selectedBrush : Brushes.Transparent;
        }
    }

    // MARK: - 文件操作

    private async Task OpenSelectionAsync()
    {
        var selected = SelectedItems;
        if (selected.Count == 1) await OpenItemAsync(selected[0]);
    }

    private async Task OpenItemAsync(FileBrowserItem item)
    {
        try
        {
            SetBusy(true);
            var isDir = item.IsDirectory || await _service.IsDirectoryAsync(_serial, item.Path);
            if (isDir)
            {
                SetBusy(false);
                await NavigateAsync(item.Path, pushHistory: true);
                return;
            }

            var tempDir = Path.Combine(Path.GetTempPath(), "ADBTypeLink", "open");
            Directory.CreateDirectory(tempDir);
            var local = Path.Combine(tempDir, item.Name);
            var result = await _service.PullAsync(_serial, item.Path, local, timeout: TimeSpan.FromMinutes(10));
            if (!result.Ok)
            {
                SetStatus(DeviceFileService.FileError(result, "下载文件失败"), error: true);
                return;
            }
            Process.Start(new ProcessStartInfo(local) { UseShellExecute = true });
            SetStatus($"已打开 {item.Name}");
        }
        catch (Exception ex)
        {
            SetStatus($"打开失败：{ex.Message}", error: true);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task DownloadSelectionAsync()
    {
        await DownloadItemsAsync(SelectedItems);
    }

    private async Task DownloadItemsAsync(IReadOnlyList<FileBrowserItem> items)
    {
        if (items.Count == 0 || _busy) return;
        try
        {
            if (items.Count == 1 && !items[0].IsDirectory)
            {
                var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
                {
                    Title = "下载到电脑",
                    SuggestedFileName = items[0].Name
                });
                var local = file?.TryGetLocalPath();
                if (string.IsNullOrEmpty(local)) return;
                SetBusy(true);
                SetStatus($"正在下载 {items[0].Name}…");
                var result = await _service.PullAsync(_serial, items[0].Path, local,
                    timeout: TimeSpan.FromMinutes(10));
                SetStatus(result.Ok ? $"已下载 {items[0].Name}" : DeviceFileService.FileError(result, "下载失败"),
                    error: !result.Ok);
                return;
            }

            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = items.Count == 1 ? "选择保存文件夹" : $"下载 {items.Count} 个项目到…",
                AllowMultiple = false
            });
            var directory = folders.FirstOrDefault()?.TryGetLocalPath();
            if (string.IsNullOrEmpty(directory)) return;
            Directory.CreateDirectory(directory);
            SetBusy(true);
            var failed = 0;
            foreach (var item in items)
            {
                SetStatus($"正在下载 {item.Name}…");
                var local = Path.Combine(directory, item.Name);
                var result = await _service.PullAsync(_serial, item.Path, local,
                    timeout: item.IsDirectory ? TimeSpan.FromMinutes(20) : TimeSpan.FromMinutes(10));
                if (!result.Ok) failed++;
            }
            SetStatus(failed == 0 ? $"已下载 {items.Count} 项" : $"已下载 {items.Count - failed} 项，{failed} 项失败",
                error: failed > 0);
        }
        catch (Exception ex)
        {
            SetStatus($"下载失败：{ex.Message}", error: true);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task UploadFilesAsync(string? targetDirectory)
    {
        if (_busy) return;
        var destination = targetDirectory ?? _path;
        if (DevicePath.IsAppDataPath(destination))
        {
            SetStatus("应用数据目录只读，不能上传", error: true);
            return;
        }
        try
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "上传到手机",
                AllowMultiple = true
            });
            var localPaths = files
                .Select(file => file.TryGetLocalPath())
                .Where(path => !string.IsNullOrEmpty(path))
                .Select(path => path!)
                .ToList();
            if (localPaths.Count == 0) return;
            await PushLocalPathsAsync(localPaths, destination);
        }
        catch (Exception ex)
        {
            SetStatus($"上传失败：{ex.Message}", error: true);
        }
    }

    private async Task UploadFolderAsync(string targetDirectory)
    {
        if (_busy) return;
        if (DevicePath.IsAppDataPath(targetDirectory))
        {
            SetStatus("应用数据目录只读，不能上传", error: true);
            return;
        }
        try
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = "上传文件夹到手机",
                AllowMultiple = false
            });
            var local = folders.FirstOrDefault()?.TryGetLocalPath();
            if (string.IsNullOrEmpty(local)) return;
            await PushLocalPathsAsync(new[] { local }, targetDirectory);
        }
        catch (Exception ex)
        {
            SetStatus($"上传失败：{ex.Message}", error: true);
        }
    }

    private async Task PushLocalPathsAsync(IReadOnlyList<string> localPaths, string destination)
    {
        SetBusy(true);
        var failed = 0;
        try
        {
            foreach (var localPath in localPaths)
            {
                SetStatus($"正在上传 {Path.GetFileName(localPath)}…");
                var progress = new Progress<double>(value =>
                {
                    Dispatcher.UIThread.Post(() => SetStatus($"正在上传 {Path.GetFileName(localPath)}… {value * 100:0}%"));
                });
                var result = await _service.PushAsync(_serial, localPath, destination, progress);
                if (!result.Ok) failed++;
            }
            SetStatus(failed == 0 ? $"已上传 {localPaths.Count} 项" : $"上传完成，{failed} 项失败",
                error: failed > 0);
            await LoadAsync(_path);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task CreateAsync(string directory, bool isDirectory)
    {
        if (_busy) return;
        if (DevicePath.IsAppDataPath(directory))
        {
            SetStatus("应用数据目录只读，不能新建", error: true);
            return;
        }
        var title = isDirectory ? "新建文件夹" : "新建文件";
        var name = await TextPromptWindow.ShowAsync(this, title, $"位置：{directory}", "");
        if (string.IsNullOrWhiteSpace(name)) return;
        name = name.Trim();
        if (name is "." or ".." || name.Contains('/') || name.Contains('\\') || name.Contains('\n'))
        {
            SetStatus("名称不能为空，也不能包含 / 或换行", error: true);
            return;
        }

        try
        {
            SetBusy(true);
            var result = await _service.CreateAsync(_serial, DevicePath.Join(directory, name), isDirectory);
            if (!result.Ok)
            {
                SetStatus(DeviceFileService.FileError(result, "新建失败"), error: true);
                return;
            }
            SetStatus(isDirectory ? $"已新建文件夹 {name}" : $"已新建文件 {name}");
            await LoadAsync(_path);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task DeleteSelectionAsync()
    {
        await DeleteItemsAsync(SelectedItems);
    }

    private async Task DeleteItemsAsync(IReadOnlyList<FileBrowserItem> items)
    {
        if (items.Count == 0 || _busy) return;
        var names = string.Join("、", items.Take(5).Select(item => item.Name));
        var message = items.Count == 1
            ? $"将从手机永久删除「{items[0].Name}」，此操作无法撤销。\n\n{items[0].Path}"
            : $"将从手机永久删除选中的 {items.Count} 个项目，文件夹会连同内容一起删除。\n此操作无法撤销。\n\n{names}";
        if (!await ConfirmWindow.ShowAsync(this, "删除确认", message, "删除")) return;

        try
        {
            SetBusy(true);
            var failed = 0;
            foreach (var item in items)
            {
                var result = await _service.RemoveAsync(_serial, item.Path);
                if (!result.Ok) failed++;
            }
            SetStatus(failed == 0 ? $"已删除 {items.Count} 项" : $"已删除 {items.Count - failed} 项，{failed} 项失败",
                error: failed > 0);
            _selectedPaths.Clear();
            await LoadAsync(_path);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task CopyPathsAsync(IReadOnlyList<FileBrowserItem> items)
    {
        if (items.Count == 0) return;
        var text = string.Join('\n', items.Select(item => item.Path));
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is not null) await clipboard.SetTextAsync(text);
        SetStatus(items.Count == 1 ? "已复制路径" : $"已复制 {items.Count} 条路径");
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _busyBar.IsVisible = busy;
        UpdateActions();
    }

    private void SetStatus(string message, bool error = false)
    {
        _statusText.Text = message;
        _statusText.Foreground = error
            ? FindBrush("FailureBrush", Color.FromRgb(235, 100, 100))
            : FindBrush("TextSecondaryBrush", Color.FromRgb(150, 150, 155));
    }
}
