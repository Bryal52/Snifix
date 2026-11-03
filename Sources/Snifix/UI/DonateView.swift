import SwiftUI
import AppKit

/// Bank cards the author accepts donations on.
private struct DonationCard: Identifiable {
    let id: String
    let brand: String
    let number: String
    let colors: [Color]
}

private let donationCards = [
    DonationCard(id: "visa", brand: "VISA", number: "4916 9903 0007 3175",
                 colors: [Color(red: 0.10, green: 0.20, blue: 0.55), Color(red: 0.18, green: 0.42, blue: 0.85)]),
    DonationCard(id: "mc", brand: "Mastercard", number: "5321 5400 1305 0170",
                 colors: [Color(red: 0.16, green: 0.14, blue: 0.20), Color(red: 0.32, green: 0.28, blue: 0.36)]),
]
private let cardHolder = "MAVLONOV UMIDJON"

/// Coffee cup in the corner of the status bar.
struct DonateButton: View {
    @Binding var isPresented: Bool
    @UIState private var hover = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill")
                    .symbolEffect(.bounce, value: hover)
                Text("Donate").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(hover ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(Theme.goldGradient))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(hover ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.gold.opacity(0.12))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
        .help("Buy the author a coffee")
    }
}

struct DonateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @UIState private var appear = false

    var body: some View {
        VStack(spacing: 16) {
            WhiteCat()
                .frame(width: 150, height: 150)
                .scaleEffect(appear ? 1 : 0.6)
                .rotationEffect(.degrees(appear ? 0 : -8))
                .shadow(color: Theme.amber.opacity(0.35), radius: 18, y: 6)
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill").foregroundStyle(Theme.goldGradient)
                    Text("Support Snifix").font(.system(size: 20, weight: .bold))
                }
                Text("Donations are completely optional.\nSnifix is free and stays free — but a coffee makes the author happy.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                ForEach(Array(donationCards.enumerated()), id: \.element.id) { i, card in
                    CardTile(card: card) { model.copy(card.number.replacingOccurrences(of: " ", with: ""), note: "\(card.brand) number copied") }
                        .opacity(appear ? 1 : 0)
                        .offset(y: appear ? 0 : 18)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.12 + Double(i) * 0.08), value: appear)
                }
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(width: 400)
        .background(Theme.background)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) { appear = true } }
    }
}

private struct CardTile: View {
    let card: DonationCard
    let copy: () -> Void
    @UIState private var copied = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.number)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Text(cardHolder).font(.system(size: 10.5, weight: .medium)).tracking(1.2).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                BrandMark(brand: card.brand)
                Button {
                    copy()
                    withAnimation(.spring(response: 0.3)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.goldGradient))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: card.colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

private struct BrandMark: View {
    let brand: String
    var body: some View {
        if brand == "VISA" {
            Text("VISA").font(.system(size: 17, weight: .heavy, design: .rounded)).italic().foregroundStyle(.white)
        } else {
            HStack(spacing: -9) {
                Circle().fill(Color(red: 0.92, green: 0.0, blue: 0.11)).frame(width: 20, height: 20)
                Circle().fill(Color(red: 0.97, green: 0.62, blue: 0.11).opacity(0.9)).frame(width: 20, height: 20)
            }
        }
    }
}

/// A white kitten, drawn so it stays sharp at any size.
struct WhiteCat: View {
    @UIState private var blink = false

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let fur = Color(white: 0.98)
            let shade = Color(white: 0.86)
            let pink = Color(red: 1.0, green: 0.72, blue: 0.78)
            let line = Color(white: 0.35)

