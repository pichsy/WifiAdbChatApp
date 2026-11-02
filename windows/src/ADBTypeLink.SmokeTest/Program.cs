using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using ADBTypeLink.Core;

namespace ADBTypeLink.SmokeTest;

/// <summary>
/// 控制台冒烟测试：本机起两个 Core 实例（127.0.0.1 回环），走真实 UDP/TCP socket，
/// 验证发现、配对、文字、文件、重名、持久化与失败提示。
///
/// 用法：
///   dotnet run --project src/ADBTypeLink.SmokeTest              # 进程内双实例
///   dotnet run --project src/ADBTypeLink.SmokeTest -- --cross-process
///   dotnet run --project src/ADBTypeLink.SmokeTest -- --keep    # 保留临时目录
/// 退出码：0 全部通过，1 有失败。
/// </summary>
internal static class Program
{
    private static int _failures;
    private static int _passes;
    private static bool _verbose;
    private static readonly List<string> _failuresText = new();

    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;

        if (args.Contains("--role=server", StringComparer.Ordinal))
        {
            return await RunServerChildAsync(args);
        }

        var crossProcess = args.Contains("--cross-process", StringComparer.Ordinal);
        var keep = args.Contains("--keep", StringComparer.Ordinal);
        _verbose = args.Contains("--verbose", StringComparer.Ordinal);

        var root = Path.Combine(
            Path.GetTempPath(),
            $"adbtypelink-smoke-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}".Substring(0, 40));
        Directory.CreateDirectory(root);
        Console.WriteLine($"== ADBTypeLink SmokeTest ==");
        Console.WriteLine($"临时目录: {root}");
        Console.WriteLine($"模式: {(crossProcess ? "跨进程" : "进程内")}");
        Console.WriteLine();

        try
        {
            if (crossProcess)
            {
                await RunCrossProcessAsync(root);
            }
            else
            {
                await RunInProcessAsync(root);
            }
        }
        catch (Exception ex)
        {
            Fail($"测试运行异常: {ex.Message}");
            if (_verbose)
            {
                Console.WriteLine(ex);
            }
        }
        finally
        {
            await Task.Delay(300);
            if (!keep)
            {
                TryDeleteDirectory(root);
            }
            else
            {
                Console.WriteLine($"保留临时目录: {root}");
            }
        }

        Console.WriteLine();
        Console.WriteLine($"== 结果: {_passes} 通过 / {_failures} 失败 ==");
        foreach (var failure in _failuresText)
        {
            Console.WriteLine($"  - {failure}");
        }

