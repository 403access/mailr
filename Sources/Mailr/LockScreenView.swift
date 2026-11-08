import SwiftUI

/// Opaque cover shown above the mail UI while App Lock is engaged. It prompts
/// for biometrics once on appearance and lets the person retry manually.
struct LockScreenView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPrompted = false

    var body: some View {
        ZStack {
            Color.mailrWindowBackground
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 2)

                Text("Mailr is Locked")
                    .font(.title2.weight(.semibold))

                Text(unlockPrompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let message = lock.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lock.isAuthenticating)
                .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .padding(32)
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
