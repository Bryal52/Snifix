using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Animation;
using Avalonia.Platform;
using QRCoder;
using Snifix.Core;

namespace Snifix;

/// Request on the left (edit and send), the answer on the right (edit and make the app receive it).
public sealed class ComposeWindow : Window
{
    static ComposeWindow? current;
    readonly AppState state = AppState.Shared;
    readonly ComboBox method = new() { Width = 100, ItemsSource = new[] { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" } };
    readonly TextBox url = new() { Watermark = "https://" };
    readonly TextBox requestHeaders = new() { Classes = { "code" }, MinHeight = 90 };
    readonly TextBox requestBody = new() { Classes = { "code" } };
    readonly TextBox status = new() { Width = 80 };
    readonly TextBox responseHeaders = new() { Classes = { "code" }, MinHeight = 90 };
    readonly TextBox responseBody = new() { Classes = { "code" } };
    readonly TextBlock responseTitle = new() { FontFamily = new FontFamily("Cascadia Mono, Consolas, Menlo, monospace"), FontSize = 12 };
    readonly Button send = Ui.Button("Send  ⏎", () => { }, gold: true);
    readonly Button mock = Ui.Button("Mock This Response", () => { }, gold: true);
    readonly Button stopMock = Ui.Button("Stop Mocking", () => { });
    Guid? mockRule;

    public static void Open(Window owner, Flow? flow)
    {
        current ??= new ComposeWindow();
        current.Load(flow);
        if (!current.IsVisible) current.Show(owner);
        current.Activate();
    }

    ComposeWindow()
    {
        Title = "Edit & Send";
        Width = 1100; Height = 680; MinWidth = 860; MinHeight = 500;
        Closed += (_, _) => current = null;
        url.FontFamily = responseTitle.FontFamily;
        send.Click += async (_, _) => await Send();
        mock.Click += (_, _) => ApplyMock();
        stopMock.Click += (_, _) => SetMock(false);
        stopMock.IsVisible = false;
        KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter && e.KeyModifiers.HasFlag(Avalonia.Input.KeyModifiers.Control)) await Send(); };

        var left = new DockPanel { Margin = new Thickness(14) };
        var lt = Ui.Column(6);
        lt.Children.Add(new TextBlock { Text = "REQUEST", Classes = { "title" } });
        var urlRow = new DockPanel();
        DockPanel.SetDock(method, Dock.Left);
        urlRow.Children.Add(method);
        urlRow.Children.Add(url);
        lt.Children.Add(urlRow);
        lt.Children.Add(Ui.Label("Headers (Name: value)"));
        lt.Children.Add(requestHeaders);
        lt.Children.Add(Ui.Label("Body"));
        DockPanel.SetDock(lt, Dock.Top);
        left.Children.Add(lt);
        var lb = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        send.HorizontalAlignment = HorizontalAlignment.Right;
        DockPanel.SetDock(send, Dock.Right);
        lb.Children.Add(send);
        lb.Children.Add(Ui.Text("The request goes through your rules and shows up in the list.", 11, "#8D879C"));
        DockPanel.SetDock(lb, Dock.Bottom);
        left.Children.Add(lb);
        left.Children.Add(requestBody);

        var right = new DockPanel { Margin = new Thickness(14) };
        var rt = Ui.Column(6);
        rt.Children.Add(Ui.Row(new TextBlock { Text = "RESPONSE", Classes = { "title" } }, responseTitle));
        rt.Children.Add(Ui.Row(Ui.Text("Status"), status));
        rt.Children.Add(Ui.Label("Headers (Name: value)"));
        rt.Children.Add(responseHeaders);
        rt.Children.Add(Ui.Label("Body"));
        DockPanel.SetDock(rt, Dock.Top);
        right.Children.Add(rt);
        var rb = Ui.Row(Ui.Button("Format JSON", () => responseBody.Text = Body.PrettyJson(responseBody.Text ?? "")), stopMock, mock);
        rb.HorizontalAlignment = HorizontalAlignment.Right;
        rb.Margin = new Thickness(0, 8, 0, 0);
        DockPanel.SetDock(rb, Dock.Bottom);
        right.Children.Add(rb);
        right.Children.Add(responseBody);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,1,*") };
        grid.Children.Add(left);
        grid.Children.Add(new Border { Background = new SolidColorBrush(Color.Parse("#2A2633")), [Grid.ColumnProperty] = 1 });
        right[Grid.ColumnProperty] = 2;
        grid.Children.Add(right);
        Content = grid;
    }

