using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Snifix.Core;

namespace Snifix;

/// Small helpers for building the code-only windows.
static class Ui
{
    public static TextBlock Label(string text) => new() { Text = text.ToUpperInvariant(), Classes = { "label" }, Margin = new Thickness(0, 8, 0, 2) };
    public static TextBlock Text(string text, double size = 12.5, string? color = null)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        if (color != null) t.Foreground = new SolidColorBrush(Color.Parse(color));
        return t;
    }
    public static TextBox Field(string value, Action<string> changed, string watermark = "", bool mono = true)
    {
        var t = new TextBox { Text = value, Watermark = watermark };
        if (mono) t.FontFamily = (FontFamily)Application.Current!.FindResource("Mono")!;
        t.TextChanged += (_, _) => changed(t.Text ?? "");
        return t;
    }
    public static TextBox Code(string value, Action<string> changed, double minHeight = 220)
    {
        var t = new TextBox { Text = value, Classes = { "code" }, MinHeight = minHeight, TextWrapping = TextWrapping.NoWrap };
        t.TextChanged += (_, _) => changed(t.Text ?? "");
        return t;
    }
    public static CheckBox Check(string title, bool value, Action<bool> changed)
    {
        var c = new CheckBox { Content = title, IsChecked = value };
        c.IsCheckedChanged += (_, _) => changed(c.IsChecked == true);
        return c;
    }
    public static Button Button(string title, Action click, bool gold = false)
    {
        var b = new Button { Content = title, Classes = { "tool" } };
        if (gold) b.Classes.Add("gold");
        b.Click += (_, _) => click();
        return b;
    }
    public static ComboBox Combo<T>(IEnumerable<(string title, T value)> items, T selected, Action<T> changed)
    {
        var list = items.ToList();
        var c = new ComboBox { ItemsSource = list.Select(i => i.title).ToList(), SelectedIndex = Math.Max(0, list.FindIndex(i => Equals(i.value, selected))) };
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) changed(list[c.SelectedIndex].value); };
        return c;
    }
    public static Border Card(Control content) => new() { Classes = { "card" }, Child = content, Margin = new Thickness(0, 0, 0, 12) };
    public static StackPanel Row(params Control[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }
    public static StackPanel Column(double spacing = 6) => new() { Spacing = spacing };
    public static string HeadersToText(List<HeaderItem> headers) => string.Join("\n", headers.Select(h => $"{h.Name}: {h.Value}"));
    public static List<HeaderItem> TextToHeaders(string text) => text.Split('\n')
        .Select(l => l.Trim()).Where(l => l.Contains(':'))
        .Select(l => { var i = l.IndexOf(':'); return new HeaderItem(l[..i].Trim(), l[(i + 1)..].Trim()); }).ToList();
}

enum Tool { MapLocal, MapRemote, Rewrite, Scripting, BlockList, NetworkConditions, SslBypass }

public sealed class RulesWindow : Window
{
    static RulesWindow? current;
    readonly AppState state = AppState.Shared;
    Tool tool = Tool.MapLocal;
    Guid? selected;
    readonly ListBox tools = new();
    readonly ListBox ruleList = new();
    readonly ContentControl editor = new();
    readonly TextBlock header = new() { FontSize = 16, FontWeight = FontWeight.SemiBold };

    public static void Open(Window owner, RuleKind kind, Guid? rule)
    {
        current ??= new RulesWindow();
        current.tool = kind switch
        {
            RuleKind.mapRemote => Tool.MapRemote, RuleKind.rewrite => Tool.Rewrite, RuleKind.script => Tool.Scripting,
            RuleKind.block => Tool.BlockList, RuleKind.throttle => Tool.NetworkConditions, _ => Tool.MapLocal,
        };
        current.selected = rule;
        current.Reload();
        if (!current.IsVisible) current.Show(owner);
        current.Activate();
    }

