using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Titanium.Web.Proxy;
using Titanium.Web.Proxy.EventArguments;
using Titanium.Web.Proxy.Http;
using Titanium.Web.Proxy.Models;
using Titanium.Web.Proxy.Network;

namespace Snifix.Core;

public sealed class ProxySettings
{
    public int Port { get; set; } = 9090;
    public bool DecryptHttps { get; set; } = true;
    public bool VerifyServerCertificates { get; set; } = true;
    public bool AutoBypassPinned { get; set; } = true;
    public bool Http2 { get; set; } = true;
    public bool CaptureOnLaunch { get; set; } = true;
    /// "always" — phones using the PAC address go through Snifix; "off" — the PAC says DIRECT.
    public string PhoneMode { get; set; } = "always";
    public int MaxFlows { get; set; } = 20000;
    /// Memory for stored request and response bodies; older bodies are removed above it.
    public int BodyMemoryMb { get; set; } = 1024;
    /// Who else on the network may use the proxy: "ask" for each new device, "always" on the local network, or "never".
    public string RemoteAccess { get; set; } = "ask";
    /// Addresses of devices the user allowed. Locked while read or changed: proxy threads read it.
    public List<string> ApprovedClients { get; set; } = new();
    /// When each address was allowed; after 30 days the device is asked about again.
    public Dictionary<string, DateTime> ApprovedAt { get; set; } = new();
}

/// Request and response bodies held by all sessions together while they are received, processed and sent (1 GB),
/// and by one other device (256 MB), so parallel uploads or downloads cannot use up the computer's memory and one
/// device cannot block the rest. A session that never reaches AfterResponse gives its share back after 10 minutes.
public static class TransferBudget
{
    public static long Limit { get; set; } = 1L << 30;
    public const long DeviceShare = 256L << 20;
    static readonly object Gate = new();
    static long total;
    static readonly Dictionary<string, long> ByDevice = new();
    static readonly Dictionary<Flow, DateTime> Holders = new();
    static readonly Timer Sweeper = new(_ => Sweep(), null, TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));

    public static long Held { get { lock (Gate) return total; } }

    /// Makes the flow hold `bytes` in all; false (and nothing more taken) when a limit would be passed.
    public static bool Ensure(Flow flow, long bytes)
    {
        lock (Gate)
        {
            var more = bytes - flow.BudgetHeld;
            if (more <= 0) return true;
            if (total + more > Limit) return false;
            if (flow.BudgetDevice is string d)
            {
                if (ByDevice.GetValueOrDefault(d) + more > DeviceShare) return false;
                ByDevice[d] = ByDevice.GetValueOrDefault(d) + more;
            }
            total += more;
            flow.BudgetHeld = bytes;
            Holders[flow] = DateTime.UtcNow;
            return true;
        }
    }

    public static void Release(Flow flow)
    {
        lock (Gate)
        {
            if (flow.BudgetHeld == 0) return;
            total = Math.Max(0, total - flow.BudgetHeld);
            if (flow.BudgetDevice is string d)
            {
                var left = ByDevice.GetValueOrDefault(d) - flow.BudgetHeld;
                if (left > 0) ByDevice[d] = left; else ByDevice.Remove(d);
            }
            flow.BudgetHeld = 0;
            Holders.Remove(flow);
        }
    }

    public static string Busy(Flow flow)
    {
        lock (Gate)
            return flow.BudgetDevice is string d && ByDevice.GetValueOrDefault(d) >= DeviceShare / 2
                ? "this device already has 256 MB of bodies in transfer through Snifix. Try again in a moment."
                : "Snifix is already holding 1 GB of bodies in transfer for all devices together. Try again in a moment.";
    }

    static void Sweep()
    {
        List<Flow> stale;
        lock (Gate) stale = Holders.Where(h => DateTime.UtcNow - h.Value > TimeSpan.FromMinutes(10)).Select(h => h.Key).ToList();
        foreach (var f in stale) Release(f);
    }
}

/// The proxy: decrypts HTTPS, applies the rules and reports every request as a Flow.
public sealed class ProxyEngine : IDisposable
{
    public string DataDirectory { get; }
    public ProxySettings Settings { get; set; }
    public RulesDocument Rules { get; set; }
    public bool Recording { get; set; } = true;
    public X509Certificate2 RootCertificate => server.CertificateManager.RootCertificate!;
    public string RootCertificateName => server.CertificateManager.RootCertificateName;
    public bool IsRunning => server.ProxyRunning;
    public bool SystemProxyEnabled { get; private set; }

    public event Action<Flow>? FlowStarted;
    public event Action<Flow>? FlowUpdated;
    public event Action<string>? ScriptLog;

    readonly ProxyServer server;
    ExplicitProxyEndPoint? endPoint;
    int nextId;
    readonly ScriptRunner scripts;

    static readonly HashSet<string> MagicHosts = new(StringComparer.OrdinalIgnoreCase) { "snifix.cert", "cert.snifix", "snifix.local", "snifix" };

