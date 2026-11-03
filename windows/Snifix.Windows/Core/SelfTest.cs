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
