using System.Collections.ObjectModel;
using System.Text.Json;
using ADBTypeLink.Core;
using Avalonia.Platform;
using Avalonia.Threading;

namespace ADBTypeLink.App.ViewModels;

public enum MobileFileStatus
{
    Pending,
    Sending,
    Done,
    Failed,
}

/// <summary>「移动设备」页待推到手机的文件。</summary>
public sealed class MobileFileItem : ObservableObject
{
    private MobileFileStatus _status = MobileFileStatus.Pending;
    private double _progress;
    private string? _message;

    public MobileFileItem(string path)
    {
        Path = path;
        Name = System.IO.Path.GetFileName(path);
        Size = SafeSize(path);
    }

    public string Path { get; }

    public string Name { get; }

    public long Size { get; }

    public string SizeText => FormatSize(Size);

    public MobileFileStatus Status
    {
        get => _status;
        set
        {
            if (SetProperty(ref _status, value))
            {
                OnPropertyChanged(nameof(IsSending));
                OnPropertyChanged(nameof(IsDone));
                OnPropertyChanged(nameof(IsFailed));
                OnPropertyChanged(nameof(BadgeText));
            }
        }
    }

    public double Progress
    {
        get => _progress;
        set
        {
            if (SetProperty(ref _progress, value))
            {
                OnPropertyChanged(nameof(BadgeText));
            }
        }
    }

    public string? Message
    {
        get => _message;
        set
        {
            if (SetProperty(ref _message, value))
            {
                OnPropertyChanged(nameof(HasMessage));
            }
        }
    }

    public bool HasMessage => !string.IsNullOrEmpty(_message);

    public bool IsSending => _status == MobileFileStatus.Sending;

    public bool IsDone => _status == MobileFileStatus.Done;

    public bool IsFailed => _status == MobileFileStatus.Failed;

    public string BadgeText => _status switch
    {
        MobileFileStatus.Pending => "待传",
        MobileFileStatus.Sending => $"{(int)Math.Round(_progress * 100)}%",
        MobileFileStatus.Done => "已传输",
        _ => "失败",
    };

    private static long SafeSize(string path)
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

    public static string FormatSize(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB" };
        double value = bytes;
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }

        return index == 0 ? $"{bytes} B" : $"{value:0.#} {units[index]}";
    }
}

/// <summary>
/// 「移动设备」页（对应 macOS 端的 <c>MobileDeviceView</c>）：
/// 通过 adb 把文字打进手机输入框 / 剪贴板，或把文件推到手机。
/// </summary>
public sealed class MobileDeviceViewModel : ObservableObject
{
    private const string DefaultTargetDir = "/sdcard/Download";

    private readonly AdbService _adb;
    private readonly Dispatcher _dispatcher;
    private readonly string _settingsPath;
    private readonly ObservableCollection<AdbDevice> _devices = new();
    private readonly ObservableCollection<string> _history = new();
    private readonly ObservableCollection<MobileFileItem> _files = new();

    private AdbDevice? _selectedDevice;
    private bool _scanning;
    private string? _deviceError;
    private bool _busy;
    private bool _sendingFiles;
    private bool _scanningInFlight;
    private string _input = string.Empty;
    private string _targetDir = DefaultTargetDir;
    private bool _clearFirst = true;
    private bool _pressEnter;
    private LinkStatusKind _statusKind = LinkStatusKind.Idle;
    private string _statusText = "连接手机并开启「USB 调试」，这里会自动列出设备";
    private DispatcherTimer? _timer;
    private bool _initialized;

