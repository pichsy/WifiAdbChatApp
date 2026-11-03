using Avalonia;

namespace ADBTypeLink.App;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            if (eventArgs.ExceptionObject is Exception exception)
            {
                Console.Error.WriteLine($"unhandled: {exception}");
            }
        };

        TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
        {
            Console.Error.WriteLine($"unobserved task: {eventArgs.Exception}");
            eventArgs.SetObserved();
        };

        var screenshotIndex = Array.IndexOf(args, "--screenshot");
        if (screenshotIndex >= 0 && screenshotIndex + 1 < args.Length)
        {
            App.ScreenshotPath = args[screenshotIndex + 1];
        }

        App.DemoMode = args.Contains("--demo", StringComparer.Ordinal);
        App.DemoHeavy = args.Contains("--demo-heavy", StringComparer.Ordinal);

        var tabIndex = Array.IndexOf(args, "--tab");
        if (tabIndex >= 0 && tabIndex + 1 < args.Length)
        {
            App.StartTab = args[tabIndex + 1];
        }

        var themeIndex = Array.IndexOf(args, "--theme");
        if (themeIndex >= 0 && themeIndex + 1 < args.Length)
        {
            App.ThemeOverride = args[themeIndex + 1];
        }

        // --screenshot / --demo 时不要把参数再交给 Avalonia 的命令行解析。
        var lifetimeArgs = App.ScreenshotPath is null && !App.DemoMode ? args : Array.Empty<string>();

        try
        {
            BuildAvaloniaApp().StartWithClassicDesktopLifetime(lifetimeArgs);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"fatal: {exception}");
        }
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
}