    void Load(Flow? f)
    {
        mockRule = null;
        stopMock.IsVisible = false;
        if (f == null)
        {
            method.SelectedItem = "GET"; url.Text = "https://"; requestHeaders.Text = "Accept: application/json"; requestBody.Text = "";
            SetResponse(null, new(), "");
            return;
        }
        method.SelectedItem = f.Method;
        url.Text = f.Url;
        requestHeaders.Text = Ui.HeadersToText(f.RequestHeaders.Where(h => !h.Name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)).ToList());
        requestBody.Text = Body.PrettyJson(Body.Text(f.RequestBody, f.RequestHeader("Content-Encoding")));
        if (f.State == FlowState.Completed)
            SetResponse(f.StatusCode, f.ResponseHeaders, Body.PrettyJson(Body.Text(f.ResponseBody, f.ResponseHeader("Content-Encoding"))));
        else SetResponse(null, new(), "");
    }

    void SetResponse(int? code, List<HeaderItem> headers, string body)
    {
        responseTitle.Text = code is int c ? $"{c} {ProxyEngine.Reason(c)}" : "Press Send (Ctrl+Enter)";
        status.Text = code?.ToString() ?? "200";
        responseHeaders.Text = Ui.HeadersToText(headers.Where(h => !new[] { "content-length", "content-encoding", "transfer-encoding" }.Contains(h.Name.ToLowerInvariant())).ToList());
        responseBody.Text = body;
    }

    async Task Send()
    {
        var target = url.Text?.Trim() ?? "";
        if (!Uri.TryCreate(target, UriKind.Absolute, out _)) { state.ShowToast("Enter a full URL"); return; }
        send.IsEnabled = false;
        var (code, headers, body, error) = await state.Engine.Send(method.SelectedItem as string ?? "GET", target,
            Ui.TextToHeaders(requestHeaders.Text ?? ""), Encoding.UTF8.GetBytes(requestBody.Text ?? ""));
        send.IsEnabled = true;
        if (error != null) { state.ShowToast("The server did not respond: " + error); return; }
        SetResponse(code, headers, Body.PrettyJson(Encoding.UTF8.GetString(body)));
    }

    void ApplyMock()
    {
        if (!Uri.TryCreate(url.Text?.Trim() ?? "", UriKind.Absolute, out var u)) return;
        var m = method.SelectedItem as string ?? "GET";
        var rule = state.Rules.Rules.FirstOrDefault(r => r.Id == mockRule) ?? new Rule
        {
            Name = $"{m} {u.Host}{u.AbsolutePath}", Kind = RuleKind.mapLocal,
            Matcher = new RuleMatcher { Pattern = u.GetLeftPart(UriPartial.Path), IncludeSubpaths = false, Methods = new() { m } },
        };
        rule.Enabled = true;
        rule.MapLocal.Source = MapLocalSource.inline;
        rule.MapLocal.StatusCode = int.TryParse(status.Text, out var c) ? c : 200;
        rule.MapLocal.Headers = Ui.TextToHeaders(responseHeaders.Text ?? "");
        rule.MapLocal.Body = responseBody.Text ?? "";
        if (!state.Rules.Rules.Contains(rule)) state.Rules.Rules.Add(rule);
        state.SaveRules();
        mockRule = rule.Id;
        stopMock.IsVisible = true;
        mock.Content = "Update Mock";
        state.ShowToast($"The app now receives this response · Map Local “{rule.Name}”");
    }

    void SetMock(bool on)
    {
        var rule = state.Rules.Rules.FirstOrDefault(r => r.Id == mockRule);
        if (rule == null) return;
        rule.Enabled = on;
        state.SaveRules();
        stopMock.IsVisible = on;
        state.ShowToast(on ? "Mock enabled" : "Mock disabled — the server answers again");
    }
}

public sealed class DevicesWindow : Window
{
    static DevicesWindow? current;
    readonly AppState state = AppState.Shared;

