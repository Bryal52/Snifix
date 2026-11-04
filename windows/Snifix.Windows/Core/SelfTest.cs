using System.Net;
using System.Text;

namespace Snifix.Core;

/// `Snifix --selftest`: real requests through the proxy with rules, like the Mac self-test.
public static class SelfTest
{
    public static async Task<int> Run()
    {
        var dir = Path.Combine(Path.GetTempPath(), "snifix-selftest-" + Environment.ProcessId);
        var rules = new RulesDocument { SslBypass = new() };
        var local = new Rule { Name = "Mock profile", Kind = RuleKind.mapLocal, Matcher = new() { Pattern = "https://example.com/mock/*" } };
        local.MapLocal.Body = "{\"name\":\"Snifix\",\"ok\":true}";
        var rewrite = new Rule { Name = "Header", Kind = RuleKind.rewrite, Matcher = new() { Pattern = "*httpbin.org*" } };
        rewrite.Rewrite.Add(new RewriteStep { Target = RewriteTarget.response, Operation = RewriteOperation.setHeader, Key = "X-Snifix", Value = "yes" });
        var script = new Rule { Name = "Script", Kind = RuleKind.script, Matcher = new() { Pattern = "https://httpbin.org/json" },
            Script = "function onResponse(c,u,req,res){ res.body.patched = 42; console.log('patched ' + u); return res; }" };
        var block = new Rule { Name = "Block", Kind = RuleKind.block, BlockMode = BlockMode.notFound, Matcher = new() { Pattern = "*/blocked" } };
        rules.Rules.AddRange(new[] { local, rewrite, script, block });
        var engine = new ProxyEngine(dir, new ProxySettings { Port = 19095 }, rules);
        var flows = new List<Flow>();
        var log = new List<string>();
        engine.FlowUpdated += f => { lock (flows) if (!flows.Contains(f)) flows.Add(f); };
        engine.ScriptLog += l => { lock (log) log.Add(l); };
        engine.Start();

        int failures = 0;
        void Check(string name, bool ok, string detail = "")
        {
            Console.WriteLine(ok ? $"✓ {name}" : $"✗ {name} {detail[..Math.Min(detail.Length, 300)]}");
            if (!ok) failures++;
        }
        async Task<(int, string, List<HeaderItem>)> Get(string method, string url, string? body = null)
        {
            var (s, h, b, e) = await engine.Send(method, url,
                body == null ? new() : new() { new("Content-Type", "application/json") }, body == null ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(body));
            return (s, e ?? Encoding.UTF8.GetString(b), h);
        }

        var (st, text, hs) = await Get("GET", "http://httpbin.org/get");
        Check("HTTP through the proxy", st == 200 && text.Contains("httpbin.org"), text);
        (st, text, hs) = await Get("GET", "https://httpbin.org/get?x=1");
        Check("HTTPS decrypted", st == 200 && text.Contains("\"x\": \"1\""), text);
        Check("Rewrite set a header", hs.Any(h => h.Name.Equals("X-Snifix", StringComparison.OrdinalIgnoreCase) && h.Value == "yes"));
        (st, text, _) = await Get("GET", "https://example.com/mock/profile");
        Check("Map Local", st == 200 && text.Contains("\"name\":\"Snifix\""), text);
        (st, text, _) = await Get("GET", "https://httpbin.org/json");
        Check("Script changed JSON", text.Contains("\"patched\":42"), text);
        (st, text, _) = await Get("GET", "https://example.com/blocked");
        Check("Block 404", st == 404, $"{st}");
        (st, text, _) = await Get("POST", "https://httpbin.org/post", "{\"pin\":\"1234\"}");
        Check("POST with body", text.Contains("\"pin\": \"1234\""), text);
        (st, text, _) = await Get("GET", "https://www.google.com/");
        Check("Compressed response", st == 200 && text.Contains("<html", StringComparison.OrdinalIgnoreCase), text);
        (st, text, _) = await Get("GET", "http://snifix.cert/cert.pem");
        Check("Certificate page", text.Contains("BEGIN CERTIFICATE"), text);
        (st, text, _) = await Get("GET", "http://snifix.cert/proxy.pac");
        Check("PAC file", text.Contains("FindProxyForURL"), text);
        // Map Local from a folder: nothing outside the folder, also not by a full or drive path in the URL
        var mocks = Path.Combine(dir, "mocks");
        Directory.CreateDirectory(Path.Combine(mocks, "users"));
        File.WriteAllText(Path.Combine(mocks, "users", "42.json"), "{\"id\":42}");
        File.WriteAllText(Path.Combine(dir, "secret.txt"), "secret");
        var folder = new Rule { Name = "Folder", Kind = RuleKind.mapLocal, Matcher = new() { Pattern = "https://example.com/api/*" } };
        folder.MapLocal.Source = MapLocalSource.directory;
        folder.MapLocal.Path = mocks;
        rules.Rules.Insert(0, folder);
        (st, text, _) = await Get("GET", "https://example.com/api/users/42");
        Check("Map Local folder serves its files", text.Contains("\"id\":42"), text);
        var secret = Uri.EscapeDataString(Path.Combine(dir, "secret.txt"));
        (st, text, _) = await Get("GET", "https://example.com/api/" + secret);
        Check("Map Local folder refuses full paths", !text.Contains("secret") || text.Contains("not found"), text);
        (st, text, _) = await Get("GET", "https://example.com/api/C:%5CWindows%5Cwin.ini");
        Check("Map Local folder refuses drive paths", st == 404, $"{st}");
        try
        {
            File.CreateSymbolicLink(Path.Combine(mocks, "users", "7.json"), Path.Combine(dir, "secret.txt"));
            Directory.CreateSymbolicLink(Path.Combine(mocks, "outside"), dir);
            (st, text, _) = await Get("GET", "https://example.com/api/users/7");
            Check("Map Local folder refuses links to outside files", text.Trim() != "secret", text);
            (st, text, _) = await Get("GET", "https://example.com/api/outside/secret.txt");
            Check("Map Local folder refuses links to outside folders", text.Trim() != "secret", text);
        }
        catch (UnauthorizedAccessException) { Console.WriteLine("  (symlinks need developer mode on Windows — skipped)"); }
        catch (IOException) { Console.WriteLine("  (symlinks not available here — skipped)"); }
                rules.Rules.Remove(folder);

        Check("Disguised localhost is recognised", ProxyEngine.IsLoopback("2130706433") && ProxyEngine.IsLoopback("::ffff:127.0.0.1") && ProxyEngine.IsLoopback("0x7f000001"));
                Check("Local network addresses", ProxyEngine.IsPrivate(IPAddress.Parse("192.168.1.5")) && ProxyEngine.IsPrivate(IPAddress.Parse("10.0.0.2"))
              && !ProxyEngine.IsPrivate(IPAddress.Parse("8.8.8.8")));
        Check("Localhost is off limits for other devices", ProxyEngine.IsLoopback("127.0.0.1") && ProxyEngine.IsLoopback("localhost") && !ProxyEngine.IsLoopback("example.com"));
        Check("Fingerprint", engine.Fingerprint.Split(' ').Length == 32, engine.Fingerprint);

        // A small "zip bomb" is not unpacked past 64 MB
        using (var packed = new MemoryStream())
        {
            using (var gz = new System.IO.Compression.GZipStream(packed, System.IO.Compression.CompressionLevel.Fastest, true))
            {
                var zeros = new byte[1 << 20];
                for (int i = 0; i < 300; i++) gz.Write(zeros);
            }
            var bomb = packed.ToArray();
            var unpacked = Body.Decoded(bomb, "gzip");
            Check("Decompression bomb is not unpacked", unpacked.Length <= bomb.Length, $"{bomb.Length} → {unpacked.Length}");
        }

        // Bodies of all sessions share one budget: past it a request is answered with 503
        var big = new string('x', 2 * 1024 * 1024);
        TransferBudget.Limit = 1024 * 1024;
        (st, text, _) = await Get("POST", "https://httpbin.org/post", big);
        Check("Body budget refuses with 503", st == 503 && text.Contains("1 GB"), $"{st} {text}");
        TransferBudget.Limit = 1L << 30;
        (st, text, _) = await Get("POST", "https://example.com/mock/profile", big);
        Check("Same upload passes under the normal budget", st == 200 && text.Contains("Snifix"), $"{st}");

        // Stuck clients free their budget, while a quiet tunnel (WebSocket, push) stays open
        var echo = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        echo.Start();
        var echoPort = ((IPEndPoint)echo.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            while (true)
            {
                System.Net.Sockets.TcpClient c;
                try { c = await echo.AcceptTcpClientAsync(); } catch { return; }
                _ = Task.Run(async () =>
                {
                    using var cs = c; var st = c.GetStream(); var b = new byte[65536]; int n;
                    var first = await st.ReadAsync(b);
                    var text = Encoding.ASCII.GetString(b, 0, first);
                    if (text.StartsWith("GET /big"))
                    {
                        // 4 MB response for the slow-reader test: 30 s + 16 s allowed at 256 KB/s
                        await st.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 4194304\r\nConnection: close\r\n\r\n"));
                        var chunk = new byte[1 << 20];
                        for (int i = 0; i < 4; i++) await st.WriteAsync(chunk);
                        return;
                    }
                    await st.WriteAsync(b.AsMemory(0, first));
                    try { while ((n = await st.ReadAsync(b)) > 0) await st.WriteAsync(b.AsMemory(0, n)); } catch { }
                });
            }
        });
        rules.SslBypass.Add("127.0.0.1");
        async Task<double> StalledBodySeconds()
        {
            using var tcp = new System.Net.Sockets.TcpClient();
            await tcp.ConnectAsync("127.0.0.1", 19095);
            var s = tcp.GetStream();
            await s.WriteAsync(Encoding.ASCII.GetBytes($"POST http://127.0.0.1:{echoPort}/up HTTP/1.1\r\nHost: 127.0.0.1:{echoPort}\r\nContent-Length: 1000\r\n\r\n0123456789"));
            var buf = new byte[4096];
            var started = DateTime.UtcNow;
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            try { while (await s.ReadAsync(buf, cts.Token) > 0) { } } catch { }
            return (DateTime.UtcNow - started).TotalSeconds;
        }
        async Task<double> SlowReaderSeconds()
        {
            using var tcp = new System.Net.Sockets.TcpClient();
            tcp.ReceiveBufferSize = 4096;
            await tcp.ConnectAsync("127.0.0.1", 19095);
            var s = tcp.GetStream();
            await s.WriteAsync(Encoding.ASCII.GetBytes($"GET http://127.0.0.1:{echoPort}/big HTTP/1.1\r\nHost: 127.0.0.1:{echoPort}\r\n\r\n"));
            var started = DateTime.UtcNow;
            // Reads nothing; waits until the budget it holds is given back
            while (DateTime.UtcNow - started < TimeSpan.FromSeconds(70))
            {
                await Task.Delay(1000);
                if (DateTime.UtcNow - started > TimeSpan.FromSeconds(3) && TransferBudget.Held == 0) break;
            }
            return (DateTime.UtcNow - started).TotalSeconds;
        }
        // A TLS echo server, like the far end of a WebSocket or push connection
        var tlsEcho = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        tlsEcho.Start();
        var tlsPort = ((IPEndPoint)tlsEcho.LocalEndpoint).Port;
        // RSA: Windows TLS (SChannel) accepts it from a freshly made certificate
        using var key = System.Security.Cryptography.RSA.Create(2048);
        var req = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=localhost", key, System.Security.Cryptography.HashAlgorithmName.SHA256,
            System.Security.Cryptography.RSASignaturePadding.Pkcs1);
        var selfSigned = req.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddDays(1));
        var serverCert = System.Security.Cryptography.X509Certificates.X509CertificateLoader.LoadPkcs12(selfSigned.Export(System.Security.Cryptography.X509Certificates.X509ContentType.Pfx), null);
        _ = Task.Run(async () =>
        {
            try
            {
                using var c = await tlsEcho.AcceptTcpClientAsync();
                using var tls = new System.Net.Security.SslStream(c.GetStream());
                await tls.AuthenticateAsServerAsync(serverCert);
                Console.WriteLine("  (TLS echo server: handshake done)");
                var b = new byte[4096]; int n;
                while ((n = await tls.ReadAsync(b)) > 0) await tls.WriteAsync(b.AsMemory(0, n));
            }
            catch (Exception ex) { Console.WriteLine($"  (TLS echo server: {ex.GetBaseException().Message})"); }
        });
        var tunnelStage = "connect";
        var tunnelStarted = DateTime.UtcNow;
        async Task<bool> QuietTunnelStaysOpen()
        {
            using var tcp = new System.Net.Sockets.TcpClient();
            await tcp.ConnectAsync("127.0.0.1", 19095);
            var s = tcp.GetStream();
            await s.WriteAsync(Encoding.ASCII.GetBytes($"CONNECT 127.0.0.1:{tlsPort} HTTP/1.1\r\nHost: 127.0.0.1:{tlsPort}\r\n\r\n"));
            var buf = new byte[4096];
            using var first = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var n = await s.ReadAsync(buf, first.Token);
            if (!Encoding.ASCII.GetString(buf, 0, n).Contains(" 200")) return false;
            using var tls = new System.Net.Security.SslStream(s, false, (_, _, _, _) => true);
            tunnelStage = "TLS handshake";
            await tls.AuthenticateAsClientAsync("localhost");
            tunnelStage = "first echo";
            await tls.WriteAsync(Encoding.ASCII.GetBytes("hello"));
            using var second = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            n = await tls.ReadAsync(buf, second.Token);
            tunnelStage = "45 s of silence";
            await Task.Delay(TimeSpan.FromSeconds(45));
            tunnelStage = "echo after the silence";
            await tls.WriteAsync(Encoding.ASCII.GetBytes("still here"));
            using var third = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            n = await tls.ReadAsync(buf, third.Token);
            return Encoding.ASCII.GetString(buf, 0, n) == "still here";
        }
        var stalled = StalledBodySeconds();
        var slow = SlowReaderSeconds();
        var quiet = QuietTunnelStaysOpen();
        bool quietOk;
        try { quietOk = await quiet; }
        catch (Exception ex)
        {
            quietOk = false;
            Console.WriteLine($"  quiet tunnel failed at {tunnelStage}, {(DateTime.UtcNow - tunnelStarted).TotalSeconds:F0} s: {ex.GetBaseException().Message}");
        }
        var stalledAfter = await stalled;
        var slowAfter = await slow;
        Check("Stalled request body is dropped", stalledAfter < 45, $"{stalledAfter:F0} s");
        Check("Client that stops reading frees its budget", slowAfter < 60, $"{slowAfter:F0} s, {TransferBudget.Held} bytes held");
        Check("Quiet tunnel stays open for 45 s", quietOk);
        echo.Stop();
        tlsEcho.Stop();

        await Task.Delay(1000);
        Check("Body budget returns to zero", TransferBudget.Held == 0, $"{TransferBudget.Held} bytes held");

        await Task.Delay(300);
        lock (flows) Check("Flows recorded", flows.Count >= 7, $"{flows.Count}");
        lock (log) Check("Script log", log.Any(l => l.Contains("patched")), string.Join(";", log));
        lock (flows) foreach (var f in flows.OrderBy(f => f.Id))
            Console.WriteLine($"  #{f.Id} {f.Method} {f.Url} → {f.StatusText} [{f.AppName}] {f.Protocol} {f.RuleNames}");
        engine.Dispose();
        try { Directory.Delete(dir, true); } catch { }
        Console.WriteLine(failures == 0 ? "All passed" : $"Failures: {failures}");
        return failures == 0 ? 0 : 1;
    }
}
