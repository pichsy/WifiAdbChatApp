using System.Collections.Specialized;
using ADBTypeLink.App.Dialogs;
using ADBTypeLink.App.Helpers;
using ADBTypeLink.App.ViewModels;
using ADBTypeLink.Core;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace ADBTypeLink.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly bool _autoStart;

    public MainWindow()
        : this(null)
    {
    }

    public MainWindow(MainViewModel? viewModel)
    {
        InitializeComponent();

        _autoStart = viewModel is null;
        _viewModel = viewModel ?? new MainViewModel();
        DataContext = _viewModel;

        _viewModel.Messages.CollectionChanged += OnMessagesChanged;

        // 用隧道阶段拦截 Enter，避免多行 TextBox 先插入换行。
        InputBox.AddHandler(KeyDownEvent, OnInputKeyDown, RoutingStrategies.Tunnel);

        DragDrop.SetAllowDrop(RootGrid, true);
        RootGrid.AddHandler(DragDrop.DragEnterEvent, OnDragEnter);
        RootGrid.AddHandler(DragDrop.DragOverEvent, OnDragOver);
        RootGrid.AddHandler(DragDrop.DragLeaveEvent, OnDragLeave);
        RootGrid.AddHandler(DragDrop.DropEvent, OnDrop);

        Opened += OnOpened;
        Closed += OnClosed;
    }

    public MainViewModel ViewModel => _viewModel;

    // MARK: - 生命周期

    private async void OnOpened(object? sender, EventArgs e)
    {
        Opened -= OnOpened;

        if (!_autoStart)
        {
            ScrollToBottom();
            return;
        }

        try
        {
            await _viewModel.InitializeAsync();
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"启动失败：{exception.Message}");
        }

        ScrollToBottom();
    }

    private async void OnClosed(object? sender, EventArgs e)
    {
        Closed -= OnClosed;
        _viewModel.Messages.CollectionChanged -= OnMessagesChanged;

        try
        {
            await _viewModel.DisposeAsync();
        }
        catch (Exception)
        {
            // 关闭时的网络异常忽略。
        }
    }

    // MARK: - 消息自动滚动到底部

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add)
        {
            ScrollToBottom();
        }
    }

    /// <summary>
    /// 等布局完成后再滚到底部；字体 / emoji 首次测量会让内容高度稍后变化，
    /// 所以隔一小段时间再补两次，保证最后一条消息完整可见。
    /// </summary>
    private void ScrollToBottom()
    {
        var attempt = 0;

        void Attempt()
        {
            try
            {
                MessageScroll.UpdateLayout();
                MessageScroll.ScrollToEnd();
            }
            catch (Exception)
            {
                // 布局未完成时忽略。
            }

            attempt++;
            if (attempt < 3)
            {
                DispatcherTimer.RunOnce(Attempt, TimeSpan.FromMilliseconds(120), DispatcherPriority.Background);
            }
        }

        Dispatcher.UIThread.Post(Attempt, DispatcherPriority.Loaded);
    }

    /// <summary>截图 / 调试用：立即把消息列表定位到底部。</summary>
    public void PrepareForScreenshot()
    {
        try
        {
            MessageScroll.UpdateLayout();
            MessageScroll.ScrollToEnd();
        }
        catch (Exception)
        {
            // 忽略。
        }
    }

    // MARK: - 设备列表

    private void OnPeerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (sender is Control control && control.DataContext is PeerItemViewModel peer)
        {
            _viewModel.SelectedPeer = peer;
        }
    }

    private async void OnPairPeerClicked(object? sender, RoutedEventArgs e)
    {
        if (sender is not Control control || control.DataContext is not PeerItemViewModel peer)
        {
            return;
        }

        await RunPairingLoopAsync(peer, pairOnly: true, code => _viewModel.PairPeerAsync(peer, code));
    }

    private async void OnPairSelectedPeer(object? sender, RoutedEventArgs e)
    {
        var peer = _viewModel.SelectedPeer;
        if (peer is null)
        {
            return;
        }

        await RunPairingLoopAsync(peer, pairOnly: true, code => _viewModel.PairPeerAsync(peer, code));
    }

    // MARK: - 发送文字 / 文件

    private async void OnSendText(object? sender, RoutedEventArgs e)
    {
        await SendTextFlowAsync();
    }

    private async Task SendTextFlowAsync()
    {
        try
        {
            var peer = _viewModel.SelectedPeer;
            if (peer is null)
            {
                _viewModel.SetLocalFailure("先在左侧选择设备");
                return;
            }

            if (string.IsNullOrWhiteSpace(_viewModel.DraftText))
            {
                _viewModel.SetLocalFailure("先输入要发送的文字");
                return;
            }

            var outcome = await _viewModel.SendTextAsync(null);
            if (outcome.IsOk)
            {
                _viewModel.ClearDraft();
                return;
            }

            if (outcome.Status == SendStatus.NeedsPairing)
            {
                await RunPairingLoopAsync(
                    peer,
                    pairOnly: false,
                    code => _viewModel.SendTextAsync(code),
                    onSuccess: () => _viewModel.ClearDraft());
            }
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"发送失败：{exception.Message}");
        }
    }

    private async void OnSendFiles(object? sender, RoutedEventArgs e)
    {
        await SendFilesFlowAsync();
    }

    private async Task SendFilesFlowAsync()
    {
        try
        {
            var peer = _viewModel.SelectedPeer;
            if (peer is null)
            {
                _viewModel.SetLocalFailure("先在左侧选择设备");
                return;
            }

            var paths = _viewModel.StagedFiles.Select(item => item.Path).ToList();
            if (paths.Count == 0)
            {
                _viewModel.SetLocalFailure("先选择文件");
                return;
            }

            var outcome = await _viewModel.SendFilesAsync(paths, null);
            if (outcome.IsOk)
            {
                _viewModel.ClearStagedFiles();
                return;
            }

            if (outcome.Status == SendStatus.NeedsPairing)
            {
                await RunPairingLoopAsync(
                    peer,
                    pairOnly: false,
                    code => _viewModel.SendFilesAsync(paths, code),
                    onSuccess: () => _viewModel.ClearStagedFiles());
            }
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"发送失败：{exception.Message}");
        }
    }

    private async Task RunPairingLoopAsync(
        PeerItemViewModel peer,
        bool pairOnly,
        Func<string, Task<SendOutcome>> sendAction,
        Action? onSuccess = null)
    {
        string? error = null;

        while (true)
        {
            var dialog = new PairingWindow();
            dialog.Configure(peer.Name, pairOnly, error);
            var code = await dialog.ShowDialog<string?>(this);
            if (code is null)
            {
                return;
            }

            var outcome = await sendAction(code);
            if (outcome.IsOk)
            {
                onSuccess?.Invoke();
                return;
            }

            error = outcome.Status == SendStatus.NeedsPairing
                ? "配对码不对，再看一眼对方屏幕上显示的数字"
                : (string.IsNullOrEmpty(outcome.Message) ? "配对失败，请重试" : outcome.Message);
        }
    }

    // MARK: - 输入框 / 附件

    private void OnInputKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && !e.KeyModifiers.HasFlag(KeyModifiers.Shift))
        {
            e.Handled = true;
            _ = SendTextFlowAsync();
        }
    }

    private async void OnAttachFiles(object? sender, RoutedEventArgs e)
    {
        try
        {
            var storage = GetTopLevel(this)?.StorageProvider;
            if (storage is null)
            {
                return;
            }

            var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选择要发送的文件",
                AllowMultiple = true,
            });

            var paths = files
                .Select(file => file.TryGetLocalPath())
                .Where(path => !string.IsNullOrEmpty(path))
                .Select(path => path!)
                .ToList();

            _viewModel.AddStagedFiles(paths);
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"选择文件失败：{exception.Message}");
        }
    }

    private void OnRemoveStagedFile(object? sender, RoutedEventArgs e)
    {
        if (sender is Control control && control.DataContext is StagedFileViewModel staged)
        {
            _viewModel.RemoveStagedFile(staged);
        }
    }

    private void OnClearStagedFiles(object? sender, RoutedEventArgs e)
    {
        _viewModel.ClearStagedFiles();
    }

    // MARK: - 本机操作

    private async void OnCopyPairingCode(object? sender, RoutedEventArgs e)
    {
        try
        {
            var clipboard = GetTopLevel(this)?.Clipboard;
            if (clipboard is null)
            {
                return;
            }

            await clipboard.SetTextAsync(_viewModel.PairingCode);
            _viewModel.ReportCopied();
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"复制失败：{exception.Message}");
        }
    }

    private void OnRegenerateCode(object? sender, RoutedEventArgs e)
    {
        _viewModel.RegeneratePairingCode();
    }

    private async void OnChangeReceiveDir(object? sender, RoutedEventArgs e)
    {
        try
        {
            var storage = GetTopLevel(this)?.StorageProvider;
            if (storage is null)
            {
                return;
            }

            var folders = await storage.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = "选择接收文件的保存目录",
                AllowMultiple = false,
            });

            if (folders.Count == 0)
            {
                return;
            }

            var path = folders[0].TryGetLocalPath();
            if (!string.IsNullOrEmpty(path))
            {
                _viewModel.SetReceiveDir(path);
            }
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"修改接收目录失败：{exception.Message}");
        }
    }

    private void OnOpenReceiveDir(object? sender, RoutedEventArgs e)
    {
        if (!ShellLauncher.TryOpenDirectory(_viewModel.ReceiveDir))
        {
            _viewModel.SetLocalFailure($"打不开接收目录：{_viewModel.ReceiveDir}");
        }
    }

    private void OnForgetAllPairs(object? sender, RoutedEventArgs e)
    {
        _viewModel.ForgetAllPairs();
    }

    private void OnDismissPairRequest(object? sender, RoutedEventArgs e)
    {
        _viewModel.ClearPendingPair();
    }

    private async void OnClearMessages(object? sender, RoutedEventArgs e)
    {
        var confirmed = await ConfirmWindow.ShowAsync(
            this,
            "清空全部消息记录？",
            "只清空这里的聊天列表，已经收到的文件不会被删除。",
            "清空");
        if (confirmed)
        {
            _viewModel.ClearMessages();
        }
    }

    // MARK: - 消息气泡操作

    private async void OnCopyMessage(object? sender, RoutedEventArgs e)
    {
        if (sender is Control control && control.DataContext is MessageItemViewModel message)
        {
            await CopyMessageAsync(message);
        }
    }

    private async Task CopyMessageAsync(MessageItemViewModel message)
    {
        if (string.IsNullOrEmpty(message.Text))
        {
            return;
        }

        try
        {
            var clipboard = GetTopLevel(this)?.Clipboard;
            if (clipboard is null)
            {
                return;
            }

            await clipboard.SetTextAsync(message.Text);
            _viewModel.ReportCopied();
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"复制失败：{exception.Message}");
        }
    }

    private void OnRevealFile(object? sender, RoutedEventArgs e)
    {
        if (sender is Control control && control.DataContext is MessageItemViewModel message)
        {
            RevealMessageFile(message);
        }
    }

    private void RevealMessageFile(MessageItemViewModel message)
    {
        var path = message.Message.FilePath;
        if (string.IsNullOrEmpty(path))
        {
            return;
        }

        if (!File.Exists(path))
        {
            _viewModel.ReportMissingFile(path);
            return;
        }

        var ok = message.IsOutgoing
            ? ShellLauncher.TryOpenFile(path)
            : ShellLauncher.TryRevealFile(path);

        if (!ok)
        {
            _viewModel.SetLocalFailure($"打不开文件：{path}");
        }
    }

    private void OnBubblePointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (sender is not Control control || control.DataContext is not MessageItemViewModel message)
        {
            return;
        }

        if (!e.GetCurrentPoint(control).Properties.IsRightButtonPressed)
        {
            return;
        }

        var flyout = new MenuFlyout();
        if (message.IsText)
        {
            var copy = new MenuItem { Header = "复制文字" };
            copy.Click += async (_, _) => await CopyMessageAsync(message);
            flyout.Items.Add(copy);
        }
        else
        {
            var reveal = new MenuItem { Header = message.IsOutgoing ? "打开文件" : "在文件夹中显示" };
            reveal.Click += (_, _) => RevealMessageFile(message);
            flyout.Items.Add(reveal);
        }

        flyout.ShowAt(control);
        e.Handled = true;
    }

    // MARK: - 拖拽文件

    private void OnDragEnter(object? sender, DragEventArgs e) => UpdateDragState(e);

    private void OnDragOver(object? sender, DragEventArgs e) => UpdateDragState(e);

    private void OnDragLeave(object? sender, DragEventArgs e) => _viewModel.IsDragOver = false;

    private void UpdateDragState(DragEventArgs e)
    {
        var transfer = e.DataTransfer;
        var hasFiles = transfer is not null && transfer.Contains(DataFormat.File);
        e.DragEffects = hasFiles ? DragDropEffects.Copy : DragDropEffects.None;
        _viewModel.IsDragOver = hasFiles;
    }

    private void OnDrop(object? sender, DragEventArgs e)
    {
        _viewModel.IsDragOver = false;

        try
        {
            var files = e.DataTransfer?.TryGetFiles();
            if (files is null)
            {
                return;
            }

            var paths = files
                .Select(file => file.TryGetLocalPath())
                .Where(path => !string.IsNullOrEmpty(path))
                .Select(path => path!)
                .ToList();

            _viewModel.AddStagedFiles(paths);
            e.DragEffects = DragDropEffects.Copy;
        }
        catch (Exception exception)
        {
            _viewModel.SetLocalFailure($"拖拽文件失败：{exception.Message}");
        }
    }
}
