using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Snifix.Core;

namespace Snifix;

public partial class MainWindow : Window
{
    readonly AppState state = AppState.Shared;
    DispatcherTimer? toastTimer;
    Flow? shown;

    public MainWindow()
    {
        InitializeComponent();
        Grid.ItemsSource = state.Visible;
        AccessBanners.ItemsSource = state.AccessRequests;
        SidebarTree.ItemsSource = state.Sidebar;

        foreach (var c in Categories.All)
        {
            var chip = new ToggleButton { Content = c, IsChecked = c == "All" };
            chip.Classes.Add("chip");
            chip.Click += (_, _) =>
            {
                foreach (var other in Chips.Items.OfType<ToggleButton>()) other.IsChecked = other == chip;
                state.Category = c;
            };
            Chips.Items.Add(chip);
        }

        SearchBox.TextChanged += (_, _) => state.Search = SearchBox.Text ?? "";
        StatusBox.SelectionChanged += (_, _) => state.StatusFilter = (StatusBox.SelectedItem as ComboBoxItem)?.Content as string ?? "Any Status";
        SidebarTree.SelectionChanged += (_, _) =>
        {
            var node = SidebarTree.SelectedItem as SidebarNode;
            state.SidebarSelection = node == null || node.Key == "all" || node.IsHeader ? null : node;
        };
        // A click anywhere on a row opens it, not only on the arrow
        SidebarTree.AddHandler(PointerReleasedEvent, (_, e) =>
        {
            if (e.Source is Visual v && v.FindAncestorOfType<TreeViewItem>() is TreeViewItem item
                && e.Source is not Avalonia.Controls.Shapes.Path && item.DataContext is SidebarNode node && node.Children.Count > 0
                && e.InitialPressMouseButton == MouseButton.Left)
                node.IsExpanded = !node.IsExpanded || SidebarTree.SelectedItem != node;
        }, RoutingStrategies.Bubble, handledEventsToo: true);
        state.SidebarRebuilt += () =>
        {
            if (state.SidebarSelection != null) SidebarTree.SelectedItem = state.SidebarSelection;
        };

        Grid.SelectionChanged += (_, _) => ShowDetail(Grid.SelectedItem as Flow);
        Grid.DoubleTapped += (_, _) => { if (Grid.SelectedItem is Flow f) ComposeWindow.Open(this, f); };
        Grid.ContextMenu = BuildContextMenu();
        state.Visible.CollectionChanged += (_, _) => EmptyState.IsVisible = state.Total == 0;
        state.PropertyChanged += (_, _) => Dispatcher.UIThread.Post(UpdateChrome);
        state.Toast += text => Dispatcher.UIThread.Post(() => ShowToast(text));

        KeyDown += OnKey;
        Closing += (_, _) => state.Shutdown();
        UpdateChrome();
        Opened += (_, _) => { if (shown != null) ShowDetail(shown); };
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        if (!e.KeyModifiers.HasFlag(KeyModifiers.Control) && !e.KeyModifiers.HasFlag(KeyModifiers.Meta)) return;
        switch (e.Key)
        {
            case Key.R: state.Recording = !state.Recording; break;
            case Key.K: state.Clear(); break;
            case Key.N: ComposeWindow.Open(this, null); break;
            case Key.P when e.KeyModifiers.HasFlag(KeyModifiers.Shift): state.SetSystemProxy(!state.SystemProxy); break;
            default: return;
        }
        e.Handled = true;
    }

    void UpdateChrome()
    {
        RecordButton.IsChecked = state.Recording;
        RecordText.Text = state.Recording ? "Recording" : "Paused";
        RecordDot.Fill = state.Recording ? new SolidColorBrush(Color.Parse("#FF4D4D")) : new SolidColorBrush(Color.Parse("#8D879C"));
        SubtitleText.Text = $"{(state.Recording ? "Recording" : "Paused")} · {state.Total}";
        ProxyText.Text = state.SystemProxy ? "PC: On" : "PC: Off";
        ProxyButton.Classes.Set("gold", state.SystemProxy);
        AddressText.Text = $"{state.LocalAddress}:{state.Settings.Port}";
        StatusDot.Fill = new SolidColorBrush(Color.Parse(state.ProxyError == null ? "#4ADE80" : "#FF5A52"));
        ProxyStatusText.Text = state.SystemProxy ? "PC: capturing" : "PC: off";
        ProxyStatusText.Foreground = state.SystemProxy ? (IBrush)this.FindResource("Gold")! : (IBrush)this.FindResource("Muted")!;
        CountText.Text = state.CountText;
        ErrorBanner.IsVisible = state.ProxyError != null;
        ErrorText.Text = state.ProxyError ?? "";
        CertBanner.IsVisible = OperatingSystem.IsWindows() && !state.CertificateTrusted;
        EmptyState.IsVisible = state.Total == 0;
    }