            // Gold backdrop circle
            ctx.fill(Path(ellipseIn: r(4, 4, 92, 92)),
                     with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.32), Color(red: 1, green: 0.6, blue: 0.1)]),
                                           startPoint: p(10, 10), endPoint: p(90, 90)))
            // Body and tail
            ctx.fill(Path(ellipseIn: r(26, 56, 48, 40)), with: .color(fur))
            var tail = Path()
            tail.move(to: p(70, 84))
            tail.addQuadCurve(to: p(88, 60), control: p(92, 80))
            ctx.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))
            // Ears
            for (a, b, c) in [(p(26, 36), p(30, 12), p(46, 28)), (p(74, 36), p(70, 12), p(54, 28))] {
                var ear = Path(); ear.move(to: a); ear.addLine(to: b); ear.addLine(to: c); ear.closeSubpath()
                ctx.fill(ear, with: .color(fur))
            }
            for (a, b, c) in [(p(30, 32), p(32, 18), p(42, 28)), (p(70, 32), p(68, 18), p(58, 28))] {
                var inner = Path(); inner.move(to: a); inner.addLine(to: b); inner.addLine(to: c); inner.closeSubpath()
                ctx.fill(inner, with: .color(pink))
            }
            // Head
            ctx.fill(Path(ellipseIn: r(22, 22, 56, 46)), with: .color(fur))
            ctx.fill(Path(ellipseIn: r(30, 50, 40, 16)), with: .color(shade.opacity(0.35)))
            // Eyes
            for x in [36.0, 56.0] {
                if blink {
                    var lid = Path(); lid.move(to: p(x, 42)); lid.addQuadCurve(to: p(x + 8, 42), control: p(x + 4, 45))
                    ctx.stroke(lid, with: .color(line), style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
                } else {
                    ctx.fill(Path(ellipseIn: r(x, 37, 8, 10)), with: .color(Color(red: 0.25, green: 0.55, blue: 0.85)))
                    ctx.fill(Path(ellipseIn: r(x + 2.2, 38.5, 3.6, 7)), with: .color(Color(white: 0.1)))
                    ctx.fill(Path(ellipseIn: r(x + 4.6, 38.5, 2, 2)), with: .color(.white))
                }
            }
            // Nose and mouth
            var nose = Path(); nose.move(to: p(47.5, 50)); nose.addLine(to: p(52.5, 50)); nose.addLine(to: p(50, 53)); nose.closeSubpath()
            ctx.fill(nose, with: .color(pink))
            var mouth = Path()
            mouth.move(to: p(50, 53)); mouth.addQuadCurve(to: p(45, 56), control: p(48, 57))
            mouth.move(to: p(50, 53)); mouth.addQuadCurve(to: p(55, 56), control: p(52, 57))
            ctx.stroke(mouth, with: .color(line), style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
            // Cheeks and whiskers
            ctx.fill(Path(ellipseIn: r(29, 50, 8, 5)), with: .color(pink.opacity(0.55)))
            ctx.fill(Path(ellipseIn: r(63, 50, 8, 5)), with: .color(pink.opacity(0.55)))
            var whiskers = Path()
            for (y1, y2) in [(51.0, 49.0), (54.0, 55.0)] {
                whiskers.move(to: p(38, y1)); whiskers.addLine(to: p(16, y2))
                whiskers.move(to: p(62, y1)); whiskers.addLine(to: p(84, y2))
            }
            ctx.stroke(whiskers, with: .color(line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8 * s, lineCap: .round))
            // Paws
            ctx.fill(Path(ellipseIn: r(34, 86, 12, 8)), with: .color(fur))
            ctx.fill(Path(ellipseIn: r(54, 86, 12, 8)), with: .color(fur))
            ctx.stroke(Path(ellipseIn: r(34, 86, 12, 8)), with: .color(shade), lineWidth: 0.8 * s)
            ctx.stroke(Path(ellipseIn: r(54, 86, 12, 8)), with: .color(shade), lineWidth: 0.8 * s)
        }
        .task {
            // Blinks every few seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                withAnimation(.easeInOut(duration: 0.1)) { blink = true }
                try? await Task.sleep(nanoseconds: 160_000_000)
                withAnimation(.easeInOut(duration: 0.1)) { blink = false }
            }
        }
    }
}