    public ProxyEngine(string dataDirectory, ProxySettings settings, RulesDocument rules)
    {
        DataDirectory = dataDirectory;
        Settings = settings;
        Rules = rules;
        Directory.CreateDirectory(dataDirectory);
        scripts = new ScriptRunner(line => ScriptLog?.Invoke(line));

        server = new ProxyServer(false, false, false);
        var cm = server.CertificateManager;
        CertificateManager.SuppressInteractiveRootStoreMutations = true;
        cm.RootCertificateName = Environment.GetEnvironmentVariable("SNIFIX_HOME") != null
            ? "Snifix Test CA (not for phones)" : $"Snifix CA ({Environment.MachineName})";
        cm.RootCertificateIssuerName = "Snifix";
        cm.PfxFilePath = Path.Combine(dataDirectory, "snifix-ca.pfx");
        cm.CertificateEngine = CertificateEngine.BouncyCastle;
        var created = KeyVault.PreparePfx(dataDirectory, cm.PfxFilePath, out var password);
        cm.PfxPassword = password;
        if (!created && File.Exists(cm.PfxFilePath)) cm.LoadRootCertificate();
        if (cm.RootCertificate == null) cm.CreateRootCertificate(true);
        File.WriteAllText(Path.Combine(dataDirectory, "snifix-ca.pem"), cm.RootCertificate!.ExportCertificatePem());

        server.BeforeRequest += OnRequest;
        server.BeforeResponse += OnResponse;
        server.AfterResponse += OnAfterResponse;
    }

    public void Start()
    {
        server.EnableHttp2 = Settings.Http2;
        server.IgnoreServerCertificateErrors = !Settings.VerifyServerCertificates;
        server.EnableDecryptFailureBypass = Settings.AutoBypassPinned;
        server.MaxBufferedBodyBytes = 256 * 1024 * 1024;
        // No TLS older than 1.2 with apps or servers; clients that never send their request are dropped
        server.SupportedSslProtocols = System.Security.Authentication.SslProtocols.Tls12 | System.Security.Authentication.SslProtocols.Tls13;
        server.SupportedServerSslProtocols = System.Security.Authentication.SslProtocols.Tls12 | System.Security.Authentication.SslProtocols.Tls13;
        server.ClientHeaderTimeoutSeconds = 15;

        endPoint = new ExplicitProxyEndPoint(IPAddress.Any, Settings.Port, Settings.DecryptHttps);
        endPoint.BeforeTunnelConnectRequest += OnTunnel;
        server.AddEndPoint(endPoint);
        server.Start(false);
    }

    public void Restart()
    {
        if (SystemProxyEnabled) SetSystemProxy(false);
        server.Stop();
        if (endPoint != null) server.RemoveEndPoint(endPoint);
        Start();
    }

    // MARK: - Windows integration

    string MarkerFile => Path.Combine(DataDirectory, "system-proxy-on");

    /// Points Windows at Snifix; the previous settings come back on exit (and after a crash, at the next start).
    public void SetSystemProxy(bool on)
    {
        if (!OperatingSystem.IsWindows() || endPoint == null) { SystemProxyEnabled = on; return; }
        if (on)
        {
            server.SetAsSystemProxy(endPoint, ProxyProtocolType.AllHttp);
            File.WriteAllText(MarkerFile, "1");
        }
        else
        {
            server.TryRestoreOriginalProxySettings();
            if (File.Exists(MarkerFile)) File.Delete(MarkerFile);
        }
        SystemProxyEnabled = on;
    }

    public void RecoverSystemProxy()
    {
        if (OperatingSystem.IsWindows() && File.Exists(MarkerFile))
        {
            server.TryDisableAllSystemProxies();
            File.Delete(MarkerFile);
        }
    }

