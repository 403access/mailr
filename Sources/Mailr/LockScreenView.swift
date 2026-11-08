import SwiftUI

/// Opaque cover shown above the mail UI while App Lock is engaged. It prompts
/// for biometrics once on appearance and lets the person retry manually.
struct LockScreenView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPrompted = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        MailrTheme.accent.opacity(0.10 - Double(index) * 0.024),
                        lineWidth: 1
                    )
                    .frame(
                        width: 230 + CGFloat(index) * 62,
                        height: 230 + CGFloat(index) * 62
                    )
            }

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(MailrTheme.accent.opacity(0.10))
                        .frame(width: 96, height: 96)
                    Circle()
                        .strokeBorder(MailrTheme.accent.opacity(0.16), lineWidth: 1)
                        .frame(width: 96, height: 96)

                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(MailrTheme.accentGradient)
                            .shadow(color: MailrTheme.accent.opacity(0.38), radius: 18, y: 8)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 60, height: 60)
                }
                .padding(.bottom, 2)

                VStack(spacing: 7) {
                    MailrSectionLabel(text: "Secure Session")

                    Text("Mailr is Locked")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkGradient)

                    Text(unlockPrompt)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                if let message = lock.lastErrorMessage {
                    Text(message)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label(
                        lock.isAuthenticating ? "Unlocking…" : unlockButtonTitle,
                        systemImage: lock.biometrySymbol
                    )
                    .frame(minWidth: 190)
                }
                .buttonStyle(.mailrPrimary)
                .disabled(lock.isAuthenticating)
                .padding(.top, 4)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("Protected by LocalAuthentication")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(MailrTheme.inkTertiary)
            }
            .multilineTextAlignment(.center)
            .padding(30)
            .frame(maxWidth: 370)
            .mailrCard(radius: 32, shadowRadius: 30)
            .padding(24)
        }
        .animation(.snappy(duration: 0.2), value: lock.lastErrorMessage)
        .task(id: scenePhase) {
            // The lock can engage while Mailr is still in the background. Wait
            // until the scene is active so the system prompt is presented.
            guard scenePhase == .active else {
                if scenePhase == .background {
                    hasPrompted = false
                }
                return
            }
            guard !hasPrompted else { return }
            hasPrompted = true
            await lock.unlock()
        }
        .accessibilityAddTraits(.isModal)
    }

    private var unlockPrompt: String {
        if lock.canUseBiometrics {
            return "Unlock with \(lock.biometryName) to view your mail."
        }
        return "Unlock to view your mail."
    }

    private var unlockButtonTitle: String {
        lock.canUseBiometrics ? "Unlock with \(lock.biometryName)" : "Unlock"
    }
}
