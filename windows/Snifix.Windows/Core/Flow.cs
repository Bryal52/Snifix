using System.ComponentModel;
using System.IO.Compression;
using System.Runtime.CompilerServices;
using System.Text;

namespace Snifix.Core;

public enum FlowState { Active, Completed, Failed, Tunnel }

/// One request/response pair; updated from proxy threads, shown in the list on the UI thread.
public sealed class Flow : INotifyPropertyChanged
{
    public int Id { get; init; }
    public DateTime Started { get; init; } = DateTime.Now;
    public string Method { get; set; } = "GET";
    public string Url { get; set; } = "";
    public string Scheme { get; set; } = "https";
    public string Host { get; set; } = "";
    public string Path { get; set; } = "/";
    public string ClientAddress { get; set; } = "";
    public bool IsLocal { get; set; }
    public string AppName { get; set; } = "";
    public string? AppPath { get; set; }
    public string DeviceName { get; set; } = "";
    public string RequestVersion { get; set; } = "HTTP/1.1";
    public List<HeaderItem> RequestHeaders { get; set; } = new();
    public byte[] RequestBody { get; set; } = Array.Empty<byte>();

    int status;
    public int StatusCode { get => status; set { status = value; Changed(); Changed(nameof(StatusText)); } }
    public string Reason { get; set; } = "";
    public string ResponseVersion { get; set; } = "";
    public List<HeaderItem> ResponseHeaders { get; set; } = new();
    public byte[] ResponseBody { get; set; } = Array.Empty<byte>();
    public List<HeaderItem> Trailers { get; set; } = new();

    FlowState state;
    public FlowState State { get => state; set { state = value; Changed(); Changed(nameof(StatusText)); Changed(nameof(StatusColor)); } }
    public string Error { get; set; } = "";
    public DateTime? Completed { get; set; }
    public List<string> Rules { get; } = new();
    public bool IsHttps => Scheme == "https";
    /// Bytes this flow holds of the transfer budget, and the other device they count against (null: this computer).
    public long BudgetHeld { get; set; }
    public string? BudgetDevice { get; set; }

    public string DeviceKey => IsLocal ? "This PC" : ClientAddress;
    public string StatusText => State switch
    {
        FlowState.Failed => "Error",
        FlowState.Tunnel => "Tunnel",
        FlowState.Active => "…",
        _ => StatusCode.ToString(),
    };
    public string StatusColor => State == FlowState.Failed ? "#FF5A52" : StatusCode switch
    {
        >= 500 => "#FF5A52", >= 400 => "#FF9A1F", >= 300 => "#4CC9F0", >= 200 => "#4ADE80", _ => "#8A8595",
    };
    public string MethodColor => Method switch
    {
        "GET" => "#FFCC33", "POST" => "#4ADE80", "PUT" or "PATCH" => "#4CC9F0", "DELETE" => "#FF5A52", "CONNECT" => "#8A8595", _ => "#C084FC",
    };
    public string Protocol
    {
        get
        {
            if (Method == "CONNECT") return "tcp";
            var c = RequestVersion.StartsWith("HTTP/2") ? "h2" : "h1";
            if (string.IsNullOrEmpty(ResponseVersion)) return c;
            var s = ResponseVersion.StartsWith("HTTP/2") ? "h2" : "h1";
            return c == s ? c : $"{c}→{s}";
        }
    }
    public string RuleNames => string.Join(", ", Rules);
    public bool HasRules => Rules.Count > 0;
    public string TimeText => Started.ToString("HH:mm:ss.fff");
    public string DurationText => Completed is DateTime d ? Format.Duration((d - Started).TotalSeconds) : "…";
    public string SizeText => Format.Bytes(ResponseSize);

    /// Bodies were removed to stay under the memory limit; headers and sizes are kept.
    public bool BodiesDropped { get; private set; }
    public bool RequestBodyDropped { get; private set; }
    int droppedRequestSize, droppedResponseSize;
    public int RequestSize => RequestBodyDropped ? droppedRequestSize : RequestBody.Length;
    public int ResponseSize => BodiesDropped ? droppedResponseSize : ResponseBody.Length;
    public int StoredBytes => RequestBody.Length + ResponseBody.Length;

    /// Removes the response body and a request body larger than keptRequest bytes.
    public void DropBodies(int keptRequest)
    {
        if (RequestBody.Length > keptRequest)
        {
            droppedRequestSize = RequestBody.Length;
            RequestBody = Array.Empty<byte>();
            RequestBodyDropped = true;
        }
        if (ResponseBody.Length > 0)
        {
            droppedResponseSize = ResponseBody.Length;
            ResponseBody = Array.Empty<byte>();
            BodiesDropped = true;
        }
    }
    public string DisplayUrl => Method == "CONNECT" ? Host : Url;
    public string Category => Categories.Of(this);

    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// Tells the list the whole row changed (called on the UI thread after the proxy finished a step).
    public void Refresh() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    public string? RequestHeader(string name) => RequestHeaders.FirstOrDefault(h => h.Name.Equals(name, StringComparison.OrdinalIgnoreCase))?.Value;
    public string? ResponseHeader(string name) => ResponseHeaders.FirstOrDefault(h => h.Name.Equals(name, StringComparison.OrdinalIgnoreCase))?.Value;
}

