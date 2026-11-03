using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Media.Imaging;
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
                desktop.ShutdownMode = ShutdownMode.OnMainWindowClose;
            }
        }

        base.OnFrameworkInitializationCompleted();
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