    public bool IsCertificateTrusted()
    {
        if (!OperatingSystem.IsWindows()) return false;
        using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadOnly);
        return store.Certificates.Find(X509FindType.FindByThumbprint, RootCertificate.Thumbprint, false).Count > 0;
    }

    /// Adds only the public certificate to the user's trusted roots (Windows asks to confirm).
    /// The private key stays in the encrypted PFX and is never put into a Windows certificate store.
    public string? TrustCertificate()
    {
        if (!OperatingSystem.IsWindows()) return "Installing the certificate works on Windows only.";
        try
        {
            using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadWrite);
            store.Add(X509CertificateLoader.LoadCertificate(RootCertificate.RawData));
            return IsCertificateTrusted() ? null : "Windows did not trust the certificate.";
        }
        catch (Exception ex) { return ex.Message; }
    }

    /// Removes this CA from the trusted roots and deletes its files; a new one is made at the next start.
    public void ForgetCertificate()
    {
        if (OperatingSystem.IsWindows())
        {
            try
            {
                using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
                store.Open(OpenFlags.ReadWrite);
                foreach (var c in store.Certificates.Find(X509FindType.FindByThumbprint, RootCertificate.Thumbprint, false)) store.Remove(c);
            }
            catch { }
        }
        foreach (var name in new[] { "snifix-ca.pfx", "snifix-ca.key", "snifix-ca.pem" })
            try { File.Delete(Path.Combine(DataDirectory, name)); } catch { }
    }

    public static string PrimaryAddress()
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()
                         .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                         .OrderBy(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 0 : n.NetworkInterfaceType == NetworkInterfaceType.Ethernet ? 1 : 2))
            {
                if (ni.GetIPProperties().GatewayAddresses.Count == 0) continue;
                var a = ni.GetIPProperties().UnicastAddresses.FirstOrDefault(u => u.Address.AddressFamily == AddressFamily.InterNetwork);
                if (a != null) return a.Address.ToString();
            }
        }
        catch { }
        return "127.0.0.1";
    }

    static HashSet<string> LocalAddresses()
    {
        var set = new HashSet<string> { "127.0.0.1", "::1", "localhost" };
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                foreach (var u in ni.GetIPProperties().UnicastAddresses) set.Add(u.Address.ToString());
        }
        catch { }
        return set;
    }

    // MARK: - Who may use the proxy

    const string NotAllowed = "this device is not allowed to use the proxy. Allow it in Snifix on the computer (a banner appears there), then try again.";
    readonly HashSet<string> denied = new(), asked = new();
    /// Called once per unknown device that tries to use the proxy while access is "ask".
    public event Action<string, string?>? AccessRequested;

    static IPAddress? Remote(SessionEventArgsBase e)
    {
        var a = e.ClientRemoteEndPoint?.Address;
        return a != null && a.IsIPv4MappedToIPv6 ? a.MapToIPv4() : a;
    }

    static bool IsLocalClient(SessionEventArgsBase e) =>
        Remote(e) is IPAddress a && (IPAddress.IsLoopback(a) || LocalAddresses().Contains(a.ToString()));

    public static bool IsPrivate(IPAddress a)
    {
        if (a.AddressFamily == AddressFamily.InterNetworkV6) return a.IsIPv6LinkLocal || a.IsIPv6UniqueLocal || IPAddress.IsLoopback(a);
        var b = a.GetAddressBytes();
        return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
               || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
    }

    /// Whether the host leads to this computer's loopback: by name, by any way of writing the IP
    /// (2130706433, 0x7f000001, ::ffff:127.0.0.1) or by what the name resolves to (127.0.0.1.nip.io).
    public static bool IsLoopback(string host)
    {
        var h = host.ToLowerInvariant().Trim('[', ']');
        if (h == "localhost" || h.EndsWith(".localhost")) return true;
        IPAddress[] addresses;
        if (IPAddress.TryParse(h, out var literal)) addresses = new[] { literal };
        else
        {
            try { addresses = Dns.GetHostAddresses(h); }
            catch { return false; }
        }
        return addresses.Any(a => IPAddress.IsLoopback(a.IsIPv4MappedToIPv6 ? a.MapToIPv4() : a) || a.Equals(IPAddress.Any) || a.Equals(IPAddress.IPv6Any));
    }

    /// This computer always may; other devices must be on the local network and, in "ask" mode, allowed by the user.
    bool Allows(SessionEventArgsBase e)
    {
        if (IsLocalClient(e)) return true;
        if (Remote(e) is not IPAddress a || !IsPrivate(a)) return false;
        var address = a.ToString();
        switch (Settings.RemoteAccess)
        {
            case "always": return true;
            case "never": return false;
        }
        lock (Settings.ApprovedClients)
        {
            if (Settings.ApprovedClients.Contains(address)
                && Settings.ApprovedAt.TryGetValue(address, out var at) && DateTime.UtcNow - at < TimeSpan.FromDays(30)) return true;
        }
        bool first;
        lock (asked) { first = !denied.Contains(address) && asked.Add(address); }
        if (first) AccessRequested?.Invoke(address, Clients.DeviceName(e.HttpClient.Request.Headers.GetFirstHeader("User-Agent")?.Value));
        return false;
    }

    public void DenyClient(string address) { lock (asked) denied.Add(address); }
    public void ForgetClient(string address) { lock (asked) { denied.Remove(address); asked.Remove(address); } }

    static void Refuse(SessionEventArgs e, string message, HttpStatusCode status = HttpStatusCode.Forbidden) =>
        e.GenericResponse(Encoding.UTF8.GetBytes($"Snifix: {message}\n"), status,
            new Dictionary<string, HttpHeader> { ["Content-Type"] = new("Content-Type", "text/plain; charset=utf-8") }, true);

    bool SignedBySnifix(X509Certificate cert)
    {
        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(RootCertificate);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        return chain.Build(new X509Certificate2(cert));
    }

    /// SHA-256 of the certificate, as iOS and Android show it in the certificate details.
    public string Fingerprint => string.Join(" ", System.Security.Cryptography.SHA256.HashData(RootCertificate.RawData).Select(b => b.ToString("X2")));

    // MARK: - Tunnels

    Task OnTunnel(object sender, TunnelConnectSessionEventArgs e)
    {
        var host = e.HttpClient.Request.RequestUri.Host;
        if (!Allows(e) || (!IsLocalClient(e) && IsLoopback(host)))
        {
            e.DenyConnect = true;
            return Task.CompletedTask;
        }
        if (!Settings.DecryptHttps || HostMatch.Matches(host, Rules.SslBypass) ||
            (Rules.AllowListEnabled && !HostMatch.Matches(host, Rules.AllowList)))
        {
            e.DecryptSsl = false;
            if (ShouldRecord(host))
            {
                var flow = NewFlow(e, "CONNECT", $"https://{host}:{e.HttpClient.Request.RequestUri.Port}/");
                flow.State = FlowState.Tunnel;
                flow.Completed = DateTime.Now;
                FlowStarted?.Invoke(flow);
            }
        }
        return Task.CompletedTask;
    }

    bool ShouldRecord(string host) => Recording && (!Rules.AllowListEnabled || HostMatch.Matches(host, Rules.AllowList));

    Flow NewFlow(SessionEventArgsBase e, string method, string url)
    {
        var uri = new Uri(url);
        var request = e.HttpClient.Request;
        var flow = new Flow
        {
            Id = Interlocked.Increment(ref nextId),
            Method = method,
            Url = url,
            Scheme = uri.Scheme,
            Host = uri.Host,
            Path = uri.PathAndQuery,
            RequestVersion = request.HttpVersion.Major >= 2 ? "HTTP/2" : $"HTTP/{request.HttpVersion.Major}.{request.HttpVersion.Minor}",
            RequestHeaders = request.Headers.GetAllHeaders().Select(h => new HeaderItem(h.Name, h.Value)).ToList(),
        };
        var remote = e.ClientRemoteEndPoint?.Address;
        if (remote != null && remote.IsIPv4MappedToIPv6) remote = remote.MapToIPv4();
        flow.ClientAddress = remote?.ToString() ?? "?";
        flow.IsLocal = remote != null && (IPAddress.IsLoopback(remote) || LocalAddresses().Contains(flow.ClientAddress));
        var ua = flow.RequestHeader("User-Agent");
        if (flow.IsLocal)
        {
            flow.DeviceName = "This PC";
            ResolveProcess(e, flow);
        }
        flow.AppName = string.IsNullOrEmpty(flow.AppName) ? Clients.AppName(ua) ?? flow.ClientAddress : flow.AppName;
        if (!flow.IsLocal) flow.DeviceName = Clients.DeviceName(ua) ?? "Device";
        return flow;
    }

    static void ResolveProcess(SessionEventArgsBase e, Flow flow)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            var pid = e.HttpClient.ProcessId.Value;
            if (pid <= 0) return;
            using var p = Process.GetProcessById(pid);
            flow.AppName = p.ProcessName;
            flow.AppPath = p.MainModule?.FileName;
            var desc = p.MainModule?.FileVersionInfo.FileDescription;
            if (!string.IsNullOrWhiteSpace(desc) && desc.Length < 40) flow.AppName = desc;
        }
        catch { }
    }

    // MARK: - Requests

    async Task OnRequest(object sender, SessionEventArgs e)
    {
        var request = e.HttpClient.Request;
        var uri = request.RequestUri;
        if (LocalEndpoint(e, uri)) return;
        // Inside a decrypted tunnel the client was already checked at CONNECT
        if (!e.IsHttps && !Allows(e)) { Refuse(e, NotAllowed); return; }
        if (!IsLocalClient(e) && IsLoopback(uri.Host)) { Refuse(e, "other devices cannot reach this computer's localhost."); return; }

        var flow = NewFlow(e, request.Method, uri.ToString());
        e.UserData = flow;
        if (request.HasBody)
        {
            // Bodies of all devices share one budget: past it the request is answered with 503 instead of read
            flow.BudgetDevice = IsLocalClient(e) ? null : Remote(e)?.ToString();
            if (!TransferBudget.Ensure(flow, Math.Max(request.ContentLength, 0))) { Refuse(e, TransferBudget.Busy(flow), HttpStatusCode.ServiceUnavailable); return; }
            // A body that stops arriving frees the budget: 30 s plus the time 256 KB/s needs, or 2 minutes when the size is unknown
            var read = e.GetRequestBody();
            var allowed = request.ContentLength >= 0 ? TimeSpan.FromSeconds(30 + request.ContentLength / 262_144) : TimeSpan.FromMinutes(2);
            if (await Task.WhenAny(read, Task.Delay(allowed)) != read)
            {
                TransferBudget.Release(flow);
                _ = read.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
                e.TerminateSession();
                return;
            }
            try { flow.RequestBody = await read; }
            catch { TransferBudget.Release(flow); throw; }
            if (!TransferBudget.Ensure(flow, flow.RequestBody.Length))
            {
                flow.RequestBody = Array.Empty<byte>();
                Refuse(e, TransferBudget.Busy(flow), HttpStatusCode.ServiceUnavailable);
                return;
            }
        }
        var record = ShouldRecord(uri.Host);
        if (record) FlowStarted?.Invoke(flow);

        var doc = Rules;
        var block = doc.Active(RuleKind.block).FirstOrDefault(r => r.Matcher.Matches(flow.Method, flow.Url));
        if (block != null)
        {
            flow.Rules.Add(block.Name);
            if (block.BlockMode == BlockMode.dropConnection)
            {
                Fail(flow, $"Connection dropped by rule “{block.Name}”");
                e.TerminateSession();
                return;
            }
            var code = block.BlockMode == BlockMode.forbidden ? HttpStatusCode.Forbidden : HttpStatusCode.NotFound;
            e.GenericResponse(Encoding.UTF8.GetBytes("Blocked by Snifix"), code, new Dictionary<string, HttpHeader>
                { ["Content-Type"] = new("Content-Type", "text/plain; charset=utf-8") }, false);
            Complete(flow, (int)code, "Blocked", new() { new("Content-Type", "text/plain; charset=utf-8") }, Encoding.UTF8.GetBytes("Blocked by Snifix"));
            return;
        }

        var local = doc.Active(RuleKind.mapLocal).FirstOrDefault(r => r.Matcher.Matches(flow.Method, flow.Url));
        if (local != null)
        {
            flow.Rules.Add(local.Name);
            var (status, headers, body) = MapLocal.Response(local, flow);
            await Throttle(doc, flow, body.Length);
            var response = new Response(body) { StatusCode = status, StatusDescription = Reason(status), HttpVersion = request.HttpVersion };
            foreach (var h in headers) response.Headers.AddHeader(h.Name, h.Value);
            response.ContentLength = body.Length;
            e.Respond(response, false);
            flow.ResponseVersion = flow.RequestVersion;
            Complete(flow, status, Reason(status), headers, body);
            return;
        }

        foreach (var rule in doc.Active(RuleKind.script).Where(r => r.Matcher.Matches(flow.Method, flow.Url)))
        {
            flow.Rules.Add(rule.Name);
            var changed = scripts.RunRequest(rule, flow);
            if (changed != null) ApplyRequest(e, flow, changed.Value.method, changed.Value.url, changed.Value.headers, changed.Value.body);
        }

        var remote = doc.Active(RuleKind.mapRemote).FirstOrDefault(r => r.Matcher.Matches(flow.Method, flow.Url));
        if (remote != null)
        {
            flow.Rules.Add(remote.Name);
            var target = MapRemote(remote.MapRemote, new Uri(flow.Url));
            var headers = flow.RequestHeaders.ToList();
            if (!remote.MapRemote.PreserveHostHeader)
            {
                headers.RemoveAll(h => h.Name.Equals("Host", StringComparison.OrdinalIgnoreCase));
                headers.Add(new("Host", target.IsDefaultPort ? target.Host : $"{target.Host}:{target.Port}"));
            }
            ApplyRequest(e, flow, null, target.ToString(), headers, null);
        }

        foreach (var rule in doc.Active(RuleKind.rewrite).Where(r => r.Matcher.Matches(flow.Method, flow.Url)))
        {
            var steps = rule.Rewrite.Where(s => s.Target == RewriteTarget.request).ToList();
            if (steps.Count == 0) continue;
            flow.Rules.Add(rule.Name);
            var headers = flow.RequestHeaders.ToList();
            var url = flow.Url;
            byte[]? body = null;
            foreach (var s in steps)
            {
                switch (s.Operation)
                {
                    case RewriteOperation.setHeader: headers.RemoveAll(h => h.Name.Equals(s.Key, StringComparison.OrdinalIgnoreCase)); headers.Add(new(s.Key, s.Value)); break;
                    case RewriteOperation.removeHeader: headers.RemoveAll(h => h.Name.Equals(s.Key, StringComparison.OrdinalIgnoreCase)); break;
                    case RewriteOperation.setBody: body = Encoding.UTF8.GetBytes(s.Value); break;
                    case RewriteOperation.replaceBody: body = Encoding.UTF8.GetBytes(Replace(Encoding.UTF8.GetString(body ?? flow.RequestBody), s)); break;
                    case RewriteOperation.replaceURL: url = Replace(url, s); break;
                    case RewriteOperation.setQuery or RewriteOperation.removeQuery: url = SetQuery(url, s); break;
                }
            }
            ApplyRequest(e, flow, null, url, headers, body);
        }
        if (record) Updated(flow);
    }

    void ApplyRequest(SessionEventArgs e, Flow flow, string? method, string? url, List<HeaderItem>? headers, byte[]? body)
    {
        var request = e.HttpClient.Request;
        if (method != null && method != request.Method) { request.Method = method; flow.Method = method; }
        if (url != null && url != flow.Url)
        {
            request.Url = url;
            var u = new Uri(url);
            flow.Url = url; flow.Host = u.Host; flow.Path = u.PathAndQuery; flow.Scheme = u.Scheme;
        }
        if (headers != null)
        {
            request.Headers.Clear();
            foreach (var h in headers.Where(h => !h.Name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)))
                request.Headers.AddHeader(h.Name, h.Value);
            flow.RequestHeaders = headers;
        }
        if (body != null)
        {
            e.SetRequestBody(body);
            flow.RequestBody = body;
        }
    }

    static Uri MapRemote(MapRemoteAction a, Uri source)
    {
        var b = new UriBuilder(source);
        if (!string.IsNullOrEmpty(a.Scheme)) { b.Scheme = a.Scheme; b.Port = a.Port ?? -1; }
        if (!string.IsNullOrEmpty(a.Host)) { b.Host = a.Host; b.Port = a.Port ?? -1; }
        if (a.Port is int p) b.Port = p;
        if (!string.IsNullOrEmpty(a.Path)) b.Path = a.Path;
        return b.Uri;
    }

    static string Replace(string text, RewriteStep s) =>
        s.UseRegex ? Regex.Replace(text, s.Key, s.Value) : text.Replace(s.Key, s.Value);

    static string SetQuery(string url, RewriteStep s)
    {
        var b = new UriBuilder(url);
        var items = b.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(kv => !Uri.UnescapeDataString(kv.Split('=')[0]).Equals(s.Key)).ToList();
        if (s.Operation == RewriteOperation.setQuery) items.Add($"{Uri.EscapeDataString(s.Key)}={Uri.EscapeDataString(s.Value)}");
        b.Query = string.Join("&", items);
        return b.Uri.ToString();
    }

    // MARK: - Responses

    async Task OnResponse(object sender, SessionEventArgs e)
    {
        if (e.UserData is not Flow flow) return;
        var response = e.HttpClient.Response;
        var body = Array.Empty<byte>();
        if (response.HasBody)
        {
            if (!TransferBudget.Ensure(flow, flow.RequestBody.Length + Math.Max(response.ContentLength, 0)))
            {
                Fail(flow, TransferBudget.Busy(flow));
                Refuse(e, TransferBudget.Busy(flow), HttpStatusCode.ServiceUnavailable);
                return;
            }
            try { body = await e.GetResponseBody(); }
            catch { TransferBudget.Release(flow); throw; }
            if (!TransferBudget.Ensure(flow, flow.RequestBody.Length + body.Length))
            {
                Fail(flow, TransferBudget.Busy(flow));
                Refuse(e, TransferBudget.Busy(flow), HttpStatusCode.ServiceUnavailable);
                return;
            }
        }
        var headers = response.Headers.GetAllHeaders().Select(h => new HeaderItem(h.Name, h.Value)).ToList();
        var status = response.StatusCode;
        var changed = false;
        var doc = Rules;

        foreach (var rule in doc.Active(RuleKind.rewrite).Where(r => r.Matcher.Matches(flow.Method, flow.Url)))
        {
            var steps = rule.Rewrite.Where(s => s.Target == RewriteTarget.response).ToList();
            if (steps.Count == 0) continue;
            if (!flow.Rules.Contains(rule.Name)) flow.Rules.Add(rule.Name);
            foreach (var s in steps)
            {
                switch (s.Operation)
                {
                    case RewriteOperation.setHeader: headers.RemoveAll(h => h.Name.Equals(s.Key, StringComparison.OrdinalIgnoreCase)); headers.Add(new(s.Key, s.Value)); break;
                    case RewriteOperation.removeHeader: headers.RemoveAll(h => h.Name.Equals(s.Key, StringComparison.OrdinalIgnoreCase)); break;
                    case RewriteOperation.setBody: body = Encoding.UTF8.GetBytes(s.Value); break;
                    case RewriteOperation.replaceBody: body = Encoding.UTF8.GetBytes(Replace(Encoding.UTF8.GetString(body), s)); break;
                    case RewriteOperation.setStatus: if (int.TryParse(s.Value.Trim(), out var c)) status = c; break;
                }
            }
            changed = true;
        }
        foreach (var rule in doc.Active(RuleKind.script).Where(r => r.Matcher.Matches(flow.Method, flow.Url)))
        {
            var result = scripts.RunResponse(rule, flow, status, headers, body);
            if (result == null) continue;
            (status, headers, body) = result.Value;
            changed = true;
        }
        if (changed)
        {
            response.StatusCode = status;
            response.StatusDescription = Reason(status);
            response.Headers.Clear();
            foreach (var h in headers.Where(h => !h.Name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)
                                                 && !h.Name.Equals("Content-Encoding", StringComparison.OrdinalIgnoreCase)
                                                 && !h.Name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase)))
                response.Headers.AddHeader(h.Name, h.Value);
            e.SetResponseBody(body);
            headers.RemoveAll(h => h.Name.Equals("Content-Encoding", StringComparison.OrdinalIgnoreCase));
        }
        await Throttle(doc, flow, body.Length);
        flow.ResponseVersion = response.HttpVersion.Major >= 2 ? "HTTP/2" : $"HTTP/{response.HttpVersion.Major}.{response.HttpVersion.Minor}";
        flow.Trailers = response.TrailingHeaders.GetAllHeaders().Select(h => new HeaderItem(h.Name, h.Value)).ToList();
        Complete(flow, status, string.IsNullOrEmpty(response.StatusDescription) ? Reason(status) : response.StatusDescription, headers, body);
        // A client that stops reading is dropped: 30 s plus the time 256 KB/s needs for the body, then the budget comes back
        var sending = flow.BudgetHeld;
        _ = Task.Delay(TimeSpan.FromSeconds(30 + body.Length / 262_144)).ContinueWith(_ =>
        {
            if (flow.BudgetHeld == 0 || flow.BudgetHeld != sending) return;
            TransferBudget.Release(flow);
            try { e.TerminateSession(); } catch { }
        });
    }

    Task OnAfterResponse(object sender, SessionEventArgs e)
    {
        if (e.UserData is Flow done) TransferBudget.Release(done);
        if (e.UserData is Flow flow && flow.State == FlowState.Active)
        {
            if (e.Exception != null) Fail(flow, e.Exception.GetBaseException().Message);
            else { flow.State = FlowState.Completed; flow.Completed ??= DateTime.Now; Updated(flow); }
        }
        return Task.CompletedTask;
    }

    async Task Throttle(RulesDocument doc, Flow flow, int bytes)
    {
        var rule = doc.Active(RuleKind.throttle).FirstOrDefault(r => r.Matcher.Matches(flow.Method, flow.Url));
        if (rule == null) return;
        if (!flow.Rules.Contains(rule.Name)) flow.Rules.Add(rule.Name);
        double ms = rule.Throttle.LatencyMs;
        if (rule.Throttle.DownloadKbps > 0) ms += bytes * 8.0 / rule.Throttle.DownloadKbps;
        await Task.Delay(TimeSpan.FromMilliseconds(ms));
    }

    void Complete(Flow flow, int status, string reason, List<HeaderItem> headers, byte[] body)
    {
        flow.Reason = reason;
        flow.ResponseHeaders = headers;
        flow.ResponseBody = body;
        flow.Completed = DateTime.Now;
        flow.StatusCode = status;
        flow.State = FlowState.Completed;
        Updated(flow);
    }

    void Fail(Flow flow, string message)
    {
        flow.Error = message;
        flow.Completed = DateTime.Now;
        flow.State = FlowState.Failed;
        Updated(flow);
    }

    void Updated(Flow flow) => FlowUpdated?.Invoke(flow);

    public static string Reason(int code) => code switch
    {
        200 => "OK", 201 => "Created", 204 => "No Content", 301 => "Moved Permanently", 302 => "Found", 304 => "Not Modified",
        400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 409 => "Conflict", 422 => "Unprocessable Entity",
        429 => "Too Many Requests", 500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable",
        _ => Enum.IsDefined(typeof(HttpStatusCode), code) ? Regex.Replace(((HttpStatusCode)code).ToString(), "(?<!^)([A-Z])", " $1") : "",
    };

    // MARK: - Pages Snifix serves itself (certificate for phones, PAC file)

    bool LocalEndpoint(SessionEventArgs e, Uri uri)
    {
        var toProxy = (LocalAddresses().Contains(uri.Host) || uri.Host.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase))
                      && uri.Port == Settings.Port;
        if (!MagicHosts.Contains(uri.Host) && !toProxy) return false;
        var local = e.ClientLocalEndPoint?.Address;
        if (local != null && local.IsIPv4MappedToIPv6) local = local.MapToIPv4();
        var proxyHost = local == null || IPAddress.IsLoopback(local) || local.Equals(IPAddress.Any) ? PrimaryAddress() : local.ToString();
        var path = uri.AbsolutePath.ToLowerInvariant();
        switch (path)
        {
            case "/cert" or "/cert.crt" or "/cert.cer" or "/ssl":
                e.Ok(RootCertificate.Export(X509ContentType.Cert), new Dictionary<string, HttpHeader>
                {
                    ["Content-Type"] = new("Content-Type", "application/x-x509-ca-cert"),
                    ["Content-Disposition"] = new("Content-Disposition", "attachment; filename=\"Snifix-CA.crt\""),
                }, false);
                break;
            case "/cert.pem":
                e.Ok(Encoding.ASCII.GetBytes(RootCertificate.ExportCertificatePem()), new Dictionary<string, HttpHeader>
                {
                    ["Content-Type"] = new("Content-Type", "application/x-pem-file"),
                    ["Content-Disposition"] = new("Content-Disposition", "attachment; filename=\"Snifix-CA.pem\""),
                }, false);
                break;
            case "/proxy.pac" or "/pac" or "/wpad.dat":
                var rule = Settings.PhoneMode == "off" ? "DIRECT" : $"PROXY {proxyHost}:{Settings.Port}; DIRECT";
                var pac = "function FindProxyForURL(url, host) {\n" +
                          "  if (isPlainHostName(host) || shExpMatch(host, \"*.local\") || isInNet(dnsResolve(host), \"127.0.0.0\", \"255.0.0.0\")) return \"DIRECT\";\n" +
                          $"  return \"{rule}\";\n}}\n";
                e.Ok(Encoding.UTF8.GetBytes(pac), new Dictionary<string, HttpHeader>
                {
                    ["Content-Type"] = new("Content-Type", "application/x-ns-proxy-autoconfig"),
                    ["Cache-Control"] = new("Cache-Control", "no-cache, no-store, max-age=0"),
                }, false);
                break;
            default:
                e.Ok(Encoding.UTF8.GetBytes(CertificatePage.Html(proxyHost, Settings.Port, RootCertificateName)), new Dictionary<string, HttpHeader>
                {
                    ["Content-Type"] = new("Content-Type", "text/html; charset=utf-8"),
                }, false);
                break;
        }
        return true;
    }

    // MARK: - Replay (Edit & Send)

    /// Sends a request through Snifix itself so it shows up in the list and goes through the rules.
    public async Task<(int status, List<HeaderItem> headers, byte[] body, string? error)> Send(string method, string url, List<HeaderItem> headers, byte[] body)
    {
        var handler = new HttpClientHandler
        {
            Proxy = new WebProxy($"http://127.0.0.1:{Settings.Port}"),
            UseProxy = true,
            AutomaticDecompression = DecompressionMethods.All,
            // Requests go through this proxy, so the certificate must be one Snifix itself signed
            ServerCertificateCustomValidationCallback = (_, cert, _, errors) =>
                errors == System.Net.Security.SslPolicyErrors.None || (cert != null && SignedBySnifix(cert)),
        };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(120) };
        var message = new HttpRequestMessage(new HttpMethod(method), url);
        if (body.Length > 0 || method is "POST" or "PUT" or "PATCH") message.Content = new ByteArrayContent(body);
        foreach (var h in headers)
        {
            if (h.Name.Equals("Host", StringComparison.OrdinalIgnoreCase) || h.Name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
            if (!message.Headers.TryAddWithoutValidation(h.Name, h.Value)) message.Content?.Headers.TryAddWithoutValidation(h.Name, h.Value);
        }
        message.Headers.UserAgent.Clear();
        message.Headers.TryAddWithoutValidation("User-Agent", headers.FirstOrDefault(h => h.Name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase))?.Value ?? "Snifix");
        try
        {
            var r = await client.SendAsync(message);
            var data = await r.Content.ReadAsByteArrayAsync();
            var hs = r.Headers.Concat(r.Content.Headers).SelectMany(h => h.Value.Select(v => new HeaderItem(h.Key, v))).ToList();
            return ((int)r.StatusCode, hs, data, null);
        }
        catch (Exception ex) { return (0, new(), Array.Empty<byte>(), ex.GetBaseException().Message); }
    }

    public void Dispose()
    {
        try { if (SystemProxyEnabled) SetSystemProxy(false); } catch { }
        try { server.Stop(); } catch { }
        server.Dispose();
    }
}