    public MobileDeviceViewModel(AdbService? adb = null, string? settingsPath = null)
    {
        _adb = adb ?? new AdbService();
        _dispatcher = Dispatcher.UIThread;
        _settingsPath = settingsPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ADBTypeLink",
            "mobile.json");
    }

    public ObservableCollection<AdbDevice> Devices => _devices;

    public ObservableCollection<string> History => _history;

    public ObservableCollection<MobileFileItem> Files => _files;

    // MARK: - 生命周期

    public async Task InitializeAsync()
    {
        if (_initialized)
        {
            return;
        }

        _initialized = true;
        LoadSettings();

        await RefreshDevicesAsync(silent: true);

        // 和 macOS 端一致：每 4 秒静默刷新设备，插拔 / 开关无线调试都能即时反映。
        _timer = new DispatcherTimer(TimeSpan.FromSeconds(4), DispatcherPriority.Background, (_, _) => _ = AutoTickAsync());
        _timer.Start();
    }

    public void Dispose()
    {
        _timer?.Stop();
        _timer = null;
    }

    private async Task AutoTickAsync()
    {
        if (_busy || _scanningInFlight || !AdbAvailable)
        {
            return;
        }

        await RefreshDevicesAsync(silent: true);
    }

    // MARK: - adb

    public string AdbPath => _adb.AdbPath;

    public bool AdbAvailable => _adb.IsAvailable;

    public bool AdbMissing => !AdbAvailable;

    public string AdbFooterText => AdbAvailable ? _adb.AdbPath : "未找到 adb（platform-tools），可点右侧「设置」手动指定";

    /// <summary>重启 adb 服务端（5037 被别的工具占用时用来恢复）。</summary>
    public async Task RestartAdbServerAsync()
    {
        if (_busy)
        {
            return;
        }

        Busy = true;
        SetStatus(LinkStatusKind.Idle, "正在重启 adb 服务…");
        try
        {
            await _adb.RestartServerAsync().ConfigureAwait(true);
            await RefreshDevicesAsync(silent: false).ConfigureAwait(true);
            if (_devices.Count > 0)
            {
                SetStatus(LinkStatusKind.Success, $"adb 服务已重启，检测到 {_devices.Count} 台设备");
            }
        }
        catch (Exception ex)
        {
            SetStatus(LinkStatusKind.Failure, $"重启 adb 失败：{ex.Message}");
        }
        finally
        {
            Busy = false;
        }
    }

    public void SetAdbPath(string path)
    {
        _adb.SetAdbPath(path);
        OnPropertyChanged(nameof(AdbPath));
        OnPropertyChanged(nameof(AdbAvailable));
        OnPropertyChanged(nameof(AdbMissing));
        OnPropertyChanged(nameof(AdbFooterText));
        _ = RefreshDevicesAsync(silent: false);
        SaveSettings();
    }

    // MARK: - 设备

    public AdbDevice? SelectedDevice
    {
        get => _selectedDevice;
        set
        {
            if (SetProperty(ref _selectedDevice, value))
            {
                OnPropertyChanged(nameof(SelectedSerial));
                OnPropertyChanged(nameof(TargetDeviceText));
                OnPropertyChanged(nameof(CanSend));
                OnPropertyChanged(nameof(CanPushFiles));
                SaveSettings();
            }
        }
    }

    public string SelectedSerial => _selectedDevice?.Serial ?? string.Empty;

    public string TargetDeviceText => _selectedDevice is null
        ? "目标设备：未连接手机"
        : $"目标设备：{_selectedDevice.DisplayName}";

    public bool HasDevices => _devices.Count > 0;

    public bool NoDevices => _devices.Count == 0;

    public bool Scanning
    {
        get => _scanning;
        private set => SetProperty(ref _scanning, value);
    }

    public string? DeviceError
    {
        get => _deviceError;
        private set
        {
            if (SetProperty(ref _deviceError, value))
            {
                OnPropertyChanged(nameof(HasDeviceError));
                OnPropertyChanged(nameof(DeviceErrorText));
            }
        }
    }

    public bool HasDeviceError => !string.IsNullOrEmpty(_deviceError);

    public string DeviceErrorText => _deviceError ?? "连接手机，并在开发者选项中开启 USB 调试";

    public async Task RefreshDevicesAsync(bool silent)
    {
        if (_scanningInFlight)
        {
            return;
        }

        if (!AdbAvailable)
        {
            DeviceError = "未找到 adb（platform-tools），请在底部「设置」里指定 adb.exe 路径";
            return;
        }

        _scanningInFlight = true;
        if (!silent)
        {
            Scanning = true;
        }

        try
        {
            var (devices, error) = await _adb.ListDevicesAsync().ConfigureAwait(true);
            _devices.Clear();
            foreach (var device in devices)
            {
                _devices.Add(device);
            }

            DeviceError = error;

            var keep = _selectedDevice is not null && devices.Any(item => item.Serial == _selectedDevice.Serial);
            if (!keep)
            {
                SelectedDevice = devices.FirstOrDefault();
            }

            OnPropertyChanged(nameof(HasDevices));
            OnPropertyChanged(nameof(NoDevices));

            if (!silent)
            {
                if (error is not null && devices.Count == 0)
                {
                    SetStatus(LinkStatusKind.Failure, error);
                }
                else if (_selectedDevice is not null)
                {
                    SetStatus(LinkStatusKind.Idle, $"已连接 {_selectedDevice.DisplayName}");
                }
                else
                {
                    SetStatus(LinkStatusKind.Idle, DeviceErrorText);
                }
            }
        }
        catch (Exception ex)
        {
            DeviceError = AdbService.Friendly(ex.Message, "adb 执行失败");
        }
        finally
        {
            _scanningInFlight = false;
            Scanning = false;
        }
    }

    // MARK: - 文字

    public string Input
    {
        get => _input;
        set
        {
            if (SetProperty(ref _input, value))
            {
                OnPropertyChanged(nameof(NeedsClipboard));
                OnPropertyChanged(nameof(ClipboardHint));
                OnPropertyChanged(nameof(SendButtonText));
                OnPropertyChanged(nameof(CanSend));
            }
        }
    }

    /// <summary>含中文 / emoji 时走剪贴板，纯 ASCII 直接 input text。</summary>
    public bool NeedsClipboard => AdbService.NeedsClipboard(_input);

    public string ClipboardHint => NeedsClipboard
        ? "含中文或表情：复制到手机剪贴板，再到手机上长按输入框点「粘贴」"
        : "纯英文 / 数字：直接输入，秒发";

    public bool ClearFirst
    {
        get => _clearFirst;
        set
        {
            if (SetProperty(ref _clearFirst, value))
            {
                SaveSettings();
            }
        }
    }

    public bool PressEnter
    {
        get => _pressEnter;
        set
        {
            if (SetProperty(ref _pressEnter, value))
            {
                SaveSettings();
            }
        }
    }

    public bool Busy
    {
        get => _busy;
        private set
        {
            if (SetProperty(ref _busy, value))
            {
                OnPropertyChanged(nameof(CanSend));
                OnPropertyChanged(nameof(CanRefresh));
                OnPropertyChanged(nameof(CanPushFiles));
            }
        }
    }

    public bool CanSend => !_busy && _selectedDevice is not null;
    public bool CanRefresh => !_busy;

    public string SendButtonText => _busy
        ? (NeedsClipboard ? "正在复制…" : "发送中…")
        : (NeedsClipboard ? "发送到设备剪贴板" : "发送到输入框");

    public async Task<SendOutcome?> SendTextAsync()
    {
        if (_busy)
        {
            return null;
        }

        var device = _selectedDevice;
        if (device is null)
        {
            SetStatus(LinkStatusKind.Failure, DeviceError ?? "未检测到设备，请连接手机并开启 USB 调试");
            return null;
        }

        var text = (_input ?? string.Empty).Trim();
        var usesClipboard = AdbService.NeedsClipboard(text);
        // 剪贴板模式只写剪贴板，不动手机界面：清空 / 回车交给用户自己完成。
        var shouldClear = _clearFirst && !usesClipboard;
        var shouldEnter = _pressEnter && !usesClipboard;

        if (text.Length == 0 && !shouldClear && !shouldEnter)
        {
            SetStatus(LinkStatusKind.Failure, "请输入要发送的内容");
            return null;
        }

        Busy = true;
        SetStatus(LinkStatusKind.Idle, usesClipboard ? "正在复制到手机剪贴板…" : "发送中…");

        try
        {
            string? failure = null;
            var didClear = false;
            var didType = false;
            var didCopy = false;

            if (shouldClear)
            {
                var result = await _adb.ClearInputAsync(device.Serial).ConfigureAwait(true);
                if (result.Ok)
                {
                    didClear = true;
                }
                else
                {
                    failure = AdbService.Friendly(result.Text, "清空设备输入框失败");
                }
            }

            if (failure is null && usesClipboard)
            {
                var error = await _adb.SetClipboardAsync(device.Serial, text, ClipJarPath()).ConfigureAwait(true);
                if (error is null)
                {
                    didCopy = true;
                }
                else
                {
                    failure = error;
                }
            }
            else if (failure is null && text.Length > 0)
            {
                var result = await _adb.InputTextAsync(device.Serial, text).ConfigureAwait(true);
                if (result.Ok)
                {
                    didType = true;
                }
                else
                {
                    failure = AdbService.Friendly(result.Text, "发送文本失败");
                }
            }

            if (failure is null && shouldEnter)
            {
                var result = await _adb.PressEnterAsync(device.Serial).ConfigureAwait(true);
                if (!result.Ok)
                {
                    failure = AdbService.Friendly(result.Text, "发送回车键失败");
                }
            }

            if (failure is not null)
            {
                SetStatus(LinkStatusKind.Failure, failure);
                return SendOutcome.Failure(failure);
            }

            string summary;
            if (didCopy)
            {
                var preview = text.Length > 18 ? text[..18] + "…" : text;
                summary = $"已复制「{preview}」到手机剪贴板 · 请在手机上长按输入框，点「粘贴」";
            }
            else if (didType)
            {
                summary = $"已发送「{text}」";
            }
            else if (didClear)
            {
                summary = "已清空设备输入框";
            }
            else
            {
                summary = "已发送回车键";
            }

            if (shouldEnter && didType)
            {
                summary += "，并按下回车";
            }

            SetStatus(LinkStatusKind.Success, summary + "  ·  " + DateTime.Now.ToString("HH:mm:ss"));

            if (didType || didCopy)
            {
                PushHistory(text);
            }

            return SendOutcome.Ok(device.DisplayName, summary);
        }
        catch (Exception ex)
        {
            SetStatus(LinkStatusKind.Failure, $"发送失败：{ex.Message}");
            return SendOutcome.Failure(ex.Message);
        }
        finally
        {
            Busy = false;
        }
    }

    // MARK: - 历史

    public bool HasHistory => _history.Count > 0;

    public void UseHistory(string item) => Input = item;

    public void ClearHistory()
    {
        _history.Clear();
        OnPropertyChanged(nameof(HasHistory));
        SaveSettings();
    }

    private void PushHistory(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var existing = _history.FirstOrDefault(item => item == text);
        if (existing is not null)
        {
            _history.Remove(existing);
        }

        _history.Insert(0, text);
        while (_history.Count > 12)
        {
            _history.RemoveAt(_history.Count - 1);
        }

        OnPropertyChanged(nameof(HasHistory));
        SaveSettings();
    }

    // MARK: - 文件

    public string TargetDir
    {
        get => _targetDir;
        set
        {
            if (SetProperty(ref _targetDir, value))
            {
                SaveSettings();
            }
        }
    }

    public void ResetTargetDir() => TargetDir = DefaultTargetDir;

    public bool HasFiles => _files.Count > 0;

    public int PendingCount => _files.Count(item => item.Status is MobileFileStatus.Pending or MobileFileStatus.Failed);

    public string PendingText => $"共 {PendingCount} 个文件待传";

    public string TotalSizeText => MobileFileItem.FormatSize(_files.Sum(item => item.Size));

    public bool SendingFiles
    {
        get => _sendingFiles;
        private set
        {
            if (SetProperty(ref _sendingFiles, value))
            {
                OnPropertyChanged(nameof(CanPushFiles));
            }
        }
    }

    public bool CanPushFiles => !_sendingFiles && _selectedDevice is not null && PendingCount > 0;

    public void AddFiles(IEnumerable<string> paths)
    {
        if (_sendingFiles)
        {
            return;
        }

        var seen = new HashSet<string>(_files.Select(item => item.Path), StringComparer.OrdinalIgnoreCase);
        foreach (var path in paths)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                continue;
            }

            var full = Path.GetFullPath(path);
            if (seen.Add(full))
            {
                _files.Add(new MobileFileItem(full));
            }
        }

        RaiseFileProperties();
    }

    public void RemoveFile(MobileFileItem item)
    {
        if (_sendingFiles)
        {
            return;
        }

        _files.Remove(item);
        RaiseFileProperties();
    }

    public void ClearFiles()
    {
        if (_sendingFiles)
        {
            return;
        }

        _files.Clear();
        RaiseFileProperties();
    }

    private void RaiseFileProperties()
    {
        OnPropertyChanged(nameof(HasFiles));
        OnPropertyChanged(nameof(PendingCount));
        OnPropertyChanged(nameof(PendingText));
        OnPropertyChanged(nameof(TotalSizeText));
        OnPropertyChanged(nameof(CanPushFiles));
    }

    public async Task PushFilesAsync()
    {
        if (_sendingFiles)
        {
            return;
        }

        var device = _selectedDevice;
        if (device is null)
        {
            SetStatus(LinkStatusKind.Failure, "未检测到设备，请连接手机并开启 USB 调试");
            return;
        }

        var pending = _files.Where(item => item.Status is MobileFileStatus.Pending or MobileFileStatus.Failed).ToList();
        if (pending.Count == 0)
        {
            SetStatus(LinkStatusKind.Failure, "没有待传的文件");
            return;
        }

        var directory = string.IsNullOrWhiteSpace(_targetDir) ? DefaultTargetDir : _targetDir.Trim();

        SendingFiles = true;
        Busy = true;
        var succeeded = 0;
        SetStatus(LinkStatusKind.Idle, $"正在传输 {pending.Count} 个文件…");

        try
        {
            foreach (var item in pending)
            {
                if (!File.Exists(item.Path))
                {
                    item.Status = MobileFileStatus.Failed;
                    item.Message = "文件已经不在了";
                    continue;
                }

                item.Status = MobileFileStatus.Sending;
                item.Message = null;
                item.Progress = 0;

                var progress = new Progress<double>(value =>
                {
                    _dispatcher.Post(() => item.Progress = value);
                });

                var result = await _adb.PushAsync(device.Serial, item.Path, directory, progress).ConfigureAwait(true);
                if (result.Ok)
                {
                    item.Status = MobileFileStatus.Done;
                    item.Progress = 1;
                    succeeded++;
                }
                else
                {
                    item.Status = MobileFileStatus.Failed;
                    item.Message = AdbService.Friendly(result.Text, "传输失败");
                }
            }

            if (succeeded == pending.Count)
            {
                SetStatus(LinkStatusKind.Success, $"已把 {succeeded} 个文件传到手机 {directory}");
            }
            else if (succeeded == 0)
            {
                var first = pending.FirstOrDefault(item => item.Status == MobileFileStatus.Failed);
                SetStatus(LinkStatusKind.Failure, first?.Message ?? "传输失败");
            }
            else
            {
                SetStatus(LinkStatusKind.Failure, $"成功 {succeeded} 个，失败 {pending.Count - succeeded} 个");
            }
        }
        catch (Exception ex)
        {
            SetStatus(LinkStatusKind.Failure, $"传输失败：{ex.Message}");
        }
        finally
        {
            SendingFiles = false;
            Busy = false;
            RaiseFileProperties();
        }
    }

    // MARK: - 状态

    public LinkStatusKind StatusKind
    {
        get => _statusKind;
        private set
        {
            if (SetProperty(ref _statusKind, value))
            {
                OnPropertyChanged(nameof(StatusIsFailure));
            }
        }
    }

    public bool StatusIsFailure => _statusKind == LinkStatusKind.Failure;

    public string StatusText
    {
        get => _statusText;
        private set => SetProperty(ref _statusText, value);
    }

    public void SetStatus(LinkStatusKind kind, string text)
    {
        StatusKind = kind;
        StatusText = text;
    }

    // MARK: - 内置剪贴板组件

    /// <summary>把内嵌的 adbtype-clip.jar 释放到临时目录，供 adb push 使用。</summary>
    private static string? ClipJarPath()
    {
        try
        {
            var target = Path.Combine(Path.GetTempPath(), "ADBTypeLink", "adbtype-clip.jar");
            if (File.Exists(target) && new FileInfo(target).Length > 0)
            {
                return target;
            }

            var directory = Path.GetDirectoryName(target);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            using var source = AssetLoader.Open(new Uri("avares://ADBTypeLink.App/Assets/adbtype-clip.jar"));
            using var destination = File.Create(target);
            source.CopyTo(destination);
            return target;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // MARK: - 设置持久化

    private sealed class MobileSettings
    {
        public string? AdbPath { get; set; }

        public bool ClearFirst { get; set; } = true;

        public bool PressEnter { get; set; }

        public string TargetDir { get; set; } = DefaultTargetDir;

        public string? SelectedSerial { get; set; }

        public List<string> History { get; set; } = new();
    }

    private void LoadSettings()
    {
        try
        {
            if (!File.Exists(_settingsPath))
            {
                return;
            }

            var settings = JsonSerializer.Deserialize<MobileSettings>(File.ReadAllText(_settingsPath));
            if (settings is null)
            {
                return;
            }

            if (!string.IsNullOrWhiteSpace(settings.AdbPath))
            {
                _adb.SetAdbPath(settings.AdbPath);
                OnPropertyChanged(nameof(AdbPath));
                OnPropertyChanged(nameof(AdbAvailable));
                OnPropertyChanged(nameof(AdbMissing));
                OnPropertyChanged(nameof(AdbFooterText));
            }

            _clearFirst = settings.ClearFirst;
            _pressEnter = settings.PressEnter;
            _targetDir = string.IsNullOrWhiteSpace(settings.TargetDir) ? DefaultTargetDir : settings.TargetDir;

            foreach (var item in settings.History ?? new List<string>())
            {
                if (!string.IsNullOrWhiteSpace(item))
                {
                    _history.Add(item);
                }
            }

            OnPropertyChanged(nameof(ClearFirst));
            OnPropertyChanged(nameof(PressEnter));
            OnPropertyChanged(nameof(TargetDir));
            OnPropertyChanged(nameof(HasHistory));
        }
        catch (Exception)
        {
            // 设置文件坏了就用默认值，不影响功能。
        }
    }

    private void SaveSettings()
    {
        try
        {
            var directory = Path.GetDirectoryName(_settingsPath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var settings = new MobileSettings
            {
                AdbPath = _adb.AdbPath,
                ClearFirst = _clearFirst,
                PressEnter = _pressEnter,
                TargetDir = _targetDir,
                SelectedSerial = _selectedDevice?.Serial,
                History = _history.ToList(),
            };

            File.WriteAllText(_settingsPath, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception)
        {
            // 保存失败不影响使用。
        }
    }
}