    public static void Open(Window owner, int tab = 1)
    {
        current ??= new DevicesWindow(tab);
        if (!current.IsVisible) current.Show(owner);
        current.Activate();
    }

    DevicesWindow(int tab)
    {
        Title = "Devices";
        Width = 720; Height = 760; MinWidth = 620; MinHeight = 600;
        Closed += (_, _) => current = null;
        if (Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT_DEVICE_TAB") is string t && int.TryParse(t, out var n)) tab = n;
        var tabs = new TabControl { Margin = new Thickness(16, 10) };
        tabs.Items.Add(new TabItem { Header = "This PC", Content = new ScrollViewer { Content = PcCard() } });
        tabs.Items.Add(new TabItem { Header = "iPhone", Content = new ScrollViewer { Content = PhoneCard(false) } });
        tabs.Items.Add(new TabItem { Header = "Android", Content = new ScrollViewer { Content = PhoneCard(true) } });
        // Selecting before the tabs exist would fall back to the first one
        tabs.SelectedIndex = tab;
        Content = tabs;
    }

    static Image Qr(string text)
    {
        var png = new PngByteQRCode(new QRCodeGenerator().CreateQrCode(text, QRCodeGenerator.ECCLevel.M)).GetGraphic(10);
        return new Image { Source = new Bitmap(new MemoryStream(png)), Width = 150, Height = 150 };
    }

    static Control Step(int n, string text)
    {
        var dot = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = new SolidColorBrush(Color.Parse("#2A2633")),
            Child = new TextBlock { Text = n.ToString(), FontWeight = FontWeight.Bold, FontSize = 11, Foreground = new SolidColorBrush(Color.Parse("#FFCC33")),
                                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            VerticalAlignment = VerticalAlignment.Top,
        };
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(dot, Dock.Left);
        row.Children.Add(dot);
        row.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 2, 0, 0) });
        return row;
    }

    static Control CopyField(string text)
    {
        var box = new TextBox { Text = text, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, Consolas, Menlo, monospace"),
                                Foreground = new SolidColorBrush(Color.Parse("#FFCC33")), FontSize = 12 };
        var copy = Ui.Button("Copy", () => TopLevel.GetTopLevel(box)?.Clipboard?.SetTextAsync(text));
        var row = new DockPanel { Margin = new Thickness(32, 0, 0, 8) };
        DockPanel.SetDock(copy, Dock.Right);
        row.Children.Add(copy);
        row.Children.Add(box);
        return row;
    }

    /// The certificate comes over plain Wi-Fi, so the phone's copy should be compared with this one.
    Control FingerprintBox(bool android)
    {
        var p = Ui.Column(4);
        p.Children.Add(new TextBlock { Text = "Check the certificate", FontWeight = FontWeight.SemiBold });
        p.Children.Add(Ui.Text(android
            ? "On the phone open Settings → Security → Encryption & credentials → Trusted credentials → User → Snifix CA: the SHA-256 fingerprint must be the same as here."
            : "On the iPhone open Settings → General → VPN & Device Management → Snifix CA → More Details: the SHA-256 fingerprint must be the same as here. If it differs, do not trust it — someone on the network replaced it.",
            11, "#8D879C"));
        p.Children.Add(new SelectableTextBlock { Text = state.Engine.Fingerprint, FontSize = 11, TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(Color.Parse("#FFCC33")), FontFamily = new FontFamily("Cascadia Mono, Consolas, Menlo, monospace") });
        return p;
    }

    Control PcCard()
    {
        var p = Ui.Column(10);
        p.Children.Add(new TextBlock { Text = "This PC", FontSize = 18, FontWeight = FontWeight.SemiBold });
        var trusted = state.CertificateTrusted;
        p.Children.Add(Ui.Text(trusted ? "✓ Certificate installed and trusted" : "Certificate not installed", 13.5, trusted ? "#FFCC33" : "#FF9A1F"));
        p.Children.Add(Ui.Text($"“{state.Engine.RootCertificateName}” lets browsers and apps on this PC accept decrypted HTTPS. Windows shows a security warning — confirm it to trust Snifix. Firefox has its own store: import snifix-ca.pem from the Snifix folder in its settings.", 12, "#B9B5C6"));
        if (!trusted) p.Children.Add(Ui.Button("Install Certificate…", () => state.TrustCertificate(), gold: true));
        p.Children.Add(Ui.Check("Capture this PC's traffic at launch (when the certificate is trusted)", state.Settings.CaptureOnLaunch,
            v => { state.Settings.CaptureOnLaunch = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Text("Fingerprint (SHA-256): " + state.Engine.Fingerprint, 10.5, "#8D879C"));
        var replace = Ui.Button("Replace Certificate…", async () =>
        {
            var ok = false;
            var dialog = new Window { Title = "Replace the Snifix certificate?", Width = 500, SizeToContent = SizeToContent.Height, CanResize = false,
                                      WindowStartupLocation = WindowStartupLocation.CenterOwner };
            var body = Ui.Column(14);
            body.Margin = new Thickness(20);
            body.Children.Add(new TextBlock { Text = "Replace the Snifix certificate?", FontSize = 16, FontWeight = FontWeight.SemiBold });
            body.Children.Add(Ui.Text("Snifix makes a new certificate and key and restarts. Every phone and this PC must then install and trust the new certificate again; the old one stops working.", 12.5, "#B9B5C6"));
            var row = Ui.Row(Ui.Button("Cancel", () => dialog.Close()), Ui.Button("Replace and Restart", () => { ok = true; dialog.Close(); }, gold: true));
            row.HorizontalAlignment = HorizontalAlignment.Right;
            body.Children.Add(row);
            dialog.Content = body;
            await dialog.ShowDialog(this);
            if (ok) state.ReplaceCertificate();
        });
        p.Children.Add(replace);
        p.Children.Add(Ui.Label("Other devices on the network"));
        p.Children.Add(Ui.Combo(new[] { ("Ask for each new device", "ask"), ("Allow every device on the local network", "always"), ("Nobody — only this PC", "never") },
            state.Settings.RemoteAccess, v => { state.Settings.RemoteAccess = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Text("Devices from the internet are never allowed, and other devices cannot reach this PC's localhost through Snifix.", 11, "#8D879C"));
        var approved = Ui.Column(4);
        void FillApproved()
        {
            approved.Children.Clear();
            foreach (var address in state.Settings.ApprovedClients.ToList())
            {
                var remove = Ui.Button("Remove", () => { state.RemoveApprovedDevice(address); FillApproved(); });
                approved.Children.Add(Ui.Row(Ui.Text("✓ " + address, 12, "#FFCC33"), remove));
            }
        }
        FillApproved();
        p.Children.Add(approved);
        p.Children.Add(Ui.Label("HTTPS"));
        p.Children.Add(Ui.Check("Decrypt HTTPS", state.Settings.DecryptHttps, v => { state.Settings.DecryptHttps = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Check("Verify server certificates (turn off for test servers with self-signed certificates)", state.Settings.VerifyServerCertificates,
            v => { state.Settings.VerifyServerCertificates = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Check("HTTP/2 with apps and servers", state.Settings.Http2, v => { state.Settings.Http2 = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Check("Bypass hosts that pin certificates", state.Settings.AutoBypassPinned, v => { state.Settings.AutoBypassPinned = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Text("HTTPS settings apply after restarting Snifix.", 11, "#8D879C"));
        p.Children.Add(Ui.Label("Files"));
        p.Children.Add(Ui.Text($"Rules, settings and the certificate are stored in {state.DataDirectory}", 11.5, "#8D879C"));
        return Ui.Card(p);
    }

    Control PhoneCard(bool android)
    {
        var p = Ui.Column(8);
        p.Children.Add(new TextBlock { Text = android ? "Android" : "iPhone / iPad", FontSize = 18, FontWeight = FontWeight.SemiBold });
        var steps = Ui.Column(2);
        steps.Children.Add(Step(1, $"{(android ? "Phone" : "iPhone")} and this PC are on the same Wi-Fi network — no cable needed."));
        steps.Children.Add(Step(2, android
            ? "Wi-Fi → your network → ✎ / Advanced → Proxy → Proxy Auto-Config, PAC URL:"
            : "Settings → Wi-Fi → (i) → Configure Proxy → Automatic, URL:"));
        steps.Children.Add(CopyField(state.PacUrl));
        steps.Children.Add(Ui.Text($"On public or office Wi-Fi set the proxy manually instead — server {state.LocalAddress}, port {state.Settings.Port}: the automatic setting comes over plain Wi-Fi and could be faked there.", 11, "#FF9A1F"));
        if (android) steps.Children.Add(Ui.Text($"Or Manual: host {state.LocalAddress}, port {state.Settings.Port} — then switch it back to None when Snifix is not running.", 11, "#8D879C"));
        steps.Children.Add(Step(3, android
            ? "Scan the QR code (or open http://snifix.cert in Chrome on the phone) and download the certificate. Then Settings → Security → Encryption & credentials → Install a certificate → CA certificate."
            : "Scan the QR code and download the certificate (or open http://snifix.cert in Safari)."));
        if (!android)
        {
            steps.Children.Add(Step(4, "Settings → General → VPN & Device Management → Snifix CA → Install."));
            steps.Children.Add(Step(5, "General → About → Certificate Trust Settings → turn on Snifix CA. Without this step HTTPS is not decrypted. “Not Verified” on the profile is normal."));
        }
        else steps.Children.Add(Step(4, "Android 7+ trusts user certificates only if the app allows it (network_security_config). Ask the developers to add <certificates src=\"user\"/> to the QA build."));
        var qr = new Border { Background = Brushes.White, CornerRadius = new CornerRadius(14), Padding = new Thickness(8), Child = Qr(state.CertificatePageUrl), VerticalAlignment = VerticalAlignment.Top };
        var row = new DockPanel();
        DockPanel.SetDock(qr, Dock.Left);
        row.Children.Add(qr);
        steps.Margin = new Thickness(18, 0, 0, 0);
        row.Children.Add(steps);
        p.Children.Add(row);
        p.Children.Add(Ui.Card(FingerprintBox(android)));
        p.Children.Add(Ui.Label("When to capture phones"));
        p.Children.Add(Ui.Combo(new[] { ("Always while Snifix is running", "always"), ("Never (the PAC says DIRECT)", "off") }, state.Settings.PhoneMode,
            v => { state.Settings.PhoneMode = v; state.SaveSettings(); }));
        p.Children.Add(Ui.Text("Set “Automatic” once. When Snifix is closed or the PC is off, the phone goes online directly. Allow Snifix in Windows Firewall when Windows asks, otherwise phones cannot connect.", 11, "#8D879C"));
        return Ui.Card(p);
    }
}

public sealed class DonateWindow : Window
{
    public DonateWindow()
    {
        Title = "Support Snifix";
        Width = 420; Height = 590; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var p = new StackPanel { Spacing = 14, Margin = new Thickness(26), HorizontalAlignment = HorizontalAlignment.Center };
        var cat = new Image { Source = new Bitmap(AssetLoader.Open(new Uri("avares://Snifix/Assets/cat.png"))), Width = 150, Height = 150,
                              RenderTransform = new ScaleTransform(0.6, 0.6), Opacity = 0 };
        cat.Transitions = new Transitions
        {
            new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(450) },
            new TransformOperationsTransition { Property = RenderTransformProperty, Duration = TimeSpan.FromMilliseconds(550), Easing = new Avalonia.Animation.Easings.BackEaseOut() },
        };
        p.Children.Add(cat);
        p.Children.Add(new TextBlock { Text = "☕  Support Snifix", FontSize = 20, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        p.Children.Add(new TextBlock
        {
            Text = "Donations are completely optional.\nSnifix is free and stays free — but a coffee makes the author happy.",
            TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Color.Parse("#8D879C")), FontSize = 12.5,
        });
        p.Children.Add(Card("VISA", "4916 9903 0007 3175", "#1A3390", "#2E6BD9"));
        p.Children.Add(Card("Mastercard", "5321 5400 1305 0170", "#29242F", "#524760"));
        var close = Ui.Button("Close", Close);
        close.HorizontalAlignment = HorizontalAlignment.Center;
        p.Children.Add(close);
        Content = p;
        Opened += (_, _) => { cat.Opacity = 1; cat.RenderTransform = new ScaleTransform(1, 1); };
    }

    Control Card(string brand, string number, string from, string to)
    {
        var left = new StackPanel { Spacing = 6 };
        left.Children.Add(new SelectableTextBlock { Text = number, FontSize = 17, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White,
                                                    FontFamily = new FontFamily("Cascadia Mono, Consolas, Menlo, monospace") });
        left.Children.Add(new TextBlock { Text = "MAVLONOV UMIDJON", FontSize = 10.5, LetterSpacing = 1.2, Foreground = new SolidColorBrush(Color.FromArgb(190, 255, 255, 255)) });
        Control mark = brand == "VISA"
            ? new TextBlock { Text = "VISA", FontSize = 17, FontWeight = FontWeight.Heavy, FontStyle = FontStyle.Italic, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Right }
            : new Canvas
            {
                Width = 32, Height = 20, HorizontalAlignment = HorizontalAlignment.Right,
                Children =
                {
                    new Avalonia.Controls.Shapes.Ellipse { Width = 20, Height = 20, Fill = new SolidColorBrush(Color.Parse("#EB001B")) },
                    new Avalonia.Controls.Shapes.Ellipse { Width = 20, Height = 20, Fill = new SolidColorBrush(Color.Parse("#E6F79E1B")), [Canvas.LeftProperty] = 12.0 },
                },
            };
        var copy = Ui.Button("Copy", () => { }, gold: true);
        copy.Click += async (_, _) =>
        {
            if (Clipboard != null) await Clipboard.SetTextAsync(number.Replace(" ", ""));
            copy.Content = "Copied ✓";
            await Task.Delay(1400);
            copy.Content = "Copy";
        };
        var right = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(mark);
        right.Children.Add(copy);
        var row = new DockPanel();
        DockPanel.SetDock(right, Dock.Right);
        row.Children.Add(right);
        row.Children.Add(left);
        return new Border
        {
            Width = 360, Padding = new Thickness(14), CornerRadius = new CornerRadius(14), Child = row,
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.Parse(from), 0), new GradientStop(Color.Parse(to), 1) },
            },
            BorderBrush = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255)), BorderThickness = new Thickness(1),
        };
    }
}

/// SNIFIX_SNAPSHOT=dir saves PNGs of the open windows (for checking the UI without a screen recorder).
static class Snapshot
{
    public static void Schedule(Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime desktop)
    {
        var dir = Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT");
        if (dir == null) return;
        var delay = double.TryParse(Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT_DELAY"), out var d) ? d : 6;
        Avalonia.Threading.DispatcherTimer.RunOnce(() =>
        {
            var main = (MainWindow)desktop.MainWindow!;
            foreach (var w in (Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT_WINDOWS") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
            {
                if (w == "rules") RulesWindow.Open(main, Enum.TryParse<RuleKind>(Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT_KIND") ?? "mapLocal", out var k) ? k : RuleKind.mapLocal,
                    AppState.Shared.Rules.Rules.FirstOrDefault(r => r.Id.ToString().Equals(Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT_RULE"), StringComparison.OrdinalIgnoreCase))?.Id
                    ?? AppState.Shared.Rules.Rules.FirstOrDefault(r => r.Kind == k)?.Id);
                if (w == "compose") ComposeWindow.Open(main, AppState.Shared.Visible.FirstOrDefault(f => f.Method == "POST") ?? AppState.Shared.Visible.FirstOrDefault());
                if (w == "devices") DevicesWindow.Open(main);
                if (w == "donate") new DonateWindow().Show(main);
            }
            main.SelectForSnapshot();
            Avalonia.Threading.DispatcherTimer.RunOnce(() =>
            {
                foreach (var win in desktop.Windows)
                {
                    var size = new PixelSize((int)win.ClientSize.Width * 2, (int)win.ClientSize.Height * 2);
                    using var rtb = new RenderTargetBitmap(size, new Vector(192, 192));
                    rtb.Render(win);
                    rtb.Save(Path.Combine(dir, (string.IsNullOrEmpty(win.Title) ? "window" : win.Title) + ".png"));
                }
                if (Environment.GetEnvironmentVariable("SNIFIX_SNAPSHOT_QUIT") != null) desktop.Shutdown();
            }, TimeSpan.FromSeconds(1.5));
        }, TimeSpan.FromSeconds(delay));
    }
}