        return _failures == 0 ? 0 : 1;
    }

    // MARK: - 进程内双实例

    private static async Task RunInProcessAsync(string root)
    {
        await using var peerA = NewEngine(root, "a", "冒烟测试 A");
        await using var peerB = NewEngine(root, "b", "冒烟测试 B");

        var pairRequestedByB = false;
        peerB.PairRequested += (_, eventArgs) =>
        {
            if (eventArgs.PeerId == peerA.DeviceId)
            {
                pairRequestedByB = true;
            }
        };

        SubscribeLog(peerA, "A");
        SubscribeLog(peerB, "B");

        await peerA.StartAsync();
        await peerB.StartAsync();

        Check(peerA.ListenPort > 0 && peerA.ListenPort != peerB.ListenPort, $"两个实例分别监听不同 TCP 端口 (A={peerA.ListenPort}, B={peerB.ListenPort})");
        Check(peerA.DeviceId != peerB.DeviceId, "两个实例设备 ID 不同");
        Check(peerA.DeviceId.Length > 10 && peerB.DeviceId.Length > 10, "设备 ID 已生成");

        // 1. 互相发现（UDP 广播 / 本机兜底）
        var discovered = await WaitUntilAsync(
            () => FindPeer(peerA, peerB.DeviceId) is not null && FindPeer(peerB, peerA.DeviceId) is not null,
            TimeSpan.FromSeconds(20));
        Check(discovered, "20 秒内双向发现对方");

        var bSeenByA = FindPeer(peerA, peerB.DeviceId);
        var aSeenByB = FindPeer(peerB, peerA.DeviceId);
        Check(bSeenByA?.Port == peerB.ListenPort, $"A 看到的 B 端口正确 ({bSeenByA?.Port} == {peerB.ListenPort})");
        Check(aSeenByB?.Port == peerA.ListenPort, $"B 看到的 A 端口正确 ({aSeenByB?.Port} == {peerA.ListenPort})");
        Info($"A 看到的 B 地址: {bSeenByA?.Host}:{bSeenByA?.Port}，B 看到的 A 地址: {aSeenByB?.Host}:{aSeenByB?.Port}");
        if (!string.Equals(bSeenByA?.Host, "127.0.0.1", StringComparison.Ordinal))
        {
            Info("发现地址不是 127.0.0.1，说明 UDP 广播路径也在工作");
        }

        if (bSeenByA is null || aSeenByB is null)
        {
            Fail("发现阶段失败，后续用例跳过");
            return;
        }

        // 2. 未配对发送 -> pair_required
        var firstText = "你好，世界 👋 第一行\n第二行 with emoji 🚀";
        var needsPairing = await peerA.SendTextAsync(bSeenByA, firstText);
        Check(needsPairing.Status == SendStatus.NeedsPairing, $"未配对发送返回 NeedsPairing (message={needsPairing.Message ?? "-"})");
        Check(await WaitUntilAsync(() => pairRequestedByB, TimeSpan.FromSeconds(6)), "B 触发「正在请求配对」事件");
        Check(!peerB.Messages.Any(item => item.Text == firstText), "未配对时对端不应收到文字");

        // 3. 带配对码发送 -> hello_ok
        var pairedText = "带配对码发送成功 ✅";
        var pairedResult = await peerA.SendTextAsync(bSeenByA, pairedText, peerB.PairingCode);
        Check(pairedResult.Status == SendStatus.Ok, $"带配对码发送文字成功 (message={pairedResult.Message ?? "-"})");
        Check(await WaitUntilAsync(
                () => peerB.Messages.Any(item => item.Direction == MessageDirection.Incoming && item.Text == pairedText),
                TimeSpan.FromSeconds(6)),
            "B 聊天记录出现收到的文字");
        Check(peerA.Messages.Any(item => item.Direction == MessageDirection.Outgoing && item.Text == pairedText), "A 聊天记录出现发出的文字");
        Check(peerA.IsPaired(peerB.DeviceId) && peerB.IsPaired(peerA.DeviceId), "双方都已记录配对关系");

        // 4. 已配对后不再需要配对码
        var secondText = "已配对后直接发送";
        var secondResult = await peerA.SendTextAsync(bSeenByA, secondText);
        Check(secondResult.Status == SendStatus.Ok, $"已配对后无需配对码即可发送 (message={secondResult.Message ?? "-"})");
        Check(await WaitUntilAsync(
                () => peerB.Messages.Any(item => item.Text == secondText),
                TimeSpan.FromSeconds(6)),
            "B 收到第二条文字");

        // 5. 长文本（超过 256 KiB，验证循环读帧）
        var longText = "长文本开始：" + new string('中', 200_000) + "：长文本结束";
        var longResult = await peerA.SendTextAsync(bSeenByA, longText);
        var longTextOk = longResult.Status == SendStatus.Ok
            && await WaitUntilAsync(
                () => peerB.Messages.Any(item => item.Text != null && item.Text.Length == longText.Length && item.Text == longText),
                TimeSpan.FromSeconds(15));
        Check(longTextOk, $"200000 字长文本完整送达 (UTF-8 {Encoding.UTF8.GetByteCount(longText)} 字节)");

        // 6. 单文件发送
        var filesDir = Path.Combine(root, "files");
        Directory.CreateDirectory(filesDir);
        var filePath = Path.Combine(filesDir, "报告 1.txt");
        var fileBytes = RandomNumberGenerator.GetBytes(1_500_000);
        File.WriteAllBytes(filePath, fileBytes);

        var fileResult = await peerA.SendFilesAsync(bSeenByA, new[] { filePath });
        Check(fileResult.Status == SendStatus.Ok, $"发送文件成功 (message={fileResult.Message ?? "-"})");
        var receivedPath = Path.Combine(peerB.ReceiveDir, "报告 1.txt");
        Check(await WaitUntilAsync(() => File.Exists(receivedPath), TimeSpan.FromSeconds(6)), $"接收目录出现文件: {receivedPath}");
        Check(File.Exists(receivedPath) && Sha256File(receivedPath) == Sha256Bytes(fileBytes), "接收文件内容与发送一致");
        Check(await WaitUntilAsync(
                () => peerB.Messages.Any(item => item.Kind == MessageKind.File && item.FileName == "报告 1.txt"),
                TimeSpan.FromSeconds(6)),
            "B 聊天记录出现文件消息");

        // 7. 同名文件自动加序号
        var secondSend = await peerA.SendFilesAsync(bSeenByA, new[] { filePath });
        var renamedPath = Path.Combine(peerB.ReceiveDir, "报告 1 (2).txt");
        Check(secondSend.Status == SendStatus.Ok && await WaitUntilAsync(() => File.Exists(renamedPath), TimeSpan.FromSeconds(6)),
            $"重名文件自动保存为「报告 1 (2).txt」");

        // 8. 一次发送多个文件
        var file2 = Path.Combine(filesDir, "第二个文件.bin");
        var file3 = Path.Combine(filesDir, "third.dat");
        File.WriteAllBytes(file2, RandomNumberGenerator.GetBytes(300_000));
        File.WriteAllBytes(file3, RandomNumberGenerator.GetBytes(1024));
        var multiResult = await peerA.SendFilesAsync(bSeenByA, new[] { file2, file3 });
        Check(multiResult.Status == SendStatus.Ok, $"一次发送 2 个文件成功 (message={multiResult.Message ?? "-"})");
        Check(await WaitUntilAsync(
                () => File.Exists(Path.Combine(peerB.ReceiveDir, "第二个文件.bin"))
                    && File.Exists(Path.Combine(peerB.ReceiveDir, "third.dat")),
                TimeSpan.FromSeconds(10)),
            "两个文件都出现在接收目录");
        Check(File.Exists(Path.Combine(peerB.ReceiveDir, "第二个文件.bin"))
            && Sha256File(Path.Combine(peerB.ReceiveDir, "第二个文件.bin")) == Sha256Bytes(File.ReadAllBytes(file2)),
            "多文件内容一致");

        // 9. 0 字节文件：发送侧按规格拒绝
        var emptyFile = Path.Combine(filesDir, "空文件.txt");
        File.WriteAllBytes(emptyFile, Array.Empty<byte>());
        var emptyResult = await peerA.SendFilesAsync(bSeenByA, new[] { emptyFile });
        Check(emptyResult.Status == SendStatus.Failure && (emptyResult.Message ?? string.Empty).Contains("读不到文件"),
            $"0 字节文件发送侧拒绝 (message={emptyResult.Message ?? "-"})");

        // 10. 空文字：直接拒绝，不建连接
        var emptyTextResult = await peerA.SendTextAsync(bSeenByA, "   ");
        Check(emptyTextResult.Status == SendStatus.Failure && (emptyTextResult.Message ?? string.Empty).Contains("先输入要发送的文字"),
            $"空文字发送被拒绝 (message={emptyTextResult.Message ?? "-"})");

        // 11. 对方已退出：连接失败要快速返回且不崩溃
        var deadPort = GetFreeTcpPort();
        var deadPeer = new LinkPeer { Id = "dead-device", Name = "已退出的设备", Host = "127.0.0.1", Port = deadPort, LastSeenUtc = DateTime.UtcNow };
        var stopwatch = Stopwatch.StartNew();
        var deadResult = await peerA.SendTextAsync(deadPeer, "发给已退出设备");
        stopwatch.Stop();
        Check(deadResult.Status == SendStatus.Failure, $"发给已退出设备返回失败 (message={deadResult.Message ?? "-"})");
        Check(stopwatch.Elapsed < TimeSpan.FromSeconds(8), $"失败提示在 8 秒内返回（实际 {stopwatch.ElapsedMilliseconds} ms）");
        Check(peerA.Peers.All(item => item.Id != "dead-device"), "连接失败后引擎仍在运行");

        // 12. 持久化
        var pairedJson = Path.Combine(peerB.DataDirectory, "paired.json");
        Check(File.Exists(pairedJson) && File.ReadAllText(pairedJson).Contains(peerA.DeviceId), "paired.json 已持久化对方设备 ID");
        var chatJson = Path.Combine(peerB.DataDirectory, "chat.json");
        Check(File.Exists(chatJson) && File.ReadAllText(chatJson).Contains("报告 1.txt"), "chat.json 已持久化文件消息");
        var deviceJson = Path.Combine(peerB.DataDirectory, "device.json");
        Check(File.Exists(deviceJson) && File.ReadAllText(deviceJson).Contains(peerB.DeviceId), "device.json 已持久化设备 ID");

        // 13. 重启后恢复
        var bDataDir = peerB.DataDirectory;
        var bReceiveDir = peerB.ReceiveDir;
        var bDeviceId = peerB.DeviceId;
        var bMessageCount = peerB.Messages.Count;
        await peerB.StopAsync();

        await using (var reborn = new LinkEngine(new LinkEngineOptions
                     {
                         DataDirectory = bDataDir,
                         ReceiveDirectory = bReceiveDir,
                         DeviceName = "冒烟测试 B（重启）",
                     }))
        {
            Check(reborn.DeviceId == bDeviceId, "重启后设备 ID 不变");
            Check(reborn.IsPaired(peerA.DeviceId), "重启后配对关系恢复");
            Check(reborn.Messages.Count == bMessageCount && bMessageCount > 5, $"重启后聊天记录恢复（{reborn.Messages.Count} 条）");
            Check(reborn.ReceiveDir == bReceiveDir, "重启后接收目录恢复");
        }

        Check(peerA.IsRunning, "A 引擎仍在运行");
    }

    // MARK: - 跨进程（父进程做客户端，子进程做服务端）

    private static async Task RunCrossProcessAsync(string root)
    {
        var childDataDir = Path.Combine(root, "child", "data");
        var childReceiveDir = Path.Combine(root, "child", "recv");
        var filesDir = Path.Combine(root, "files");
        Directory.CreateDirectory(childDataDir);
        Directory.CreateDirectory(childReceiveDir);
        Directory.CreateDirectory(filesDir);

        var startInfo = new ProcessStartInfo
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        var processPath = Environment.ProcessPath ?? "dotnet";
        var entryAssembly = typeof(Program).Assembly.Location;
        var isDotnetHost = string.Equals(Path.GetFileNameWithoutExtension(processPath), "dotnet", StringComparison.OrdinalIgnoreCase);
        if (isDotnetHost)
        {
            startInfo.FileName = processPath;
            startInfo.ArgumentList.Add(entryAssembly);
        }
        else
        {
            startInfo.FileName = processPath;
        }

        startInfo.ArgumentList.Add("--role=server");
        startInfo.ArgumentList.Add($"--data-dir={childDataDir}");
        startInfo.ArgumentList.Add($"--receive-dir={childReceiveDir}");

        using var child = new Process { StartInfo = startInfo };
        if (!child.Start())
        {
            Fail("无法启动子进程");
            return;
        }

        var pairCode = string.Empty;
        var childDeviceId = string.Empty;
        var childPort = 0;
        var childReceivedText = false;
        var childReceivedFile = false;
        var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await child.StandardOutput.ReadLineAsync()) is not null)
                {
                    Console.WriteLine($"  [子进程] {line}");
                    if (line.StartsWith("READY ", StringComparison.Ordinal))
                    {
                        var parts = line.Split(' ');
                        if (parts.Length >= 4)
                        {
                            childDeviceId = parts[1];
                            pairCode = parts[2];
                            childPort = int.Parse(parts[3]);
                            ready.TrySetResult(true);
                        }
                    }
                    else if (line.StartsWith("RECEIVED ", StringComparison.Ordinal))
                    {
                        if (line.Contains("TEXT", StringComparison.Ordinal))
                        {
                            Volatile.Write(ref childReceivedText, true);
                        }

                        if (line.Contains("FILE", StringComparison.Ordinal))
                        {
                            Volatile.Write(ref childReceivedFile, true);
                        }
                    }
                }
            }
            catch (Exception)
            {
                // 子进程退出。
            }
        });
        _ = Task.Run(async () =>
        {
            try
            {
                string? errorLine;
                while ((errorLine = await child.StandardError.ReadLineAsync()) is not null)
                {
                    Console.WriteLine($"  [子进程 stderr] {errorLine}");
                }
            }
            catch (Exception)
            {
                // 子进程退出。
            }
        });

        try
        {
            var readyTask = await Task.WhenAny(ready.Task, Task.Delay(TimeSpan.FromSeconds(30)));
            if (readyTask != ready.Task || !ready.Task.IsCompletedSuccessfully)
            {
                Fail("子进程 30 秒内没有就绪");
                return;
            }

            Check(childPort > 0, $"子进程 TCP 端口已就绪（{childPort}）");
            Check(pairCode.Length == 6, $"子进程配对码为 6 位（{pairCode}）");

            await using var parent = new LinkEngine(new LinkEngineOptions
            {
                DataDirectory = Path.Combine(root, "parent", "data"),
                ReceiveDirectory = Path.Combine(root, "parent", "recv"),
                DeviceName = "冒烟测试 父进程",
            });
            await parent.StartAsync();

            var childPeer = await WaitUntilAsync(
                () => FindPeer(parent, childDeviceId) is not null,
                TimeSpan.FromSeconds(20))
                ? FindPeer(parent, childDeviceId)
                : null;
            Check(childPeer is not null, $"父进程发现子进程（{childPeer?.Host}:{childPeer?.Port}）");
            if (childPeer is null)
            {
                return;
            }

            Check(childPeer.Port == childPort, $"发现的端口与子进程一致（{childPeer.Port} == {childPort}）");

            var text = "跨进程冒烟测试：你好跨进程 👋";
            var textResult = await parent.SendTextAsync(childPeer, text, pairCode);
            Check(textResult.Status == SendStatus.Ok, $"跨进程发送文字成功 (message={textResult.Message ?? "-"})");

            var filePath = Path.Combine(filesDir, "跨进程文件.txt");
            var fileBytes = RandomNumberGenerator.GetBytes(700_000);
            File.WriteAllBytes(filePath, fileBytes);
            var fileResult = await parent.SendFilesAsync(childPeer, new[] { filePath });
            Check(fileResult.Status == SendStatus.Ok, $"跨进程发送文件成功 (message={fileResult.Message ?? "-"})");

            var childReceivePath = Path.Combine(childReceiveDir, "跨进程文件.txt");
            Check(await WaitUntilAsync(() => File.Exists(childReceivePath), TimeSpan.FromSeconds(10)), "子进程接收目录出现文件");
            Check(File.Exists(childReceivePath) && Sha256File(childReceivePath) == Sha256Bytes(fileBytes), "跨进程文件内容一致");

            var childDone = await WaitUntilAsync(
                () => Volatile.Read(ref childReceivedText) && Volatile.Read(ref childReceivedFile),
                TimeSpan.FromSeconds(10));
            Check(childDone, "子进程自报收到文字与文件");
        }
        finally
        {
            try
            {
                if (!child.HasExited)
                {
                    child.Kill(entireProcessTree: true);
                    child.WaitForExit(5000);
                }
            }
            catch (Exception)
            {
                // 忽略清理异常。
            }
        }
    }

    private static async Task<int> RunServerChildAsync(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        var dataDir = GetOption(args, "--data-dir=") ?? Path.Combine(Path.GetTempPath(), "adbtypelink-child", Guid.NewGuid().ToString("N"), "data");
        var receiveDir = GetOption(args, "--receive-dir=") ?? Path.Combine(Path.GetTempPath(), "adbtypelink-child", Guid.NewGuid().ToString("N"), "recv");

        var receivedText = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var receivedFile = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        await using var engine = new LinkEngine(new LinkEngineOptions
        {
            DataDirectory = dataDir,
            ReceiveDirectory = receiveDir,
            DeviceName = "冒烟测试 子进程",
        });
        engine.MessageAdded += (_, message) =>
        {
            if (message.Direction != MessageDirection.Incoming)
            {
                return;
            }

            if (message.Kind == MessageKind.Text)
            {
                Console.WriteLine($"RECEIVED TEXT {message.Text?.Length}");
                receivedText.TrySetResult(true);
            }
            else
            {
                Console.WriteLine($"RECEIVED FILE {message.FileName} {message.FileSize}");
                receivedFile.TrySetResult(true);
            }
        };
        engine.StatusChanged += (_, status) =>
        {
            if (_verbose)
            {
                Console.WriteLine($"STATUS {status.Text}");
            }
        };

        await engine.StartAsync();
        Console.WriteLine($"READY {engine.DeviceId} {engine.PairingCode} {engine.ListenPort}");

        var finished = Task.WhenAll(receivedText.Task, receivedFile.Task);
        var timeout = Task.Delay(TimeSpan.FromSeconds(90));
        var completed = await Task.WhenAny(finished, timeout);
        if (completed == timeout)
        {
            Console.WriteLine("TIMEOUT waiting for text+file");
            return 1;
        }

        Console.WriteLine("CHILD DONE");
        return 0;
    }

    // MARK: - 工具

    private static LinkEngine NewEngine(string root, string tag, string name)
    {
        var dataDir = Path.Combine(root, tag, "data");
        var receiveDir = Path.Combine(root, tag, "recv");
        Directory.CreateDirectory(dataDir);
        Directory.CreateDirectory(receiveDir);
        return new LinkEngine(new LinkEngineOptions
        {
            DataDirectory = dataDir,
            ReceiveDirectory = receiveDir,
            DeviceName = name,
        });
    }

    private static void SubscribeLog(LinkEngine engine, string tag)
    {
        engine.StatusChanged += (_, status) =>
        {
            if (_verbose)
            {
                Console.WriteLine($"  [{tag}] {status.Kind}: {status.Text}");
            }
        };
    }

    private static LinkPeer? FindPeer(LinkEngine engine, string peerId) =>
        engine.Peers.FirstOrDefault(item => string.Equals(item.Id, peerId, StringComparison.Ordinal));

    private static async Task<bool> WaitUntilAsync(Func<bool> predicate, TimeSpan timeout)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < timeout)
        {
            try
            {
                if (predicate())
                {
                    return true;
                }
            }
            catch (Exception)
            {
                // 忽略读取过程中的瞬时异常。
            }

            await Task.Delay(100);
        }

        try
        {
            return predicate();
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static int GetFreeTcpPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static string Sha256File(string path) => Sha256Bytes(File.ReadAllBytes(path));

    private static string Sha256Bytes(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void Check(bool condition, string label)
    {
        if (condition)
        {
            _passes++;
            Console.WriteLine($"  [PASS] {label}");
        }
        else
        {
            Fail(label);
        }
    }

    private static void Fail(string label)
    {
        _failures++;
        _failuresText.Add(label);
        Console.WriteLine($"  [FAIL] {label}");
    }

    private static void Info(string text) => Console.WriteLine($"  [INFO] {text}");

    private static string? GetOption(string[] args, string prefix) =>
        args.FirstOrDefault(item => item.StartsWith(prefix, StringComparison.Ordinal))?[prefix.Length..];

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (Exception)
        {
            // 清理失败不影响结果。
        }
    }
}