    void ShowToast(string text)
    {
        ToastText.Text = text;
        ToastBorder.Opacity = 1;
        toastTimer?.Stop();
        toastTimer = new DispatcherTimer(TimeSpan.FromSeconds(2.6), DispatcherPriority.Normal, (_, _) => { ToastBorder.Opacity = 0; toastTimer?.Stop(); });
        toastTimer.Start();
    }

    // MARK: - Detail

    void ShowDetail(Flow? f)
    {
        shown = f;
        state.Shown = f;
        if (f == null)
        {
            RequestTitle.Text = ResponseTitle.Text = "";
            foreach (var t in new[] { RequestHeaders, RequestQuery, RequestBody, RequestRaw, Summary, ResponseHeaders, ResponseBody, ResponseRaw }) t.Text = "";
            return;
        }
        var uri = new Uri(f.Url);
        RequestTitle.Text = $"{f.Method} {uri.PathAndQuery}";
        RequestTitle.Foreground = new SolidColorBrush(Color.Parse(f.MethodColor));
        RequestHeaders.Text = HeadersText(f.RequestHeaders);
        RequestQuery.Text = string.Join("\n", uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(kv => { var p = kv.Split('=', 2); return $"{Uri.UnescapeDataString(p[0])}: {(p.Length > 1 ? Uri.UnescapeDataString(p[1]) : "")}"; }));
        RequestBody.Text = Pretty(Body.Text(f.RequestBody, f.RequestHeader("Content-Encoding")));
        RequestRaw.Text = $"{f.Method} {uri.PathAndQuery} {f.RequestVersion}\n{HeadersText(f.RequestHeaders)}\n\n{Body.Text(f.RequestBody, f.RequestHeader("Content-Encoding"))}";
        var sb = new StringBuilder();
        sb.AppendLine($"URL            {f.Url}");
        sb.AppendLine($"Client         {f.AppName} · {f.DeviceName}");
        sb.AppendLine($"Client address {f.ClientAddress}");
        if (f.AppPath != null) sb.AppendLine($"Program        {f.AppPath}");
        sb.AppendLine($"Started        {f.TimeText}");
        sb.AppendLine($"Duration       {f.DurationText}");
        sb.AppendLine($"HTTPS          {(f.IsHttps ? "Yes, decrypted by Snifix" : "No")}");
        sb.AppendLine($"Protocol       client {f.RequestVersion}, server {(f.ResponseVersion == "" ? "—" : f.ResponseVersion)}");
        sb.AppendLine($"Request size   {Format.Bytes(f.RequestSize)}");
        sb.AppendLine($"Response size  {Format.Bytes(f.ResponseSize)}");
        if (f.BodiesDropped || f.RequestBodyDropped) sb.AppendLine($"Bodies         {DroppedNote}");
        if (f.Rules.Count > 0) sb.AppendLine($"Rules          {f.RuleNames}");
        if (f.Error != "") sb.AppendLine($"Error          {f.Error}");
        Summary.Text = sb.ToString();

        if (f.State == FlowState.Failed) { ResponseTitle.Text = "Error"; ResponseBody.Text = f.Error; ResponseHeaders.Text = ResponseRaw.Text = ""; }
        else if (f.State == FlowState.Tunnel)
        {
            ResponseTitle.Text = "Tunnel";
            ResponseBody.Text = "Tunnel without decryption.\nThe host is in SSL Bypass, outside the Allow List, or the client rejected the certificate.";
            ResponseHeaders.Text = ResponseRaw.Text = "";
        }
        else if (f.State == FlowState.Active) { ResponseTitle.Text = "Waiting…"; ResponseHeaders.Text = ResponseBody.Text = ResponseRaw.Text = ""; }
        else
        {
            ResponseTitle.Text = $"{f.StatusCode} {f.Reason}";
            ResponseTitle.Foreground = new SolidColorBrush(Color.Parse(f.StatusColor));
            ResponseHeaders.Text = HeadersText(f.ResponseHeaders) + (f.Trailers.Count > 0 ? "\n\nTrailers\n" + HeadersText(f.Trailers) : "");
            var text = Body.Text(f.ResponseBody, f.ResponseHeader("Content-Encoding"));
            ResponseBody.Text = Pretty(text);
            ResponseRaw.Text = $"{f.ResponseVersion} {f.StatusCode} {f.Reason}\n{HeadersText(f.ResponseHeaders)}\n\n{text}";
        }
        if (f.RequestBodyDropped) RequestBody.Text = DroppedNote;
        if (f.BodiesDropped && f.State == FlowState.Completed) ResponseBody.Text = DroppedNote;
    }

    const string DroppedNote = "Not kept: older bodies are removed when stored bodies pass the memory limit. Headers and timing are kept.";

    static string HeadersText(List<HeaderItem> headers) => string.Join("\n", headers.Select(h => $"{h.Name}: {h.Value}"));
    static string Pretty(string text) => text.TrimStart().StartsWith('{') || text.TrimStart().StartsWith('[') ? Body.PrettyJson(text) : text;

