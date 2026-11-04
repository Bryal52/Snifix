import Foundation
import Compression

public enum BodyCodec {
    /// Decompression stops here: a small gzip/brotli "bomb" must not become gigabytes in memory.
    static let maxDecoded = 64 * 1024 * 1024

    /// Body with Content-Encoding (gzip, deflate, br) removed; the original data when it cannot be decoded.
    public static func decoded(_ body: Data, headers: [HTTPHeader]) -> Data {
        guard !body.isEmpty, let enc = headers["Content-Encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return body
        }
        switch enc {
        case "gzip", "x-gzip": return gunzip(body) ?? body
        case "deflate": return inflate(body.count > 2 && body[body.startIndex] == 0x78 ? body.dropFirst(2) : body) ?? body
        case "br": return decode(body, algorithm: COMPRESSION_BROTLI) ?? body
        default: return body
        }
    }

    public static func isEncoded(_ headers: [HTTPHeader]) -> Bool {
        guard let e = headers["Content-Encoding"]?.lowercased() else { return false }
        return ["gzip", "x-gzip", "deflate", "br"].contains(e.trimmingCharacters(in: .whitespaces))
    }

    private static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return inflate(Data(b[i..<(b.count - 8)]))
    }

    private static func inflate(_ data: Data) -> Data? { decode(data, algorithm: COMPRESSION_ZLIB) }

    private static func decode(_ data: Data, algorithm: compression_algorithm) -> Data? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var result = Data()
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = data.count
            while true {
                stream.pointee.dst_ptr = out
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                result.append(out, count: chunk - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: if result.count > maxDecoded { return nil }
                case COMPRESSION_STATUS_END: return result
                default: return result.isEmpty ? nil : result
                }
            }
        }
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "json": return "application/json; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}

public enum ContentCategory: String, CaseIterable, Sendable {
    case json, form, xml, js, css, graphql, document, image, media, font, other

    public static func of(request: RequestData, response: ResponseData?) -> ContentCategory {
        if request.pathOnly.lowercased().contains("graphql") { return .graphql }
        let type = (response?.headers["Content-Type"] ?? request.headers["Content-Type"] ?? "").lowercased()
        if type.contains("json") { return .json }
        if type.contains("x-www-form-urlencoded") || type.contains("multipart/form-data") { return .form }
        if type.contains("xml") && !type.contains("svg") { return .xml }
        if type.contains("javascript") || type.contains("ecmascript") { return .js }
        if type.contains("css") { return .css }
        if type.contains("html") { return .document }
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("video/") || type.hasPrefix("audio/") { return .media }
        if type.contains("font") { return .font }
        return .other
    }
}