    RulesWindow()
    {
        Title = "Rules";
        Width = 1120; Height = 720; MinWidth = 900; MinHeight = 560;
        Closed += (_, _) => current = null;

        tools.ItemsSource = Enum.GetValues<Tool>().Select(ToolTitle).ToList();
        tools.SelectionChanged += (_, _) =>
        {
            if (tools.SelectedIndex < 0) return;
            var t = (Tool)tools.SelectedIndex;
            if (t != tool) { tool = t; selected = null; Reload(); }
        };
        ruleList.SelectionChanged += (_, _) =>
        {
            if (ruleList.SelectedItem is ListBoxItem { Tag: Guid id }) { selected = id; ShowEditor(); }
        };

        var add = Ui.Button("+ New Rule", AddRule, gold: true);
        var more = new Button { Content = "···", Classes = { "tool" } };
        var menu = new ContextMenu();
        foreach (var (title, action) in new (string, Action)[] { ("Duplicate", Duplicate), ("Delete", Delete), ("Import…", () => _ = Import()), ("Export…", () => _ = Export()) })
        {
            var m = new MenuItem { Header = title };
            m.Click += (_, _) => action();
            menu.Items.Add(m);
        }
        more.Click += (_, _) => menu.Open(more);
        var top = new DockPanel { Margin = new Thickness(12, 10) };
        DockPanel.SetDock(header, Dock.Left);
        top.Children.Add(header);
        var buttons = Ui.Row(add, more);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        top.Children.Add(buttons);

        var middle = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        middle.Children.Add(top);
        middle.Children.Add(ruleList);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("200,1,380,1,*") };
        var side = new Border { Background = new SolidColorBrush(Color.Parse("#121017")), Child = tools, Padding = new Thickness(6) };
        grid.Children.Add(side);
        grid.Children.Add(new Border { Background = new SolidColorBrush(Color.Parse("#2A2633")), [Grid.ColumnProperty] = 1 });
        middle[Grid.ColumnProperty] = 2;
        grid.Children.Add(middle);
        grid.Children.Add(new Border { Background = new SolidColorBrush(Color.Parse("#2A2633")), [Grid.ColumnProperty] = 3 });
        var scroll = new ScrollViewer { Content = editor, Padding = new Thickness(16), [Grid.ColumnProperty] = 4 };
        grid.Children.Add(scroll);
        Content = grid;
    }

    static string ToolTitle(Tool t) => t switch
    {
        Tool.MapLocal => "Map Local", Tool.MapRemote => "Map Remote", Tool.Rewrite => "Rewrite", Tool.Scripting => "Scripting",
        Tool.BlockList => "Block List", Tool.NetworkConditions => "Network Conditions", _ => "SSL Bypass",
    };

    static RuleKind? KindOf(Tool t) => t switch
    {
        Tool.MapLocal => RuleKind.mapLocal, Tool.MapRemote => RuleKind.mapRemote, Tool.Rewrite => RuleKind.rewrite,
        Tool.Scripting => RuleKind.script, Tool.BlockList => RuleKind.block, Tool.NetworkConditions => RuleKind.throttle, _ => null,
    };

    static string Help(Tool t) => t switch
    {
        Tool.MapLocal => "The response comes from text, a file or a folder on this PC — the server is not called.",
        Tool.MapRemote => "The request goes to another host, port or path (e.g. prod → staging).",
        Tool.Rewrite => "Changes headers, query, body and status code on the fly.",
        Tool.Scripting => "JavaScript onRequest / onResponse functions for any logic.",
        Tool.BlockList => "Returns 403/404 or drops the connection.",
        Tool.NetworkConditions => "Adds latency and limits the response speed.",
        _ => "These hosts are not decrypted — traffic is tunneled as is.",
    };

    void Reload()
    {
        tools.SelectedIndex = (int)tool;
        header.Text = ToolTitle(tool);
        var kind = KindOf(tool);
        var items = new List<ListBoxItem>();
        if (kind is RuleKind k)
        {
            foreach (var group in state.Rules.Groups.Where(g => state.Rules.Rules.Any(r => r.Kind == k && r.GroupId == g.Id)))
            {
                var g = group;
                var check = Ui.Check(g.Name, g.Enabled, v => { g.Enabled = v; state.SaveRules(); });
                check.Foreground = (IBrush)Application.Current!.FindResource("Gold")!;
                check.FontWeight = FontWeight.SemiBold;
                items.Add(new ListBoxItem { Content = check, IsEnabled = true, Focusable = false });
                items.AddRange(state.Rules.Rules.Where(r => r.Kind == k && r.GroupId == g.Id).Select(RuleItem));
            }
            items.AddRange(state.Rules.Rules.Where(r => r.Kind == k && (r.GroupId == null || state.Rules.Groups.All(g => g.Id != r.GroupId))).Select(RuleItem));
        }
        ruleList.ItemsSource = items;
        ruleList.SelectedItem = items.FirstOrDefault(i => i.Tag is Guid id && id == selected);
        ShowEditor();
    }

    ListBoxItem RuleItem(Rule r)
    {
        var check = new CheckBox { IsChecked = r.Enabled, VerticalAlignment = VerticalAlignment.Center };
        check.IsCheckedChanged += (_, _) => { r.Enabled = check.IsChecked == true; state.SaveRules(); };
        var text = Ui.Column(1);
        text.Children.Add(new TextBlock { Text = r.Name, FontWeight = FontWeight.Medium, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Text = r.Matcher.Pattern, FontSize = 10.5, Foreground = new SolidColorBrush(Color.Parse("#8D879C")),
            FontFamily = (FontFamily)Application.Current!.FindResource("Mono")!, TextTrimming = TextTrimming.CharacterEllipsis });
        var row = new DockPanel();
        DockPanel.SetDock(check, Dock.Left);
        row.Children.Add(check);
        if (r.Kind == RuleKind.mapLocal)
        {
            var badge = new Border { Background = new SolidColorBrush(Color.Parse("#33FFCC33")), CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0),
                Child = new TextBlock { Text = r.MapLocal.StatusCode.ToString(), FontSize = 10.5, Foreground = (IBrush)Application.Current!.FindResource("Gold")! },
                VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(badge, Dock.Right);
            row.Children.Add(badge);
        }
        row.Children.Add(text);
        return new ListBoxItem { Content = row, Tag = r.Id, Padding = new Thickness(8, 5) };
    }

    Rule? Current => state.Rules.Rules.FirstOrDefault(r => r.Id == selected);

    void ShowEditor()
    {
        if (tool == Tool.SslBypass) { editor.Content = SslBypassEditor(); return; }
        if (Current is not Rule rule)
        {
            editor.Content = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Spacing = 8, Margin = new Thickness(0, 120, 0, 0),
                Children = { new TextBlock { Text = "Select a rule", FontSize = 15, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
                             new TextBlock { Text = Help(tool) + "\nClick + New Rule, or right-click a request → Map Local / Script / Create Rule.",
                                             Foreground = new SolidColorBrush(Color.Parse("#8D879C")), TextWrapping = TextWrapping.Wrap, MaxWidth = 420, TextAlignment = TextAlignment.Center } },
            };
            return;
        }
        var panel = Ui.Column(4);
        panel.Children.Add(Ui.Card(CommonFields(rule)));
        panel.Children.Add(Ui.Card(rule.Kind switch
        {
            RuleKind.mapLocal => MapLocalFields(rule),
            RuleKind.mapRemote => MapRemoteFields(rule),
            RuleKind.rewrite => RewriteFields(rule),
            RuleKind.script => ScriptFields(rule),
            RuleKind.block => BlockFields(rule),
            _ => ThrottleFields(rule),
        }));
        editor.Content = panel;
    }

    void Save() => state.SaveRules();

    Control CommonFields(Rule rule)
    {
        var p = Ui.Column();
        var name = new TextBox { Text = rule.Name, FontSize = 16, FontWeight = FontWeight.SemiBold, BorderThickness = new Thickness(0), Background = Brushes.Transparent };
        name.TextChanged += (_, _) => { rule.Name = name.Text ?? ""; Save(); };
        var enabled = Ui.Check("Enabled", rule.Enabled, v => { rule.Enabled = v; Save(); Reload(); });
        var top = new DockPanel();
        DockPanel.SetDock(enabled, Dock.Right);
        top.Children.Add(enabled);
        top.Children.Add(name);
        p.Children.Add(top);
        p.Children.Add(Ui.Label("URL"));
        var match = Ui.Text("", 11, "#8D879C");
        void UpdateMatch()
        {
            var n = state.Visible.Count(f => rule.Matcher.Matches(f.Method, f.Url));
            match.Text = n == 0 ? "No recorded requests match" : $"✓ Matches {n} recorded {(n == 1 ? "request" : "requests")}";
            match.Foreground = new SolidColorBrush(Color.Parse(n == 0 ? "#8D879C" : "#FFCC33"));
        }
        p.Children.Add(Ui.Field(rule.Matcher.Pattern, v => { rule.Matcher.Pattern = v; Save(); UpdateMatch(); }, "https://api.example.com/v1/*"));
        p.Children.Add(Ui.Row(Ui.Check("Regex", rule.Matcher.UseRegex, v => { rule.Matcher.UseRegex = v; Save(); UpdateMatch(); }),
                              Ui.Check("Include all subpaths", rule.Matcher.IncludeSubpaths, v => { rule.Matcher.IncludeSubpaths = v; Save(); UpdateMatch(); })));
        p.Children.Add(Ui.Label("Methods (empty = any, e.g. GET, POST)"));
        p.Children.Add(Ui.Field(string.Join(", ", rule.Matcher.Methods), v =>
        {
            rule.Matcher.Methods = v.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(m => m.ToUpperInvariant()).ToList();
            Save(); UpdateMatch();
        }, "Any"));
        var groups = new List<(string, Guid?)> { ("No Group", null) };
        groups.AddRange(state.Rules.Groups.Select(g => (g.Name, (Guid?)g.Id)));
        var newGroup = Ui.Button("New Group", () =>
        {
            var g = new RuleGroup { Name = $"Group {state.Rules.Groups.Count + 1}" };
            state.Rules.Groups.Add(g);
            rule.GroupId = g.Id;
            Save(); Reload();
        });
        p.Children.Add(Ui.Label("Group"));
        p.Children.Add(Ui.Row(Ui.Combo(groups, rule.GroupId, v => { rule.GroupId = v; Save(); Reload(); }), newGroup));
        p.Children.Add(match);
        UpdateMatch();
        return p;
    }

    Control MapLocalFields(Rule rule)
    {
        var a = rule.MapLocal;
        var p = Ui.Column();
        p.Children.Add(Ui.Label("Response"));
        var status = Ui.Field(a.StatusCode.ToString(), v => { if (int.TryParse(v, out var c)) { a.StatusCode = c; Save(); } });
        status.Width = 80;
        var source = Ui.Combo(new[] { ("Text", MapLocalSource.inline), ("File", MapLocalSource.file), ("Folder", MapLocalSource.directory) }, a.Source,
            v => { a.Source = v; Save(); ShowEditor(); });
        p.Children.Add(Ui.Row(Ui.Text("Status"), status, Ui.Text("Source"), source));
        p.Children.Add(Ui.Label("Headers (one per line: Name: value)"));
        p.Children.Add(Ui.Code(Ui.HeadersToText(a.Headers), v => { a.Headers = Ui.TextToHeaders(v); Save(); }, 60));
        if (a.Source == MapLocalSource.inline)
        {
            TextBox? body = null;
            p.Children.Add(Ui.Row(Ui.Label("Body"), Ui.Button("Format JSON", () => { if (body != null) body.Text = Body.PrettyJson(body.Text ?? ""); })));
            body = Ui.Code(a.Body, v => { a.Body = v; Save(); }, 260);
            p.Children.Add(body);
        }
        else
        {
            var dir = a.Source == MapLocalSource.directory;
            TextBox? path = null;
            path = Ui.Field(a.Path, v => { a.Path = v; Save(); }, dir ? "Folder" : "File");
            var choose = Ui.Button("Choose…", async () =>
            {
                if (dir)
                {
                    var r = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions());
                    if (r.Count > 0) path.Text = r[0].Path.LocalPath;
                }
                else
                {
                    var r = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions());
                    if (r.Count > 0) path.Text = r[0].Path.LocalPath;
                }
            });
            p.Children.Add(Ui.Label(dir ? "Folder" : "File"));
            var row = new DockPanel();
            DockPanel.SetDock(choose, Dock.Right);
            row.Children.Add(choose);
            row.Children.Add(path);
            p.Children.Add(row);
            p.Children.Add(Ui.Text(dir
                ? "The rest of the path after the part before “*” is looked up in the folder. Example: rule https://api.x.com/v1/* and folder C:\\mocks — /v1/users/42 returns C:\\mocks\\users\\42 (or 42.json)."
                : "The file is read on every request — edit it in any editor.", 11, "#8D879C"));
        }
        return p;
    }

    Control MapRemoteFields(Rule rule)
    {
        var a = rule.MapRemote;
        var p = Ui.Column();
        p.Children.Add(Ui.Label("Map to (empty field = unchanged)"));
        p.Children.Add(Ui.Combo(new[] { ("Scheme unchanged", ""), ("https", "https"), ("http", "http") }, a.Scheme, v => { a.Scheme = v; Save(); }));
        p.Children.Add(Ui.Field(a.Host, v => { a.Host = v; Save(); }, "Host, e.g. staging.example.com"));
        p.Children.Add(Ui.Field(a.Port?.ToString() ?? "", v => { a.Port = int.TryParse(v, out var n) ? n : null; Save(); }, "Port (default)"));
        p.Children.Add(Ui.Field(a.Path, v => { a.Path = v; Save(); }, "Path, e.g. /v2/users"));
        p.Children.Add(Ui.Check("Preserve the original Host header", a.PreserveHostHeader, v => { a.PreserveHostHeader = v; Save(); }));
        return p;
    }

    Control RewriteFields(Rule rule)
    {
        var p = Ui.Column(8);
        p.Children.Add(Ui.Row(Ui.Label("Changes"), Ui.Button("+ Add", () => { rule.Rewrite.Add(new RewriteStep()); Save(); ShowEditor(); })));
        var ops = new[]
        {
            ("Set Header", RewriteOperation.setHeader), ("Remove Header", RewriteOperation.removeHeader), ("Replace in Body", RewriteOperation.replaceBody),
            ("Replace Whole Body", RewriteOperation.setBody), ("Status Code", RewriteOperation.setStatus), ("Set Query Parameter", RewriteOperation.setQuery),
            ("Remove Query Parameter", RewriteOperation.removeQuery), ("Replace in URL", RewriteOperation.replaceURL),
        };
        foreach (var step in rule.Rewrite.ToList())
        {
            var s = step;
            var box = Ui.Column(4);
            box.Children.Add(Ui.Row(
                Ui.Combo(new[] { ("Request", RewriteTarget.request), ("Response", RewriteTarget.response) }, s.Target, v => { s.Target = v; Save(); }),
                Ui.Combo(ops, s.Operation, v => { s.Operation = v; Save(); }),
                Ui.Button("Delete", () => { rule.Rewrite.Remove(s); Save(); ShowEditor(); })));
            box.Children.Add(Ui.Field(s.Key, v => { s.Key = v; Save(); }, "Header / Find / Parameter"));
            box.Children.Add(Ui.Field(s.Value, v => { s.Value = v; Save(); }, "Value / Replacement / Status"));
            box.Children.Add(Ui.Check("Regex", s.UseRegex, v => { s.UseRegex = v; Save(); }));
            p.Children.Add(new Border { Background = new SolidColorBrush(Color.Parse("#1E1B26")), CornerRadius = new CornerRadius(10), Padding = new Thickness(10), Child = box });
        }
        return p;
    }

    Control ScriptFields(Rule rule)
    {
        var p = Ui.Column();
        TextBox? code = null;
        p.Children.Add(Ui.Row(Ui.Label("JavaScript"), Ui.Button("Reset Template", () => { if (code != null) code.Text = Rule.DefaultScript; })));
        code = Ui.Code(rule.Script, v => { rule.Script = v; Save(); }, 300);
        p.Children.Add(code);
        p.Children.Add(Ui.Text("request: method, url, headers, body · response: statusCode, headers, body. A JSON body arrives as an object. console.log writes to the log below. Changes are saved automatically.", 11, "#8D879C"));
        p.Children.Add(Ui.Label("Log"));
        var log = new ListBox { ItemsSource = state.ScriptLog, Height = 130, FontFamily = (FontFamily)Application.Current!.FindResource("Mono")!, FontSize = 11 };
        p.Children.Add(log);
        return p;
    }

    Control BlockFields(Rule rule)
    {
        var p = Ui.Column();
        p.Children.Add(Ui.Label("Action"));
        p.Children.Add(Ui.Combo(new[] { ("Respond 403 Forbidden", BlockMode.forbidden), ("Respond 404 Not Found", BlockMode.notFound), ("Drop the connection", BlockMode.dropConnection) },
            rule.BlockMode, v => { rule.BlockMode = v; Save(); }));
        return p;
    }

    Control ThrottleFields(Rule rule)
    {
        var t = rule.Throttle;
        var p = Ui.Column();
        p.Children.Add(Ui.Label("Network"));
        var latency = Ui.Field(t.LatencyMs.ToString(), v => { if (int.TryParse(v, out var n)) { t.LatencyMs = n; Save(); } });
        var speed = Ui.Field(t.DownloadKbps.ToString(), v => { if (int.TryParse(v, out var n)) { t.DownloadKbps = n; Save(); } });
        var presets = Ui.Row();
        foreach (var (title, ms, kbps) in new[] { ("3G", 300, 750), ("Edge", 800, 240), ("Bad Wi-Fi", 500, 1000), ("LTE", 80, 12000) })
            presets.Children.Add(Ui.Button(title, () => { latency.Text = ms.ToString(); speed.Text = kbps.ToString(); }));
        p.Children.Add(presets);
        p.Children.Add(Ui.Row(Ui.Text("Latency, ms"), latency));
        p.Children.Add(Ui.Row(Ui.Text("Speed, kbit/s (0 = unlimited)"), speed));
        return p;
    }

    Control SslBypassEditor()
    {
        var p = Ui.Column();
        p.Children.Add(Ui.Text(Help(Tool.SslBypass), 12.5, "#8D879C"));
        p.Children.Add(Ui.Label("Hosts (one per line, *.example.com for all subdomains)"));
        p.Children.Add(Ui.Code(string.Join("\n", state.Rules.SslBypass), v =>
        {
            state.Rules.SslBypass = v.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            Save();
        }, 260));
        p.Children.Add(Ui.Check("Automatically bypass hosts whose client rejects the certificate (pinning)", state.Settings.AutoBypassPinned,
            v => { state.Settings.AutoBypassPinned = v; state.SaveSettings(); }));
        return Ui.Card(p);
    }

    // MARK: - Actions

    void AddRule()
    {
        if (KindOf(tool) is not RuleKind kind) return;
        var rule = new Rule { Name = "New Rule", Kind = kind, Matcher = new() { Pattern = "https://api.example.com/*" } };
        if (kind == RuleKind.rewrite) rule.Rewrite.Add(new RewriteStep());
        if (Current?.GroupId is Guid g) rule.GroupId = g;
        state.AddRule(rule);
        selected = rule.Id;
        Reload();
    }

    void Duplicate()
    {
        if (Current is not Rule r) return;
        var copy = r.Clone();
        copy.Id = Guid.NewGuid();
        copy.Name += " (copy)";
        state.Rules.Rules.Insert(state.Rules.Rules.IndexOf(r) + 1, copy);
        Save();
        selected = copy.Id;
        Reload();
    }

    void Delete()
    {
        if (Current is not Rule r) return;
        selected = null;
        state.Rules.Rules.Remove(r);
        Save();
        Reload();
    }

    async Task Export()
    {
        if (KindOf(tool) is not RuleKind kind) return;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { SuggestedFileName = $"Snifix {ToolTitle(tool)}.json" });
        if (file == null) return;
        var doc = new RulesDocument { SslBypass = new(), Rules = state.Rules.Rules.Where(r => r.Kind == kind).ToList() };
        var used = doc.Rules.Select(r => r.GroupId).ToHashSet();
        doc.Groups = state.Rules.Groups.Where(g => used.Contains(g.Id)).ToList();
        await using var s = await file.OpenWriteAsync();
        await JsonSerializer.SerializeAsync(s, doc, Json.Options);
        state.ShowToast($"Exported {doc.Rules.Count} rules");
    }

    async Task Import()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = false });
        if (files.Count == 0) return;
        try
        {
            await using var s = await files[0].OpenReadAsync();
            var doc = await JsonSerializer.DeserializeAsync<RulesDocument>(s, Json.Options) ?? throw new Exception();
            var map = new Dictionary<Guid, Guid>();
            foreach (var g in doc.Groups) { var id = Guid.NewGuid(); map[g.Id] = id; g.Id = id; state.Rules.Groups.Add(g); }
            foreach (var r in doc.Rules) { r.Id = Guid.NewGuid(); r.GroupId = r.GroupId is Guid old && map.TryGetValue(old, out var n) ? n : null; state.Rules.Rules.Add(r); }
            Save();
            Reload();
            state.ShowToast($"Imported {doc.Rules.Count} rules");
        }
        catch { state.ShowToast("This file does not look like Snifix rules"); }
    }
}
