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
