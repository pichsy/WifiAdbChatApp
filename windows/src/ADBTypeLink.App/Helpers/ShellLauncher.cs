using System.Diagnostics;

namespace ADBTypeLink.App.Helpers;

/// <summary>跨平台打开目录 / 打开文件 / 在文件管理器中定位文件。</summary>
public static class ShellLauncher
{
    public static bool TryOpenDirectory(string path)
    {
        try
        {
            if (!Directory.Exists(path))
            {
                return false;
            }

            if (OperatingSystem.IsWindows())
            {
                return Start("explorer.exe", $"\"{path}\"");
            }

            if (OperatingSystem.IsMacOS())
            {
                return Start("open", null, path);
            }

            return Start("xdg-open", null, path);
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static bool TryOpenFile(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return false;
            }

            if (OperatingSystem.IsWindows())
            {
                var info = new ProcessStartInfo(path) { UseShellExecute = true };
                Process.Start(info);
                return true;
            }

            if (OperatingSystem.IsMacOS())
            {
                return Start("open", null, path);
            }

            return Start("xdg-open", null, path);
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static bool TryRevealFile(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return false;
            }

            if (OperatingSystem.IsWindows())
            {
                return Start("explorer.exe", $"/select,\"{path}\"");
            }

            if (OperatingSystem.IsMacOS())
            {
                return Start("open", null, "-R", path);
            }

            var directory = Path.GetDirectoryName(path);
            return directory is not null && TryOpenDirectory(directory);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool Start(string fileName, string? arguments, params string[] argumentList)
    {
        var info = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = true,
            CreateNoWindow = true,
        };

        if (arguments is not null)
        {
            info.Arguments = arguments;
        }

        foreach (var argument in argumentList)
        {
            info.ArgumentList.Add(argument);
        }

        Process.Start(info);
        return true;
    }
}
