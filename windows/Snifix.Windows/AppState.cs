using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Avalonia.Threading;
using Snifix.Core;

namespace Snifix;

/// A row in the sidebar tree: All, device → Apps/Domains → app → domain.
public sealed class SidebarNode : INotifyPropertyChanged
{
    public string Title { get; init; } = "";
    public string Detail { get; init; } = "";
    public int Count { get; set; }
    public string Glyph { get; init; } = "";
    public bool IsHeader { get; init; }
    public string? Device { get; init; }
    public string? App { get; init; }
    public string? Host { get; init; }
    public string Key { get; init; } = "";
    public ObservableCollection<SidebarNode> Children { get; } = new();
    bool expanded;
    public bool IsExpanded { get => expanded; set { expanded = value; AppState.Shared.SetExpanded(Key, value); Changed(); } }
    public void SetExpandedSilently(bool v) { expanded = v; Changed(nameof(IsExpanded)); }

    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}

public sealed class AppState : INotifyPropertyChanged
{
    public static AppState Shared { get; } = new();

    public string DataDirectory { get; }
    public ProxyEngine Engine { get; }
    public ProxySettings Settings { get; }
    public RulesDocument Rules { get; private set; }

    public ObservableCollection<Flow> Visible { get; } = new();
    public ObservableCollection<SidebarNode> Sidebar { get; } = new();
    public ObservableCollection<string> ScriptLog { get; } = new();
    readonly List<Flow> all = new();
    readonly ConcurrentQueue<Flow> added = new();
    readonly ConcurrentDictionary<int, Flow> updated = new();
    readonly HashSet<string> expanded = new() { "dev:This PC", "apps:This PC" };
    string sidebarSignature = "";

    public string Search { get => search; set { search = value; Refilter(); } }
    string search = "";
    public string Category { get => category; set { category = value; Refilter(); Changed(); } }
    string category = "All";
    public string StatusFilter { get => statusFilter; set { statusFilter = value; Refilter(); } }
    string statusFilter = "Any Status";
    public SidebarNode? SidebarSelection { get => sidebarSelection; set { sidebarSelection = value; Refilter(); } }
    SidebarNode? sidebarSelection;

    public bool Recording { get => Engine.Recording; set { Engine.Recording = value; Changed(); } }
    public bool SystemProxy => Engine.SystemProxyEnabled;
    public bool CertificateTrusted { get; private set; }
    public string LocalAddress { get; private set; } = ProxyEngine.PrimaryAddress();
    public string? ProxyError { get; private set; }
    public int Total => all.Count;
    public string CountText => $"{Visible.Count} of {all.Count}";
    public string PacUrl => $"http://{LocalAddress}:{Settings.Port}/proxy.pac";
    public string CertificatePageUrl => $"http://{LocalAddress}:{Settings.Port}/";
    public event Action<string>? Toast;

    AppState()
    {
        DataDirectory = Environment.GetEnvironmentVariable("SNIFIX_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Snifix");
        Directory.CreateDirectory(DataDirectory);
        Settings = Load<ProxySettings>("settings.json") ?? new ProxySettings();
        Rules = Load<RulesDocument>("rules.json") ?? new RulesDocument();
        Engine = new ProxyEngine(DataDirectory, Settings, Rules);
        Engine.FlowStarted += f => added.Enqueue(f);
        Engine.FlowUpdated += f => updated[f.Id] = f;
        Engine.ScriptLog += line => Dispatcher.UIThread.Post(() =>
        {
            ScriptLog.Add(line);
            while (ScriptLog.Count > 300) ScriptLog.RemoveAt(0);
        });
    }

    public void Start()
    {
        Engine.RecoverSystemProxy();
        try
        {
            Engine.Start();
            ProxyError = null;
        }
        catch (Exception ex)
        {
            ProxyError = $"Port {Settings.Port} is in use or blocked: {ex.GetBaseException().Message}. Quit the other proxy or change the port.";
        }
        CertificateTrusted = Engine.IsCertificateTrusted();
        // Without a trusted certificate every HTTPS site on the PC would break, so wait for it
        if (ProxyError == null && Settings.CaptureOnLaunch && CertificateTrusted) SetSystemProxy(true);
        new DispatcherTimer(TimeSpan.FromMilliseconds(150), DispatcherPriority.Background, (_, _) => Drain()).Start();
        new DispatcherTimer(TimeSpan.FromSeconds(5), DispatcherPriority.Background, (_, _) =>
        {
            var a = ProxyEngine.PrimaryAddress();
            if (a != LocalAddress) { LocalAddress = a; Changed(nameof(LocalAddress)); Changed(nameof(PacUrl)); Changed(nameof(CertificatePageUrl)); }
        }).Start();
        Changed(string.Empty);
    }

