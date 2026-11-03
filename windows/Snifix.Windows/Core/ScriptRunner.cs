using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jint;

namespace Snifix.Core;

/// Runs Scripting rules (onRequest / onResponse) in Jint, with the same API as the Mac app.
public sealed class ScriptRunner
{
    readonly Action<string> log;
    public ScriptRunner(Action<string> log) => this.log = log;

    Engine? Make(Rule rule)
    {
        try
        {
            var engine = new Engine(o => o.TimeoutInterval(TimeSpan.FromSeconds(2)).LimitRecursion(256));
            engine.SetValue("__log", new Action<string>(line => log($"[{rule.Name}] {line}")));
            engine.Execute("""
                var console = { log: function () {
                  __log(Array.prototype.slice.call(arguments).map(function (a) {
                    return typeof a === 'object' ? JSON.stringify(a) : String(a); }).join(' ')); } };
                console.error = console.log;
                """);
            engine.Execute(rule.Script);
            return engine;
        }
        catch (Exception ex)
        {
            log($"[{rule.Name}] Error: {ex.Message}");
            return null;
        }
    }

    static JsonObject Message(string? method, string? url, List<HeaderItem> headers, byte[] body, string? encoding)
    {
        var o = new JsonObject();
        if (method != null) o["method"] = method;
        if (url != null) o["url"] = url;
        var h = new JsonObject();
        foreach (var header in headers) h[header.Name] = header.Value;
        o["headers"] = h;
        var text = Encoding.UTF8.GetString(Body.Decoded(body, encoding));
        JsonNode? json = null;
        if (text.Length > 0) { try { json = JsonNode.Parse(text); } catch { } }
        o["body"] = json ?? JsonValue.Create(text);
        return o;
    }

    static List<HeaderItem> Headers(JsonNode? node, List<HeaderItem> old)
    {
        if (node is not JsonObject h) return old;
        var result = new List<HeaderItem>();
        foreach (var (k, v) in h) result.Add(new HeaderItem(k, v is JsonValue jv && jv.TryGetValue<string>(out var s) ? s : v?.ToJsonString() ?? ""));
        return result;
    }

    /// New body bytes when the script changed the body, null when it stayed the same.
    static byte[]? NewBody(JsonNode? before, JsonNode? after)
    {
        if (JsonNode.DeepEquals(before, after)) return null;
        if (after is JsonValue v && v.TryGetValue<string>(out var s)) return Encoding.UTF8.GetBytes(s);
        return Encoding.UTF8.GetBytes(after?.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) ?? "");
    }

    JsonObject? Call(Engine engine, Rule rule, string function, params JsonNode[] args)
    {
        try
        {
            if (engine.GetValue(function).IsUndefined()) return null;
            for (int i = 0; i < args.Length; i++) engine.SetValue($"__a{i}", args[i].ToJsonString());
            var list = string.Join(", ", args.Select((_, i) => $"JSON.parse(__a{i})"));
            var name = JsonSerializer.Serialize(rule.Name);
            var result = engine.Evaluate($"JSON.stringify({function}({{ rule: {name} }}, {list}))");
            return result.IsString() ? JsonNode.Parse(result.AsString()) as JsonObject : null;
        }
        catch (Exception ex)
        {
            log($"[{rule.Name}] Error: {ex.Message}");
            return null;
        }
    }

    public (string method, string url, List<HeaderItem> headers, byte[]? body)? RunRequest(Rule rule, Flow flow)
    {
        var engine = Make(rule);
        if (engine == null) return null;
        var request = Message(flow.Method, flow.Url, flow.RequestHeaders, flow.RequestBody, flow.RequestHeader("Content-Encoding"));
        var before = request["body"]?.DeepClone();
        var r = Call(engine, rule, "onRequest", JsonValue.Create(flow.Url)!, request);
        if (r == null) return null;
        return (r["method"]?.GetValue<string>()?.ToUpperInvariant() ?? flow.Method,
                r["url"]?.GetValue<string>() ?? flow.Url,
                Headers(r["headers"], flow.RequestHeaders),
                NewBody(before, r["body"]));
    }

    public (int status, List<HeaderItem> headers, byte[] body)? RunResponse(Rule rule, Flow flow, int status, List<HeaderItem> headers, byte[] body)
    {
        var engine = Make(rule);
        if (engine == null) return null;
        var encoding = headers.FirstOrDefault(h => h.Name.Equals("Content-Encoding", StringComparison.OrdinalIgnoreCase))?.Value;
        var request = Message(flow.Method, flow.Url, flow.RequestHeaders, flow.RequestBody, flow.RequestHeader("Content-Encoding"));
        var response = Message(null, null, headers, body, encoding);
        response["statusCode"] = status;
        var before = response["body"]?.DeepClone();
        var r = Call(engine, rule, "onResponse", JsonValue.Create(flow.Url)!, request, response);
        if (r == null) return null;
        var newStatus = r["statusCode"] is JsonValue sv && sv.TryGetValue<int>(out var c) ? c : status;
        var newBody = NewBody(before, r["body"]);
        return (newStatus, Headers(r["headers"], headers), newBody ?? Body.Decoded(body, encoding));
    }
}
