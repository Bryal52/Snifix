using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Snifix.Core;

// Same JSON as the Mac app's rules.json, so rules can be exported on one and imported on the other.

public sealed class HeaderItem
{
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    public HeaderItem() { }
    public HeaderItem(string name, string value) { Name = name; Value = value; }
}

[JsonConverter(typeof(JsonStringEnumConverter<RuleKind>))]
public enum RuleKind { mapLocal, mapRemote, rewrite, breakpoint, block, throttle, script }

[JsonConverter(typeof(JsonStringEnumConverter<MapLocalSource>))]
public enum MapLocalSource { inline, file, directory }

[JsonConverter(typeof(JsonStringEnumConverter<RewriteTarget>))]
public enum RewriteTarget { request, response }

[JsonConverter(typeof(JsonStringEnumConverter<RewriteOperation>))]
public enum RewriteOperation { setHeader, removeHeader, replaceBody, setBody, setStatus, setQuery, removeQuery, replaceURL }

[JsonConverter(typeof(JsonStringEnumConverter<BlockMode>))]
public enum BlockMode { forbidden, notFound, dropConnection }

public sealed class RuleMatcher
{
    public string Pattern { get; set; } = "";
    public bool UseRegex { get; set; }
    public bool IncludeSubpaths { get; set; } = true;
    public List<string> Methods { get; set; } = new();

    public bool Matches(string method, string url)
    {
        if (Methods.Count > 0 && !Methods.Any(m => string.Equals(m, method, StringComparison.OrdinalIgnoreCase)))
            return false;
        // Plain patterns without a query are matched against the URL without its query
        var target = url;
        if (!UseRegex && !Pattern.Contains('?') && target.IndexOf('?') is var q and >= 0) target = target[..q];
        var re = PatternCache.Get(this);
        return re != null && re.IsMatch(target);
    }
}

static class PatternCache
{
    static readonly Dictionary<string, Regex?> Cache = new();

    public static Regex? Get(RuleMatcher m)
    {
        var key = $"{m.UseRegex}|{m.IncludeSubpaths}|{m.Pattern}";
        lock (Cache)
        {
            if (Cache.TryGetValue(key, out var r)) return r;
            string source;
            if (m.UseRegex) source = m.Pattern;
            else
            {
                var p = Regex.Escape(m.Pattern.Trim()).Replace("\\*", ".*");
                if (!m.Pattern.Contains("://")) p = "([a-z]+://)?" + p;
                if (m.IncludeSubpaths) p += "([/?#].*)?";
                source = "^" + p + "$";
            }
            try { r = new Regex(source, RegexOptions.IgnoreCase | RegexOptions.Compiled); } catch { r = null; }
            Cache[key] = r;
            return r;
        }
    }
}

public sealed class MapLocalAction
{
    public int StatusCode { get; set; } = 200;
    public List<HeaderItem> Headers { get; set; } = new() { new("Content-Type", "application/json; charset=utf-8") };
    public MapLocalSource Source { get; set; } = MapLocalSource.inline;
    public string Body { get; set; } = "";
    public string Path { get; set; } = "";
}

public sealed class MapRemoteAction
{
    public string Scheme { get; set; } = "";
    public string Host { get; set; } = "";
    public int? Port { get; set; }
    public string Path { get; set; } = "";
    public bool PreserveHostHeader { get; set; }
}

public sealed class RewriteStep
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public RewriteTarget Target { get; set; } = RewriteTarget.response;
    public RewriteOperation Operation { get; set; } = RewriteOperation.setHeader;
    public string Key { get; set; } = "";
    public string Value { get; set; } = "";
    public bool UseRegex { get; set; }
}

public sealed class ThrottleAction
{
    public int LatencyMs { get; set; } = 500;
    public int DownloadKbps { get; set; }
}

public sealed class Rule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "New Rule";
    public bool Enabled { get; set; } = true;
    public RuleKind Kind { get; set; }
    [JsonPropertyName("groupID")] public Guid? GroupId { get; set; }
    public RuleMatcher Matcher { get; set; } = new();
    public MapLocalAction MapLocal { get; set; } = new();
    public MapRemoteAction MapRemote { get; set; } = new();
    public List<RewriteStep> Rewrite { get; set; } = new();
    public bool BreakOnRequest { get; set; } = true;
    public bool BreakOnResponse { get; set; } = true;
    public BlockMode BlockMode { get; set; } = BlockMode.forbidden;
    public ThrottleAction Throttle { get; set; } = new();
    public string Script { get; set; } = DefaultScript;

    public const string DefaultScript =
        "// Called before the request goes to the server.\n" +
        "function onRequest(context, url, request) {\n" +
        "  // request.headers[\"X-Debug\"] = \"1\";\n" +
        "  return request;\n" +
        "}\n\n" +
        "// Called when the response arrives. A JSON body is already an object in response.body.\n" +
        "function onResponse(context, url, request, response) {\n" +
        "  // response.body.debug = true;\n" +
        "  return response;\n" +
        "}\n";

    public Rule Clone() => JsonSerializer.Deserialize<Rule>(JsonSerializer.Serialize(this, Json.Options), Json.Options)!;
}

public sealed class RuleGroup
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Group";
    public bool Enabled { get; set; } = true;
}

public sealed class DnsOverride
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public bool Enabled { get; set; } = true;
    public string Host { get; set; } = "";
    public string Address { get; set; } = "";
}

public sealed class RulesDocument
{
    public List<RuleGroup> Groups { get; set; } = new();
    public List<Rule> Rules { get; set; } = new();
    public List<string> SslBypass { get; set; } = new() { "*.microsoft.com", "*.windowsupdate.com", "*.apple.com", "*.icloud.com" };
    public bool AllowListEnabled { get; set; }
    public List<string> AllowList { get; set; } = new();
    public List<DnsOverride> DnsOverrides { get; set; } = new();

    /// Rules that are on and whose group (if any) is on, in list order.
    public IEnumerable<Rule> Active(RuleKind kind)
    {
        var off = Groups.Where(g => !g.Enabled).Select(g => g.Id).ToHashSet();
        return Rules.Where(r => r.Kind == kind && r.Enabled && !(r.GroupId is Guid g && off.Contains(g)));
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}

public static class HostMatch
{
    public static bool Matches(string host, IEnumerable<string> patterns)
    {
        var h = host.ToLowerInvariant();
        foreach (var raw in patterns)
        {
            var p = raw.Trim().ToLowerInvariant();
            if (p.Length == 0) continue;
            if (p.StartsWith("*."))
            {
                var b = p[2..];
                if (h == b || h.EndsWith("." + b)) return true;
            }
            else if (p.Contains('*'))
            {
                if (Regex.IsMatch(h, "^" + Regex.Escape(p).Replace("\\*", ".*") + "$")) return true;
            }
            else if (h == p) return true;
        }
        return false;
    }
}