public static class Format
{
    public static string Bytes(long n) => n <= 0 ? "—" : n < 1024 ? $"{n} B" : n < 1024 * 1024 ? $"{n / 1024.0:0.0} KB" : $"{n / 1024.0 / 1024.0:0.0} MB";
    public static string Duration(double s) => s < 0 ? "…" : s < 1 ? $"{(int)(s * 1000)} ms" : $"{s:0.00} s";
}

public static class Categories
{
    public static readonly string[] All = { "All", "JSON", "Form", "XML", "JS", "CSS", "GraphQL", "Document", "Image", "Media", "Errors" };

    public static string Of(Flow f)
    {
        if (f.Path.Contains("graphql", StringComparison.OrdinalIgnoreCase)) return "GraphQL";
        var t = (f.ResponseHeader("Content-Type") ?? f.RequestHeader("Content-Type") ?? "").ToLowerInvariant();
        if (t.Contains("json")) return "JSON";
        if (t.Contains("x-www-form-urlencoded") || t.Contains("multipart/form-data")) return "Form";
        if (t.Contains("xml") && !t.Contains("svg")) return "XML";
        if (t.Contains("javascript")) return "JS";
        if (t.Contains("css")) return "CSS";
        if (t.Contains("html")) return "Document";
        if (t.StartsWith("image/")) return "Image";
        if (t.StartsWith("video/") || t.StartsWith("audio/") || t.Contains("font")) return "Media";
        return "Other";
    }

    public static bool Matches(Flow f, string filter) => filter switch
    {
        "All" => true,
        "Errors" => f.State == FlowState.Failed || f.StatusCode >= 400,
        _ => f.Category == filter,
    };
}

public static class Body
{
    /// Body without Content-Encoding (gzip, deflate, br); the raw data when it cannot be decoded.
    public const int MaxDecoded = 64 * 1024 * 1024;

    public static byte[] Decoded(byte[] body, string? encoding)
    {
        if (body.Length == 0 || string.IsNullOrEmpty(encoding)) return body;
        try
        {
            using var input = new MemoryStream(body);
            Stream s = encoding.Trim().ToLowerInvariant() switch
            {
                "gzip" or "x-gzip" => new GZipStream(input, CompressionMode.Decompress),
                "deflate" => new ZLibStream(input, CompressionMode.Decompress),
                "br" => new BrotliStream(input, CompressionMode.Decompress),
                _ => input,
            };
            // A small "zip bomb" must not unpack into gigabytes: past 64 MB the body is shown as it came
            using var output = new MemoryStream();
            var buffer = new byte[81920];
            int n;
            while ((n = s.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (output.Length + n > MaxDecoded) return body;
                output.Write(buffer, 0, n);
            }
            return output.ToArray();
        }
        catch { return body; }
    }

    public static string Text(byte[] body, string? encoding)
    {
        var data = Decoded(body, encoding);
        if (data.Length == 0) return "";
        var text = Encoding.UTF8.GetString(data);
        // Binary data: show a hex dump of the beginning
        if (text.Count(c => c == '�') > text.Length / 20 + 2) return HexDump(data);
        return text;
    }

    static string HexDump(byte[] data)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < Math.Min(data.Length, 64 * 1024); i += 16)
        {
            var chunk = data.Skip(i).Take(16).ToArray();
            sb.Append(i.ToString("x8")).Append("  ")
              .Append(string.Join(" ", chunk.Select(b => b.ToString("x2"))).PadRight(48)).Append("  ")
              .Append(new string(chunk.Select(b => b is >= 32 and < 127 ? (char)b : '.').ToArray())).Append('\n');
        }
        return sb.ToString();
    }

    public static string PrettyJson(string text)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(text);
            return System.Text.Json.JsonSerializer.Serialize(doc.RootElement, new System.Text.Json.JsonSerializerOptions
            {
                WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            });
        }
        catch { return text; }
    }

    public static string MimeType(string ext) => ext.TrimStart('.').ToLowerInvariant() switch
    {
        "json" => "application/json; charset=utf-8", "html" or "htm" => "text/html; charset=utf-8", "txt" => "text/plain; charset=utf-8",
        "xml" => "application/xml", "js" => "application/javascript", "css" => "text/css", "png" => "image/png",
        "jpg" or "jpeg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp", "svg" => "image/svg+xml", "pdf" => "application/pdf",
        _ => "application/octet-stream",
    };
}
