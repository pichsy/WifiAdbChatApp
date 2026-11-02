using ADBTypeLink.Core;

namespace ADBTypeLink.TestPeer;

/// <summary>接收模式：启动引擎并持续打印收到的消息，便于和 macOS 端联调。</summary>
internal static class ServeCommand
{
    public static async Task<int> RunAsync(CommandLine options)
    {
        var name = options.Get("name") ?? "WinProbe";
        var code = options.Get("code");
        if (code is not null && (code.Length != 6 || !code.All(char.IsAsciiDigit)))
        {
            Console.Error.WriteLine("--code 必须是 6 位数字");
            return 2;
        }

        var dataDir = options.Get("data-dir") ?? Path.Combine(LinkPaths.DefaultDataDirectory(), "testpeer", "serve");
        var receiveDir = options.Get("recv-dir") ?? LinkPaths.DefaultReceiveDirectory();
        var seconds = options.GetInt("seconds", 120);
        var verbose = options.Has("verbose");

        var engineOptions = new LinkEngineOptions
        {
            DataDirectory = dataDir,
            ReceiveDirectory = receiveDir,
            DeviceName = name,
            PairingCode = code,
        };

        await using var engine = new LinkEngine(engineOptions);
        var knownPeers = new HashSet<string>(StringComparer.Ordinal);
        var sync = new object();

        void WriteLine(string line)
        {
            lock (sync)
            {
                Console.WriteLine(line);
                Console.Out.Flush();
            }
        }

        engine.MessageAdded += (_, message) =>
        {
            if (message.Direction == MessageDirection.Incoming && message.Kind == MessageKind.Text)
            {
                WriteLine($"MSG incoming TEXT {OneLine(message.Text)}");
            }
            else if (message.Direction == MessageDirection.Incoming)
            {
                WriteLine($"MSG incoming FILE name=\"{OneLine(message.FileName)}\" size={message.FileSize} path=\"{OneLine(message.FilePath)}\"");
            }
            else if (message.Kind == MessageKind.Text)
            {
                WriteLine($"MSG outgoing TEXT {OneLine(message.Text)}");
            }
            else
            {
                WriteLine($"MSG outgoing FILE name=\"{OneLine(message.FileName)}\" size={message.FileSize}");
            }
        };

        engine.PairRequested += (_, eventArgs) =>
            WriteLine($"PAIR_REQUEST peer=\"{OneLine(eventArgs.PeerName)}\" id={eventArgs.PeerId}");

        engine.PairingChanged += (_, _) =>
            WriteLine($"PAIRING count={engine.PairedCount}");

        engine.PeersChanged += (_, peers) =>
        {
            foreach (var peer in peers)
            {
                if (knownPeers.Add(peer.Id))
                {
                    WriteLine($"PEER name=\"{OneLine(peer.Name)}\" host={peer.Host} port={peer.Port} id={peer.Id} paired={engine.IsPaired(peer.Id)}");
                }
            }
        };

        engine.StatusChanged += (_, status) =>
        {
            if (verbose)
            {
                WriteLine($"STATUS {status.Text}");
            }
        };

        await engine.StartAsync();

        WriteLine($"DEVICE id={engine.DeviceId} name={engine.DeviceName}");
        WriteLine($"DATA_DIR {engine.DataDirectory}");
        WriteLine($"RECV_DIR {engine.ReceiveDir}");
        WriteLine($"READY code={engine.PairingCode} port={engine.ListenPort}");

        if (seconds <= 0)
        {
            WriteLine("SERVING until Ctrl+C");
            using var cts = new CancellationTokenSource();
            Console.CancelKeyPress += (_, eventArgs) =>
            {
                eventArgs.Cancel = true;
                cts.Cancel();
            };
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cts.Token);
            }
            catch (OperationCanceledException)
            {
                // Ctrl+C 正常退出。
            }
        }
        else
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds));
        }

        WriteLine("DONE");
        return 0;
    }

    private static string OneLine(string? value) =>
        (value ?? string.Empty)
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal);
}
