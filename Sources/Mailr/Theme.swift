import SwiftUI

// MARK: - Palette

/// The light "Aurora Glass" theme. Colors are intentionally fixed while the
/// app is light-only; a matching dark palette can be layered in later without
/// changing the shape of the design system.
enum MailrTheme {
    static let baseTop = Color(red: 0.976, green: 0.980, blue: 1.000)
    static let baseBottom = Color(red: 0.929, green: 0.941, blue: 0.992)

    static let ink = Color(red: 0.071, green: 0.086, blue: 0.157)
    static let inkSecondary = Color(red: 0.353, green: 0.388, blue: 0.490)
    static let inkTertiary = Color(red: 0.545, green: 0.573, blue: 0.663)

    static let accent = Color(red: 0.365, green: 0.259, blue: 0.965)
    static let accentDeep = Color(red: 0.231, green: 0.157, blue: 0.867)
    static let cyan = Color(red: 0.000, green: 0.694, blue: 0.941)
    static let violet = Color(red: 0.639, green: 0.345, blue: 0.976)
    static let mint = Color(red: 0.098, green: 0.780, blue: 0.678)
    static let amber = Color(red: 0.965, green: 0.643, blue: 0.208)

    static let surface = Color.white.opacity(0.78)
    static let surfaceStrong = Color.white.opacity(0.94)
    static let surfaceSoft = Color.white.opacity(0.56)
    static let border = Color.white.opacity(0.90)
    static let hairline = Color(red: 0.74, green: 0.77, blue: 0.89).opacity(0.55)
    static let shadow = Color(red: 0.16, green: 0.18, blue: 0.46).opacity(0.10)

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.42, green: 0.28, blue: 0.99),
            Color(red: 0.14, green: 0.68, blue: 0.99)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let auroraGradient = LinearGradient(
        colors: [violet, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let selectionGradient = LinearGradient(
        colors: [accent.opacity(0.15), cyan.opacity(0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [Color.white.opacity(0.96), Color.white.opacity(0.70)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let inkGradient = LinearGradient(
        colors: [ink, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let unreadGradient = LinearGradient(
        colors: [Color.white.opacity(0.99), accent.opacity(0.075)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Aurora background

struct MailrBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [MailrTheme.baseTop, MailrTheme.baseBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { proxy in
                let longest = max(proxy.size.width, proxy.size.height)
                ZStack {
                    glow(MailrTheme.violet, opacity: 0.26, diameter: longest * 0.78)
                        .offset(x: -proxy.size.width * 0.34, y: -proxy.size.height * 0.36)

                    glow(MailrTheme.cyan, opacity: 0.18, diameter: longest * 0.66)
                        .offset(x: proxy.size.width * 0.38, y: proxy.size.height * 0.12)

                    glow(MailrTheme.mint, opacity: 0.12, diameter: longest * 0.58)
                        .offset(x: proxy.size.width * 0.10, y: proxy.size.height * 0.48)
                }
                .blur(radius: 46)
            }

            LinearGradient(
                colors: [Color.white.opacity(0.38), .clear, Color.white.opacity(0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.softLight)
        }
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, opacity: Double, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Brand marks

struct MailrLogoMark: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(MailrTheme.accentGradient)
                .shadow(color: MailrTheme.accent.opacity(0.32), radius: size * 0.32, y: size * 0.14)

            Image(systemName: "envelope.fill")
                .font(.system(size: size * 0.40, weight: .bold))
                .foregroundStyle(.white)

            Image(systemName: "sparkle")
                .font(.system(size: size * 0.19, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .offset(x: size * 0.29, y: -size * 0.29)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MailrSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .tracking(2.1)
            .foregroundStyle(MailrTheme.inkTertiary)
    }
}

struct MailrStatChip: View {
    let systemImage: String
    let text: String
    var highlighted: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(highlighted ? MailrTheme.accentDeep : MailrTheme.inkSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            highlighted ? MailrTheme.accent.opacity(0.10) : MailrTheme.surfaceSoft,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    highlighted ? MailrTheme.accent.opacity(0.14) : MailrTheme.hairline,
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Surface styles

struct MailrCardModifier: ViewModifier {
    var radius: CGFloat = 18
    var shadowRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(MailrTheme.cardGradient)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(MailrTheme.border, lineWidth: 1)
            }
            .shadow(color: MailrTheme.shadow, radius: shadowRadius, x: 0, y: shadowRadius * 0.42)
    }
}

extension View {
    func mailrCard(radius: CGFloat = 18, shadowRadius: CGFloat = 16) -> some View {
        modifier(MailrCardModifier(radius: radius, shadowRadius: shadowRadius))
    }

    /// Frosted strip used for toolbars and footers.
    @ViewBuilder
    func mailrGlassBar(edge: VerticalEdge = .top) -> some View {
        self.background {
            ZStack(alignment: edge == .top ? .top : .bottom) {
                Rectangle()
                    .fill(MailrTheme.surfaceStrong)
                Rectangle()
                    .fill(MailrTheme.hairline)
                    .frame(height: 1)
            }
        }
    }
}

struct MailrBarBackground: View {
    var edge: VerticalEdge = .top

    var body: some View {
        ZStack(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(MailrTheme.surfaceStrong)
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
        }
    }
}

// MARK: - Buttons

struct MailrPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(MailrTheme.accentGradient, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
            .shadow(
                color: MailrTheme.accent.opacity(isEnabled ? 0.34 : 0),
                radius: 12,
                y: 5
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MailrPrimaryButtonStyle {
    static var mailrPrimary: MailrPrimaryButtonStyle { .init() }
}

struct MailrIconButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: (size * 0.44), weight: .semibold))
            .foregroundStyle(MailrTheme.inkSecondary)
            .frame(width: size, height: size)
            .background(MailrTheme.surfaceSoft, in: Circle())
            .overlay {
                Circle().strokeBorder(MailrTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.70 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MailrIconButtonStyle {
    static var mailrIcon: MailrIconButtonStyle { .init() }
}
