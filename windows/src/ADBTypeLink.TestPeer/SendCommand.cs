using ADBTypeLink.Core;

namespace ADBTypeLink.TestPeer;

/// <summary>发送模式：发现对端 → 发送文字/文件 → 打印 RESULT。</summary>
internal static class SendCommand
{
    public static async Task<int> RunAsync(CommandLine options)
    {
        var name = options.Get("name") ?? "WinProbe";
        var peerName = options.Get("peer-name");
        var peerId = options.Get("peer-id");
        var text = options.Get("text");
        var files = options.GetAll("file");
        var code = options.Get("code");
        var timeoutSeconds = options.GetInt("timeout", 25);
        var verbose = options.Has("verbose");

        if (peerName is null && peerId is null)
        {
            Console.Error.WriteLine("需要 --peer-name 或 --peer-id");
            return 2;
        }

        if (text is null && files.Count == 0)
        {
            Console.Error.WriteLine("需要 --text 或 --file");
            return 2;
        }

        if (code is not null && (code.Length != 6 || !code.All(char.IsAsciiDigit)))
        {
            Console.Error.WriteLine("--code 必须是 6 位数字");
            return 2;
        }

        var dataDir = options.Get("data-dir") ?? Path.Combine(LinkPaths.DefaultDataDirectory(), "testpeer", "send");
        var receiveDir = options.Get("recv-dir") ?? LinkPaths.DefaultReceiveDirectory();

        await using var engine = new LinkEngine(new LinkEngineOptions
        {
            DataDirectory = dataDir,
            ReceiveDirectory = receiveDir,
            DeviceName = name,
        });

        var sync = new object();
        var knownPeers = new HashSet<string>(StringComparer.Ordinal);

        void WriteLine(string line)
        {
            lock (sync)
            {
                Console.WriteLine(line);
                Console.Out.Flush();
            }
        }

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
        WriteLine($"WAITING peer={(peerName ?? peerId)} timeout={timeoutSeconds}s");

        LinkPeer? peer = null;
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            peer = FindPeer(engine, peerName, peerId);
            if (peer is not null)
            {
                break;
            }

            await Task.Delay(200);
        }

        if (peer is null)
        {
            WriteLine($"RESULT failure message=\"在 {timeoutSeconds} 秒内没有发现「{peerName ?? peerId}」\"");
            return 1;
        }

        WriteLine($"PEER id={peer.Id} name=\"{OneLine(peer.Name)}\" host={peer.Host} port={peer.Port} paired={engine.IsPaired(peer.Id)}");

        var worst = 0;
        if (text is not null)
        {
            var outcome = await engine.SendTextAsync(peer, text, code);
            worst = Math.Max(worst, Report("text", outcome, WriteLine));
        }

        if (files.Count > 0)
        {
            var outcome = await engine.SendFilesAsync(peer, files, code);
            worst = Math.Max(worst, Report("file", outcome, WriteLine));
        }

        await Task.Delay(300);
        WriteLine("DONE");
        return worst;
    }

    private static LinkPeer? FindPeer(LinkEngine engine, string? peerName, string? peerId)
    {
        var peers = engine.Peers;
        if (!string.IsNullOrEmpty(peerId))
        {
            return peers.FirstOrDefault(item => string.Equals(item.Id, peerId, StringComparison.Ordinal));
        }

        if (string.IsNullOrEmpty(peerName))
        {
            return null;
        }

        return peers.FirstOrDefault(item => string.Equals(item.Name, peerName, StringComparison.Ordinal))
            ?? peers.FirstOrDefault(item => string.Equals(item.Name, peerName, StringComparison.OrdinalIgnoreCase))
            ?? peers.FirstOrDefault(item => item.Name.Contains(peerName, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>打印 RESULT 行；返回 0 / 1 / 3（3 = 需要配对）。</summary>
    private static int Report(string action, SendOutcome outcome, Action<string> writeLine)
    {
        switch (outcome.Status)
        {
            case SendStatus.Ok:
                writeLine($"RESULT ok action={action} message=\"{OneLine(outcome.Message)}\"");
                return 0;
            case SendStatus.NeedsPairing:
                writeLine($"RESULT needs-pairing action={action} peer=\"{OneLine(outcome.PeerName)}\"");
                return 3;
            default:
                writeLine($"RESULT failure action={action} message=\"{OneLine(outcome.Message)}\"");
                return 1;
        }
    }

    private static string OneLine(string? value) =>
        (value ?? string.Empty)
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal);
}
