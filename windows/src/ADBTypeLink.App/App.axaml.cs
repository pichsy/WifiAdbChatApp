using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Styling;
using ADBTypeLink.App.ViewModels;

namespace ADBTypeLink.App;

public partial class App : Application
{
    /// <summary>--screenshot &lt;png&gt;：离屏渲染主窗口后退出（用于自动化检查界面）。</summary>
    public static string? ScreenshotPath { get; set; }

    /// <summary>--demo：用演示数据启动界面，不启动网络。</summary>
    public static bool DemoMode { get; set; }

    /// <summary>--theme light|dark：强制浅色 / 深色，便于截图核对。</summary>
    public static string? ThemeOverride { get; set; }

    /// <summary>--demo-heavy：演示数据塞满聊天区，用来验证自动滚动到底部。</summary>
    public static bool DemoHeavy { get; set; }

    /// <summary>--tab computers|mobile：启动时切到指定页签（截图 / 自动化核对用）。</summary>
    public static string? StartTab { get; set; }

    private TrayIcon? _trayIcon;
    private TrayIcons? _trayIcons;
    private MainWindow? _mainWindow;
    private bool _exitRequested;

    /// <summary>当前 App 实例，供窗口层调用「显示主窗口 / 退出」。</summary>
    public static App? Instance => Current as App;

    /// <summary>true 表示已经在走退出流程，主窗口的 Closing 不再拦成「收进托盘」。</summary>
    public bool IsExitRequested => _exitRequested;

    /// <summary>托盘图标是否建成功：建失败时关闭窗口必须真的退出，否则用户没有别的出口。</summary>
    public bool IsTrayAvailable => _trayIcon is not null;

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            if (string.Equals(ThemeOverride, "light", StringComparison.OrdinalIgnoreCase))
            {
                RequestedThemeVariant = ThemeVariant.Light;
            }
            else if (string.Equals(ThemeOverride, "dark", StringComparison.OrdinalIgnoreCase))
            {
                RequestedThemeVariant = ThemeVariant.Dark;
            }

            var useDemoData = DemoMode || ScreenshotPath is not null;
            var window = useDemoData
                ? new MainWindow(MainViewModel.CreateDemo(DemoHeavy))
                : new MainWindow();

            desktop.MainWindow = window;
            _mainWindow = window;

            if (string.Equals(StartTab, "computers", StringComparison.OrdinalIgnoreCase))
            {
                window.SelectTab(1);
            }
            else if (string.Equals(StartTab, "mobile", StringComparison.OrdinalIgnoreCase))
            {
                window.SelectTab(0);
            }

            if (ScreenshotPath is not null)
            {
                desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
                window.Opened += async (_, _) =>
                {
                    try
                    {
                        // 等一帧布局稳定后再渲染。
                        await Task.Delay(1500);
                        window.PrepareForScreenshot();
                        CaptureWindow(window, ScreenshotPath);
                        Console.WriteLine($"SCREENSHOT {ScreenshotPath}");
                        Console.Out.Flush();
                    }
                    catch (Exception exception)
                    {
                        Console.Error.WriteLine($"screenshot failed: {exception}");
                    }
                    finally
                    {
                        desktop.Shutdown();
                    }
                };
            }
            else
            {
                // 关闭窗口不再结束进程：点 ✕ 只是把窗口收进托盘，后台继续收发，
                // 真正退出走托盘菜单或界面「⋯ → 退出程序」。
                // 万一托盘建不出来，退回「关窗即退出」，不能让窗口消失后进程还赖在后台。
                desktop.ShutdownMode = CreateTrayIcon()
                    ? ShutdownMode.OnExplicitShutdown
                    : ShutdownMode.OnMainWindowClose;
            }
        }

        base.OnFrameworkInitializationCompleted();
    }

    // MARK: - 托盘图标 / 显示 / 退出

    /// <summary>点 ✕ 后在托盘里放一个图标：左键点它恢复窗口，右键菜单可以退出。</summary>
    /// <returns>托盘图标是否创建成功。</returns>
    private bool CreateTrayIcon()
    {
        try
        {
            var icon = LoadTrayIcon();

            var menu = new NativeMenu();

            var showItem = new NativeMenuItem("显示主窗口");
            showItem.Click += (_, _) => ShowMainWindow();
            menu.Add(showItem);

            menu.Add(new NativeMenuItemSeparator());

            var exitItem = new NativeMenuItem("退出文件互传助手");
            exitItem.Click += (_, _) => ExitApplication();
            menu.Add(exitItem);

            _trayIcon = new TrayIcon
            {
                Icon = icon,
                ToolTipText = "文件互传助手 · 点这里打开，右键退出",
                Menu = menu,
                IsVisible = true,
            };
            _trayIcon.Clicked += (_, _) => ShowMainWindow();

            // Avalonia 要求把托盘图标挂在 Application 的 TrayIcon.Icons 附加属性上才会真正创建。
            _trayIcons = new TrayIcons { _trayIcon };
            TrayIcon.SetIcons(this, _trayIcons);
            return true;
        }
        catch (Exception exception)
        {
            // 托盘不可用时退回原来的行为：关闭窗口就是退出，不能把用户困在后台。
            _trayIcon = null;
            _trayIcons = null;
            Console.Error.WriteLine($"tray icon unavailable: {exception}");
            return false;
        }
    }

    private static WindowIcon LoadTrayIcon()
    {
        // 托盘用多尺寸 .ico 最清晰；个别环境解不了 ico 就退回窗口用的 png。
        try
        {
            return new WindowIcon(AssetLoader.Open(new Uri("avares://ADBTypeLink.App/Assets/app.ico")));
        }
        catch (Exception)
        {
            return new WindowIcon(AssetLoader.Open(new Uri("avares://ADBTypeLink.App/Assets/app-icon.png")));
        }
    }

    /// <summary>从托盘恢复主窗口（最小化过就先还原，再显示并置前）。</summary>
    public void ShowMainWindow()
    {
        var window = _mainWindow;
        if (window is null)
        {
            return;
        }

        try
        {
            if (window.WindowState == WindowState.Minimized)
            {
                window.WindowState = WindowState.Normal;
            }

            window.Show();
            window.Activate();
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"show main window failed: {exception}");
        }
    }

    /// <summary>真正退出：收掉托盘图标，交给 Avalonia 关闭窗口并结束进程。</summary>
    public void ExitApplication()
    {
        if (_exitRequested)
        {
            return;
        }

        _exitRequested = true;

        if (_trayIcon is not null)
        {
            _trayIcon.IsVisible = false;
        }

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.Shutdown();
        }
    }

    private static void CaptureWindow(Window window, string path)
    {
        var width = (int)Math.Ceiling(window.Bounds.Width);
        var height = (int)Math.Ceiling(window.Bounds.Height);
        if (width <= 0 || height <= 0)
        {
            width = (int)window.Width;
            height = (int)window.Height;
        }

        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        using var bitmap = new RenderTargetBitmap(new PixelSize(width, height), new Vector(96, 96));
        bitmap.Render(window);
        bitmap.Save(fullPath);
    }
}
