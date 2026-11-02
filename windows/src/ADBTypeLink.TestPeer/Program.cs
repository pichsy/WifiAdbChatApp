using System.Text;

namespace ADBTypeLink.TestPeer;

/// <summary>
/// 命令行联调端：用于和 macOS 端（真实 LANModel）或另一个 Windows 端做端到端互通验证。
///
///   serve --code 123456 --recv-dir &lt;dir&gt; [--data-dir &lt;dir&gt;] [--name WinProbe] [--seconds 120]
///   send  --peer-name &lt;名字&gt; --text &lt;文字&gt; [--file &lt;路径&gt;] [--code 123456] [--data-dir &lt;dir&gt;] [--name WinProbe]
///
/// serve 输出：
///   READY code=123456 port=58205
///   MSG incoming TEXT 你好
///   MSG incoming FILE name="a.txt" size=1024 path="/.../a.txt"
///
/// send 输出：
///   RESULT ok / RESULT needs-pairing peer="..." / RESULT failure message="..."
/// </summary>
internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;

        if (args.Length == 0)
        {
            PrintUsage();
            return 2;
        }

        var command = args[0].ToLowerInvariant();
        var options = CommandLine.Parse(args.Skip(1).ToArray());

        try
        {
            switch (command)
            {
                case "serve":
                    return await ServeCommand.RunAsync(options);
                case "send":
                    return await SendCommand.RunAsync(options);
                case "help":
                case "-h":
                case "--help":
                    PrintUsage();
                    return 0;
                default:
                    Console.Error.WriteLine($"未知子命令: {command}");
                    PrintUsage();
                    return 2;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"执行失败: {ex}");
            return 1;
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine("ADBTypeLink.TestPeer - 局域网传输联调端");
        Console.WriteLine();
        Console.WriteLine("接收模式:");
        Console.WriteLine("  serve --code 123456 --recv-dir <目录> [--data-dir <目录>] [--name WinProbe] [--seconds 120]");
        Console.WriteLine();
        Console.WriteLine("发送模式:");
        Console.WriteLine("  send --peer-name <对端名称> --text <文字> [--file <文件路径> ...] [--code 123456]");
        Console.WriteLine("       [--peer-id <设备ID>] [--data-dir <目录>] [--name WinProbe] [--timeout 25]");
        Console.WriteLine();
        Console.WriteLine("说明：");
        Console.WriteLine("  --code 6 位配对码；serve 不传会随机生成并打印，send 不传表示已配对或首次发送（会返回 needs-pairing）。");
        Console.WriteLine("  退出码：0 成功，1 失败，2 参数错误。");
    }
}
