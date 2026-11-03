import SwiftUI
import AppKit

enum Theme {
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let amber = Color(red: 1.0, green: 0.60, blue: 0.10)
    static let goldGradient = LinearGradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.32), amber],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let background = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.055, green: 0.051, blue: 0.071, alpha: 1)
            : NSColor(red: 0.975, green: 0.968, blue: 0.955, alpha: 1)
    })
    static let surface = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.086, green: 0.080, blue: 0.110, alpha: 1)
            : NSColor.white
    })
    static let stroke = Color.primary.opacity(0.08)

    static func statusColor(_ code: Int, failed: Bool = false) -> Color {
        if failed { return .red }
        switch code {
        case 0: return .secondary
        case 101: return .purple
        case 200..<300: return .green
        case 300..<400: return .cyan
        case 400..<500: return amber
        default: return .red
        }
    }

    static func methodColor(_ m: String) -> Color {
        switch m {
        case "GET": return gold
        case "POST": return .green
        case "PUT", "PATCH": return .cyan
        case "DELETE": return .red
        case "CONNECT": return .secondary
        default: return .purple
        }
    }

    static let nsGold = NSColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 1)
}

/// Gold capsule that slides between options.
struct GoldSegments<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = item == selection
                Text(label(item))
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.black.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        if on {
                            Capsule().fill(Theme.goldGradient)
                                .matchedGeometryEffect(id: "seg", in: ns)
                                .shadow(color: Theme.amber.opacity(0.35), radius: 6, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { selection = item }
                    }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

struct PulseDot: View {
    var active: Bool
    var color: Color = .red
    @UIState private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(active ? 0.35 : 0)).frame(width: 16, height: 16)
                .scaleEffect(pulse ? 1.25 : 0.6).opacity(pulse ? 0 : 1)
            Circle().fill(active ? color : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
        }
        .frame(width: 16, height: 16)
        .onAppear { startPulse() }
        .onChange(of: active) { startPulse() }
    }

    private func startPulse() {
        pulse = false
        guard active else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
    }
}

struct Sparkline: View {
    var values: [Int]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(1, values.max() ?? 1)
            let step = geo.size.width / CGFloat(max(1, values.count - 1))
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v) / CGFloat(maxV)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Theme.goldGradient, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .animation(.easeInOut(duration: 0.4), value: values)
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).foregroundStyle(Theme.goldGradient)
            Text(toast.text).font(.system(size: 12.5, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.35)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }
}

struct Badge: View {
    var text: String
    var color: Color = Theme.gold
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var subtitle: String
    @UIState private var appear = false
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.goldGradient)
                .scaleEffect(appear ? 1 : 0.7)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .opacity(appear ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}

func formatBytes(_ n: Int) -> String {
    if n <= 0 { return "—" }
    if n < 1024 { return "\(n) B" }
    if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
    return String(format: "%.1f MB", Double(n) / 1024 / 1024)
}

func formatDuration(_ s: Double) -> String {
    if s < 0 { return "…" }
    if s < 1 { return "\(Int(s * 1000)) ms" }
    return String(format: "%.2f s", s)
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// The macOS 27 SDK turns `@State` into a macro whose plugin ships only with Xcode;
/// the property wrapper itself is still there and works through an alias.
typealias UIState<Value> = SwiftUI.State<Value>
