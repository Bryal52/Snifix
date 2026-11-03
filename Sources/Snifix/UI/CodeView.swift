import SwiftUI
import AppKit

enum JSONPretty {
    static func format(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]),
              let s = String(data: out, encoding: .utf8) else { return text }
        return s
    }

    static func isJSON(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }
}

enum SyntaxColors {
    static let key = NSColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 1)
    static let string = NSColor(red: 0.55, green: 0.86, blue: 0.55, alpha: 1)
    static let number = NSColor(red: 0.55, green: 0.75, blue: 1.0, alpha: 1)
    static let literal = NSColor(red: 0.95, green: 0.55, blue: 0.75, alpha: 1)
    static let punct = NSColor.secondaryLabelColor
    static let tag = NSColor(red: 1.0, green: 0.65, blue: 0.3, alpha: 1)
}

enum Highlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func attributed(_ text: String, json: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        // Very large bodies are shown without colors to stay responsive
        guard text.utf16.count < 1_500_000 else { return s }
        if json { colorJSON(s, text) } else if text.contains("<") { colorMarkup(s, text) }
        return s
    }

    private static func colorJSON(_ s: NSMutableAttributedString, _ text: String) {
        let ns = text as NSString
        let length = ns.length
        var i = 0
        while i < length {
            let c = ns.character(at: i)
            switch c {
            case 34: // "
                var j = i + 1
                while j < length {
                    let d = ns.character(at: j)
                    if d == 92 { j += 2; continue }
                    if d == 34 { break }
                    j += 1
                }
                let end = min(j + 1, length)
                var k = end
                while k < length, ns.character(at: k) == 32 { k += 1 }
                let isKey = k < length && ns.character(at: k) == 58
                s.addAttribute(.foregroundColor, value: isKey ? SyntaxColors.key : SyntaxColors.string, range: NSRange(location: i, length: end - i))
                i = end
            case 45, 48...57:
                var j = i + 1
                while j < length, let u = UnicodeScalar(ns.character(at: j)), "0123456789.eE+-".unicodeScalars.contains(u) { j += 1 }
                s.addAttribute(.foregroundColor, value: SyntaxColors.number, range: NSRange(location: i, length: j - i))
                i = j
            case 116, 102, 110: // true false null
                var j = i
                while j < length, let u = UnicodeScalar(ns.character(at: j)), CharacterSet.letters.contains(u) { j += 1 }
                s.addAttribute(.foregroundColor, value: SyntaxColors.literal, range: NSRange(location: i, length: j - i))
                i = max(j, i + 1)
            case 123, 125, 91, 93, 44, 58:
                s.addAttribute(.foregroundColor, value: SyntaxColors.punct, range: NSRange(location: i, length: 1))
                i += 1
            default:
                i += 1
            }
        }
    }

    private static func colorMarkup(_ s: NSMutableAttributedString, _ text: String) {
        guard let re = try? NSRegularExpression(pattern: "</?[a-zA-Z][^>]*>") else { return }
        for m in re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            s.addAttribute(.foregroundColor, value: SyntaxColors.tag, range: m.range)
        }
    }
}

/// NSTextView-based viewer/editor: fast with big bodies, find bar, syntax colors.
struct CodeView: NSViewRepresentable {
    var text: String
    var json: Bool = false
    var editable: Bool = false
    var onChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.isEditable = editable
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = Highlighter.font
        tv.insertionPointColor = Theme.nsGold
        tv.selectedTextAttributes = [.backgroundColor: Theme.nsGold.withAlphaComponent(0.3)]
        tv.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        context.coordinator.apply(text, to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = editable
        if context.coordinator.lastText != text { context.coordinator.apply(text, to: tv) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeView
        var lastText: String?
        init(_ p: CodeView) { parent = p }

        func apply(_ text: String, to tv: NSTextView) {
            lastText = text
            let selected = tv.selectedRanges
            tv.textStorage?.setAttributedString(Highlighter.attributed(text, json: parent.json || JSONPretty.isJSON(text)))
            if parent.editable { tv.selectedRanges = selected.filter { $0.rangeValue.upperBound <= (text as NSString).length } }
            if tv.selectedRanges.isEmpty { tv.setSelectedRange(NSRange(location: 0, length: 0)) }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            lastText = tv.string
            parent.onChange?(tv.string)
        }
    }
}

/// Collapsible tree for JSON bodies.
struct JSONNode: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    let kind: Kind
    var children: [JSONNode]?
    enum Kind { case object, array, string, number, bool, null }

    static func build(_ any: Any, key: String = "root") -> JSONNode {
        if let d = any as? [String: Any] {
            return JSONNode(key: key, value: "{\(d.count)}", kind: .object,
                            children: d.keys.sorted().map { build(d[$0]!, key: $0) })
        }
        if let a = any as? [Any] {
            return JSONNode(key: key, value: "[\(a.count)]", kind: .array,
                            children: a.enumerated().map { build($1, key: "[\($0)]") })
        }
        if any is NSNull { return JSONNode(key: key, value: "null", kind: .null) }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return JSONNode(key: key, value: n.boolValue ? "true" : "false", kind: .bool) }
            return JSONNode(key: key, value: n.stringValue, kind: .number)
        }
        return JSONNode(key: key, value: "\"\(any)\"", kind: .string)
    }

    var color: Color {
        switch kind {
        case .string: return Color(nsColor: SyntaxColors.string)
        case .number: return Color(nsColor: SyntaxColors.number)
        case .bool, .null: return Color(nsColor: SyntaxColors.literal)
        default: return .secondary
        }
    }
}

struct JSONTreeView: View {
    let root: JSONNode
    var body: some View {
        List {
            OutlineGroup(root.children ?? [root], children: \.children) { node in
                HStack(spacing: 6) {
                    Text(node.key).foregroundStyle(Color(nsColor: SyntaxColors.key))
                    Text(node.value).foregroundStyle(node.color).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy Value") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), forType: .string)
                    }
                    Button("Copy Key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.key, forType: .string)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