    // MARK: - Context menu

    ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();
        MenuItem Item(string header, Action<Flow> action)
        {
            var m = new MenuItem { Header = header };
            m.Click += (_, _) => { if (Grid.SelectedItem is Flow f) action(f); };
            return m;
        }
        var create = new MenuItem { Header = "Create Rule" };
        foreach (var (title, kind) in new[] { ("Map Remote", RuleKind.mapRemote), ("Rewrite", RuleKind.rewrite), ("Block", RuleKind.block), ("Network Conditions", RuleKind.throttle) })
            create.Items.Add(Item(title, f => NewRule(kind, f)));
        menu.Items.Add(Item("Copy URL", f => Copy(f.Url)));
        menu.Items.Add(Item("Copy as cURL", f => Copy(Curl(f), "cURL copied")));
        menu.Items.Add(Item("Copy Response Body", f => Copy(Body.Text(f.ResponseBody, f.ResponseHeader("Content-Encoding")))));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Repeat", f =>
        {
            if (f.RequestBodyDropped) ShowToast("Request body was not kept (memory limit) — not sent");
            else _ = state.Engine.Send(f.Method, f.Url, f.RequestHeaders, f.RequestBody);
        }));
        menu.Items.Add(Item("Edit & Send…", f => ComposeWindow.Open(this, f)));
        menu.Items.Add(Item("Script for This Request…", f => NewRule(RuleKind.script, f)));
        menu.Items.Add(Item("Map Local (Mock Response)…", f => NewRule(RuleKind.mapLocal, f)));
        menu.Items.Add(new Separator());
        menu.Items.Add(create);
        menu.Items.Add(Item("Bypass SSL for This Host", f =>
        {
            if (!state.Rules.SslBypass.Contains(f.Host)) { state.Rules.SslBypass.Add(f.Host); state.SaveRules(); }
            ShowToast($"{f.Host} added to SSL Bypass");
        }));
        menu.Items.Add(new Separator());
        var delete = new MenuItem { Header = "Delete" };
        delete.Click += (_, _) => state.Remove(Grid.SelectedItems.OfType<Flow>());
        menu.Items.Add(delete);
        return menu;
    }

    void NewRule(RuleKind kind, Flow f)
    {
        var rule = state.MakeRule(kind, f);
        state.AddRule(rule);
        RulesWindow.Open(this, kind, rule.Id);
    }

    void Copy(string text, string note = "Copied")
    {
        Clipboard?.SetTextAsync(text);
        ShowToast(note);
    }

    static string Curl(Flow f)
    {
        string Q(string s) => "'" + s.Replace("'", "'\\''") + "'";
        var parts = new List<string> { "curl" };
        if (f.Method != "GET") parts.Add("-X " + f.Method);
        parts.Add(Q(f.Url));
        foreach (var h in f.RequestHeaders.Where(h => !new[] { "host", "content-length", "connection", "proxy-connection" }.Contains(h.Name.ToLowerInvariant())))
            parts.Add("-H " + Q($"{h.Name}: {h.Value}"));
        if (f.RequestBody.Length > 0) parts.Add("--data-raw " + Q(Encoding.UTF8.GetString(f.RequestBody)));
        return string.Join(" \\\n  ", parts);
    }

    public void SelectForSnapshot()
    {
        var f = state.Visible.FirstOrDefault(x => x.Method == "POST") ?? state.Visible.FirstOrDefault();
        if (f != null) Grid.SelectedItem = f;
    }

    // MARK: - Toolbar

    void OnRecord(object? s, RoutedEventArgs e) => state.Recording = RecordButton.IsChecked == true;
    void OnClear(object? s, RoutedEventArgs e) { state.Clear(); ShowDetail(null); }
    void OnSystemProxy(object? s, RoutedEventArgs e)
    {
        if (!OperatingSystem.IsWindows()) { ShowToast("Capturing this PC's traffic works on Windows."); return; }
        if (!state.SystemProxy && !state.CertificateTrusted) { ShowToast("Install the certificate first (Devices → This PC)"); }
        state.SetSystemProxy(!state.SystemProxy);
        ShowToast(state.SystemProxy ? "This PC's traffic goes through Snifix" : "This PC goes online directly");
    }
    void OnCompose(object? s, RoutedEventArgs e) => ComposeWindow.Open(this, null);
    void OnRules(object? s, RoutedEventArgs e) => RulesWindow.Open(this, RuleKind.mapLocal, null);
    void OnScripting(object? s, RoutedEventArgs e) => RulesWindow.Open(this, RuleKind.script, null);
    void OnDevices(object? s, RoutedEventArgs e) => DevicesWindow.Open(this);
    void OnDonate(object? s, RoutedEventArgs e) => new DonateWindow().ShowDialog(this);
    void OnTrust(object? s, RoutedEventArgs e) => state.TrustCertificate();
    void OnAllowDevice(object? s, RoutedEventArgs e) { if ((s as Button)?.Tag is string a) state.AllowDevice(a); }
    void OnDenyDevice(object? s, RoutedEventArgs e) { if ((s as Button)?.Tag is string a) state.DenyDevice(a); }
}