    public void Shutdown()
    {
        SaveRules();
        Save(Settings, "settings.json");
        Engine.Dispose();
    }

    public void SetSystemProxy(bool on)
    {
        try { Engine.SetSystemProxy(on); }
        catch (Exception ex) { Toast?.Invoke("Could not change the Windows proxy: " + ex.Message); }
        Changed(nameof(SystemProxy));
    }

    public void TrustCertificate()
    {
        var error = Engine.TrustCertificate();
        CertificateTrusted = Engine.IsCertificateTrusted();
        Changed(nameof(CertificateTrusted));
        Toast?.Invoke(error ?? "Certificate installed and trusted");
        if (CertificateTrusted && !SystemProxy && Settings.CaptureOnLaunch) SetSystemProxy(true);
    }

    // MARK: - Flows

    void Drain()
    {
        var changed = false;
        while (added.TryDequeue(out var f))
        {
            all.Add(f);
            if (Passes(f)) Visible.Insert(0, f);
            changed = true;
        }
        foreach (var id in updated.Keys.ToList())
        {
            if (!updated.TryRemove(id, out var f)) continue;
            f.Refresh();
            changed = true;
        }
        if (all.Count > Settings.MaxFlows)
        {
            var drop = all.Take(all.Count - Settings.MaxFlows).ToList();
            all.RemoveRange(0, drop.Count);
            foreach (var f in drop) Visible.Remove(f);
        }
        if (!changed) return;
        RebuildSidebar();
        Changed(nameof(CountText));
        Changed(nameof(Total));
    }

