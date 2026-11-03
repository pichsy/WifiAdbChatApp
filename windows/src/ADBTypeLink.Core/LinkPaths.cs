namespace ADBTypeLink.Core;

/// <summary>
/// 本机数据文件位置。Windows 用 %APPDATA%\\ADBTypeLink；
/// 在 macOS 上调试时用 ~/Library/Application Support/ADBTypeLink，
/// 绝不读写 macOS 正式端的 ~/Library/Application Support/ADBType。
/// </summary>
public sealed class LinkPaths
{
    public LinkPaths(string dataDirectory)
    {
        DataDirectory = Path.GetFullPath(dataDirectory);
        try
        {
            Directory.CreateDirectory(DataDirectory);
        }
        catch (Exception)
        {
            // 目录建不出来时后续读写会各自报错，这里不崩溃。
        }
    }

    public string DataDirectory { get; }

    /// <summary>设备 ID 文件（§8：device.json）。</summary>
    public string DeviceIdFile => Path.Combine(DataDirectory, "device.json");

    /// <summary>已配对设备 ID 列表（§8：paired.json，JSON 字符串数组）。</summary>
    public string PairedFile => Path.Combine(DataDirectory, "paired.json");

    /// <summary>旧版单文件聊天记录（§8：chat.json），仅用于迁移。</summary>
    public string ChatFile => Path.Combine(DataDirectory, "chat.json");

    /// <summary>按设备分开的聊天记录目录：chats/&lt;peerId&gt;.json。</summary>
    public string ChatsDirectory => Path.Combine(DataDirectory, "chats");

    /// <summary>好友名册（配对过 / 有过往来），格式与 macOS 的 friends.json 一致。</summary>
    public string FriendsFile => Path.Combine(DataDirectory, "friends.json");

    /// <summary>本机设置（接收目录等）。</summary>
    public string SettingsFile => Path.Combine(DataDirectory, "settings.json");

    /// <summary>按平台返回默认数据目录。</summary>
    public static string DefaultDataDirectory()
    {
        if (OperatingSystem.IsWindows())
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(appData))
            {
                appData = Path.Combine(HomeDirectory(), "AppData", "Roaming");
            }

            return Path.Combine(appData, "ADBTypeLink");
        }

        if (OperatingSystem.IsMacOS())
        {
            // 刻意与 macOS 正式端的 ADBType 目录区分开，避免污染。
            return Path.Combine(HomeDirectory(), "Library", "Application Support", "ADBTypeLink");
        }

        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        var baseDir = string.IsNullOrEmpty(xdg) ? Path.Combine(HomeDirectory(), ".config") : xdg;
        return Path.Combine(baseDir, "ADBTypeLink");
    }

    /// <summary>默认接收目录：下载目录下的「ADBType 接收」。</summary>
    public static string DefaultReceiveDirectory() => Path.Combine(HomeDirectory(), "Downloads", "ADBType 接收");

    private static string HomeDirectory()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrEmpty(home))
        {
            home = Environment.GetEnvironmentVariable("HOME");
        }

        if (string.IsNullOrEmpty(home))
        {
            home = Directory.GetCurrentDirectory();
        }

        return home;
    }
}

/// <summary>本机默认展示名。</summary>
public static class DeviceNameProvider
{
    public static string GetDefaultName()
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var machine = Environment.MachineName;
                if (!string.IsNullOrWhiteSpace(machine))
                {
                    return machine;
                }
            }
            else
            {
                var host = System.Net.Dns.GetHostName();
                if (!string.IsNullOrWhiteSpace(host))
                {
                    if (host.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
                    {
                        host = host[..^".local".Length];
                    }

                    return host;
                }
            }
        }
        catch (Exception)
        {
            // 取不到主机名就用兜底名称。
        }

        return OperatingSystem.IsWindows() ? "Windows 电脑" : "这台电脑";
    }
}