static class MapLocal
{
    public static (int status, List<HeaderItem> headers, byte[] body) Response(Rule rule, Flow flow)
    {
        var a = rule.MapLocal;
        var headers = a.Headers.Select(h => new HeaderItem(h.Name, h.Value)).ToList();
        switch (a.Source)
        {
            case MapLocalSource.file:
            {
                var path = Expand(a.Path);
                if (!File.Exists(path)) return Missing(path);
                if (!headers.Any(h => h.Name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)))
                    headers.Add(new("Content-Type", Body.MimeType(System.IO.Path.GetExtension(path))));
                return (a.StatusCode, headers, File.ReadAllBytes(path));
            }
            case MapLocalSource.directory:
            {
                var file = FileInDirectory(rule, flow);
                if (file == null) return Missing(System.IO.Path.Combine(Expand(a.Path), Suffix(rule, flow)));
                headers.RemoveAll(h => h.Name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase));
                headers.Add(new("Content-Type", Body.MimeType(System.IO.Path.GetExtension(file))));
                return (a.StatusCode, headers, File.ReadAllBytes(file));
            }
            default:
                return (a.StatusCode, headers, Encoding.UTF8.GetBytes(a.Body));
        }
    }

    static string Expand(string p) => p.StartsWith("~") ? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), p.TrimStart('~', '/', '\\')) : p;

    /// Part of the request path after the static prefix of the pattern (up to its first `*`).
    static string Suffix(Rule rule, Flow flow)
    {
        var prefix = rule.Matcher.Pattern;
        var star = prefix.IndexOf('*');
        if (star >= 0) prefix = prefix[..star];
        var scheme = prefix.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) prefix = prefix[(scheme + 3)..];
        var slash = prefix.IndexOf('/');
        var prefixPath = slash >= 0 ? prefix[slash..] : "/";
        var path = flow.Path.Split('?')[0];
        if (path.StartsWith(prefixPath)) path = path[prefixPath.Length..];
        return Uri.UnescapeDataString(path.Trim('/'));
    }

    static string? FileInDirectory(Rule rule, Flow flow)
    {
        var dir = Expand(rule.MapLocal.Path);
        var rest = Suffix(rule, flow);
        if (rest.Contains("..") || rest.Contains(':') || rest.Contains('\\') || System.IO.Path.IsPathRooted(rest)) return null;
        var root = System.IO.Path.GetFullPath(dir);
        var full = System.IO.Path.GetFullPath(rest.Length == 0 ? dir : System.IO.Path.Combine(dir, rest.Replace('/', System.IO.Path.DirectorySeparatorChar)));
        // Absolute, drive or network paths from the URL, links and junctions must never leave the folder
        var realRoot = RealPath(root);
        bool Inside(string p)
        {
            var real = RealPath(p);
            return real.Equals(realRoot, StringComparison.OrdinalIgnoreCase)
                   || real.StartsWith(realRoot.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }
        if (!Inside(full)) return null;
        if (File.Exists(full)) return full;
        if (Directory.Exists(full))
            return new[] { "index.json", "index.html" }.Select(i => System.IO.Path.Combine(full, i)).FirstOrDefault(p => File.Exists(p) && Inside(p));
        return new[] { "json", "html", "txt", "xml" }.Select(ext => full + "." + ext).FirstOrDefault(p => File.Exists(p) && Inside(p));
    }

    /// The path with every symbolic link and junction on the way replaced by its target.
    static string RealPath(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        var root = System.IO.Path.GetPathRoot(full) ?? "";
        var current = root;
        foreach (var part in full[root.Length..].Split(System.IO.Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = System.IO.Path.Combine(current, part);
            FileSystemInfo info = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            if (info.Exists && info.LinkTarget != null && info.ResolveLinkTarget(true) is FileSystemInfo target)
                current = System.IO.Path.GetFullPath(target.FullName);
        }
        return current;
    }

    static (int, List<HeaderItem>, byte[]) Missing(string path) =>
        (404, new() { new("Content-Type", "text/plain; charset=utf-8") }, Encoding.UTF8.GetBytes($"Snifix Map Local: file not found\n{path}\n"));
}

public static class Clients
{
    /// "Octo%20Mobile/1.2 CFNetwork/..." → "Octo Mobile"; "okhttp/4.9" → "okhttp".
    public static string? AppName(string? ua)
    {
        if (string.IsNullOrEmpty(ua)) return null;
        var product = ua.Split(' ')[0].Split('/')[0];
        if (product == "Mozilla")
        {
            if (ua.Contains("Edg/")) return "Edge";
            if (ua.Contains("Chrome/")) return "Chrome";
            if (ua.Contains("Firefox/")) return "Firefox";
            if (ua.Contains("Safari/")) return "Safari";
            return "Browser";
        }
        var name = Uri.UnescapeDataString(product);
        return name.Length == 0 ? null : name;
    }

    public static string? DeviceName(string? ua)
    {
        if (ua == null) return null;
        var u = ua.ToLowerInvariant();
        if (u.Contains("ipad")) return "iPad";
        if (u.Contains("iphone") || u.Contains("ios") || u.Contains("cfnetwork") || u.Contains("darwin")) return "iPhone";
        if (u.Contains("android") || u.Contains("okhttp") || u.Contains("dalvik")) return "Android";
        if (u.Contains("windows")) return "Windows";
        return null;
    }
}

static class CertificatePage
{
    public static string Html(string host, int port, string rawName) => Page(host, port, System.Net.WebUtility.HtmlEncode(rawName));

    static string Page(string host, int port, string caName) => $$"""
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>Snifix — certificate</title>
        <style>
        :root{color-scheme:dark} body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:#0c0b10;color:#f2f0f7}
        main{max-width:560px;margin:0 auto;padding:28px 18px 48px}
        h1{font-size:28px;margin:0 0 4px;background:linear-gradient(90deg,#ffd84a,#ff9a1f);-webkit-background-clip:text;color:transparent}
        p{color:#b9b5c6;line-height:1.5}
        a.btn{display:block;text-align:center;margin:18px 0;padding:15px;border-radius:14px;font-weight:600;text-decoration:none;color:#1a1204;background:linear-gradient(180deg,#ffd84a,#ffae1f)}
        a.alt{background:#1d1b25;color:#ffcf3a;border:1px solid #3a3446}
        ol{padding-left:20px;color:#d9d5e4;line-height:1.6} .card{background:#16141d;border:1px solid #2a2633;border-radius:16px;padding:6px 18px;margin:18px 0}
        h2{font-size:17px;color:#ffcf3a} code{background:#221f2b;padding:2px 6px;border-radius:6px;color:#ffd84a}
        </style></head><body><main>
        <h1>Snifix</h1><p>The “{{caName}}” certificate lets Snifix decrypt this device's HTTPS traffic.</p>
        <a class="btn" href="/cert">Download Certificate</a>
        <div class="card"><h2>iPhone / iPad</h2><ol>
        <li>Tap Download Certificate, then Allow.</li>
        <li>Settings → General → VPN &amp; Device Management → Snifix CA → Install.</li>
        <li>Settings → General → About → Certificate Trust Settings → turn on Snifix CA.</li>
        <li>Wi‑Fi → (i) → Configure Proxy → Automatic: <code>http://{{host}}:{{port}}/proxy.pac</code></li></ol></div>
        <div class="card"><h2>Android</h2><ol>
        <li>Download the certificate.</li>
        <li>Settings → Security → Encryption &amp; credentials → Install a certificate → CA certificate.</li>
        <li>Wi‑Fi proxy: Proxy Auto-Config <code>http://{{host}}:{{port}}/proxy.pac</code>, or Manual <code>{{host}}</code> port <code>{{port}}</code>.</li></ol></div>
        <a class="btn alt" href="/cert.pem">Certificate as PEM</a>
        </main></body></html>
        """;
}