    bool Passes(Flow f)
    {
        if (sidebarSelection is SidebarNode n)
        {
            if (n.Device != null && f.DeviceKey != n.Device) return false;
            if (n.App != null && f.AppName != n.App) return false;
            if (n.Host != null && f.Host != n.Host) return false;
        }
        if (!Categories.Matches(f, category)) return false;
        var ok = statusFilter switch
        {
            "2xx" => f.StatusCode is >= 200 and < 300, "3xx" => f.StatusCode is >= 300 and < 400,
            "4xx" => f.StatusCode is >= 400 and < 500, "5xx" => f.StatusCode >= 500, _ => true,
        };
        if (!ok) return false;
        if (string.IsNullOrWhiteSpace(search)) return true;
        var hay = $"{f.Method} {f.Url} {f.StatusCode} {f.AppName}".ToLowerInvariant();
        return search.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries).All(hay.Contains);
    }

    public void Refilter()
    {
        Visible.Clear();
        foreach (var f in Enumerable.Reverse(all)) if (Passes(f)) Visible.Add(f);
        Changed(nameof(CountText));
    }

    public void Clear()
    {
        all.Clear();
        Visible.Clear();
        RebuildSidebar();
        Changed(nameof(CountText));
    }

    public void Remove(IEnumerable<Flow> flows)
    {
        foreach (var f in flows.ToList()) { all.Remove(f); Visible.Remove(f); }
        RebuildSidebar();
        Changed(nameof(CountText));
    }

    public void SetExpanded(string key, bool on) { if (on) expanded.Add(key); else expanded.Remove(key); }

    void RebuildSidebar()
    {
        var devices = all.GroupBy(f => f.DeviceKey).OrderBy(g => g.Key == "This PC" ? 0 : 1).ThenBy(g => g.Key).ToList();
        var signature = string.Join("|", devices.Select(d => d.Key + ":" + d.Count() + ":" +
            string.Join(",", d.GroupBy(f => f.AppName).Select(a => a.Key + a.Count() + ":" + string.Join(".", a.Select(f => f.Host).Distinct())))));
        if (signature == sidebarSignature) return;
        sidebarSignature = signature;

        var selectedKey = sidebarSelection?.Key;
        Sidebar.Clear();
        Sidebar.Add(new SidebarNode { Title = "All Requests", Glyph = "▤", Count = all.Count, Key = "all", IsHeader = true });
        foreach (var d in devices)
        {
            var name = d.Key == "This PC" ? "This PC"
                : d.GroupBy(f => f.DeviceName).Where(g => g.Key != "Device").OrderByDescending(g => g.Count()).FirstOrDefault()?.Key ?? "Device";
            var device = new SidebarNode
            {
                Title = name, Detail = d.Key == "This PC" ? "" : d.Key, Count = d.Count(), Device = d.Key, Key = "dev:" + d.Key,
                Glyph = d.Key == "This PC" ? "💻" : name.Contains("Android") ? "🤖" : "📱",
            };
            var apps = new SidebarNode { Title = "Apps", Glyph = "▦", Count = d.Select(f => f.AppName).Distinct().Count(), Key = "apps:" + d.Key, IsHeader = true };
            foreach (var a in d.GroupBy(f => f.AppName).OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase))
            {
                var app = new SidebarNode { Title = a.Key, Glyph = "◆", Count = a.Count(), Device = d.Key, App = a.Key, Key = $"app:{d.Key}/{a.Key}" };
                foreach (var h in a.GroupBy(f => f.Host).OrderBy(g => string.Join(".", g.Key.Split('.').Reverse())))
                    app.Children.Add(new SidebarNode { Title = h.Key, Glyph = "🌐", Count = h.Count(), Device = d.Key, App = a.Key, Host = h.Key, Key = $"host:{d.Key}/{a.Key}/{h.Key}" });
                apps.Children.Add(app);
            }
            var hosts = new SidebarNode { Title = "Domains", Glyph = "🌐", Count = d.Select(f => f.Host).Distinct().Count(), Key = "hosts:" + d.Key, IsHeader = true };
            foreach (var h in d.GroupBy(f => f.Host).OrderBy(g => string.Join(".", g.Key.Split('.').Reverse())))
                hosts.Children.Add(new SidebarNode { Title = h.Key, Glyph = "🌐", Count = h.Count(), Device = d.Key, Host = h.Key, Key = $"dhost:{d.Key}/{h.Key}" });
            device.Children.Add(apps);
            device.Children.Add(hosts);
            Sidebar.Add(device);
        }
        foreach (var n in Walk(Sidebar)) n.SetExpandedSilently(expanded.Contains(n.Key));
        if (selectedKey != null) sidebarSelection = Walk(Sidebar).FirstOrDefault(n => n.Key == selectedKey);
        SidebarRebuilt?.Invoke();
    }

    public event Action? SidebarRebuilt;

    public static IEnumerable<SidebarNode> Walk(IEnumerable<SidebarNode> nodes)
    {
        foreach (var n in nodes)
        {
            yield return n;
            foreach (var c in Walk(n.Children)) yield return c;
        }
    }

    // MARK: - Rules

    public Rule MakeRule(RuleKind kind, Flow f)
    {
        var u = new Uri(f.Url);
        var baseUrl = u.GetLeftPart(UriPartial.Path);
        var rule = new Rule
        {
            Name = $"{f.Method} {f.Host}{u.AbsolutePath}", Kind = kind,
            Matcher = new RuleMatcher { Pattern = kind is RuleKind.mapRemote or RuleKind.block ? u.GetLeftPart(UriPartial.Authority) + "/*" : baseUrl, IncludeSubpaths = false },
        };
        if (kind == RuleKind.mapLocal && f.State == FlowState.Completed)
        {
            rule.MapLocal.StatusCode = f.StatusCode;
            rule.MapLocal.Headers = f.ResponseHeaders.Where(h => !new[] { "content-length", "content-encoding", "transfer-encoding", "connection", "date" }
                .Contains(h.Name.ToLowerInvariant())).Select(h => new HeaderItem(h.Name, h.Value)).ToList();
            rule.MapLocal.Body = Body.PrettyJson(Body.Text(f.ResponseBody, f.ResponseHeader("Content-Encoding")));
        }
        if (kind == RuleKind.mapRemote) rule.MapRemote.Host = f.Host;
        if (kind == RuleKind.rewrite) rule.Rewrite.Add(new RewriteStep());
        return rule;
    }

    public void AddRule(Rule rule) { Rules.Rules.Add(rule); SaveRules(); }

    public void SaveRules()
    {
        Engine.Rules = Rules;
        Save(Rules, "rules.json");
    }

    public void ReplaceRules(RulesDocument doc) { Rules = doc; SaveRules(); }

    public void SaveSettings() { Engine.Settings = Settings; Save(Settings, "settings.json"); }

    T? Load<T>(string name) where T : class
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(DataDirectory, name)), Json.Options); }
        catch { return null; }
    }

    void Save<T>(T value, string name)
    {
        try { File.WriteAllText(Path.Combine(DataDirectory, name), JsonSerializer.Serialize(value, Json.Options)); } catch { }
    }

    public void ShowToast(string text) => Toast?.Invoke(text);

    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}
