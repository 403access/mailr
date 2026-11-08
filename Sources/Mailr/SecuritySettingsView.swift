import SwiftUI

/// Setup screen for App Lock, opened from Settings. It shows whether
/// biometrics are available, turns the lock on after a confirmation prompt,
/// and can lock the app immediately.
struct SecuritySettingsView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    appLockCard
                    statusCard
                    noteCard
                }
                .padding(16)
            }

            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
            footer
        }
        .modifier(SettingsSizing())
        .background { MailrBackground() }
        .tint(MailrTheme.accent)
        .onAppear { lock.refreshBiometry() }
    }

    private var appLockCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MailrTheme.accentGradient)
                        .shadow(color: MailrTheme.accent.opacity(0.24), radius: 7, y: 3)
                    Image(systemName: lock.biometrySymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock with \(lock.biometryName)")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                    Text(lock.isEnabled
                         ? "App Lock is on."
                         : "Ask for \(lock.biometryName) whenever Mailr opens.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                }

                Spacer()

                Toggle("", isOn: lockBinding)
                    .labelsHidden()
                    .tint(MailrTheme.accent)
                    .disabled((!lock.canUseBiometrics && !lock.isEnabled) || lock.isAuthenticating)
                    .accessibilityLabel("App Lock")
                    .accessibilityHint("Mailr will ask for \(lock.biometryName) every time it opens.")
            }
            .padding(14)

            if lock.isEnabled {
                Rectangle()
                    .fill(MailrTheme.hairline)
                    .frame(height: 1)

                Button {
                    lock.lock()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MailrTheme.accent)
                            .frame(width: 24)
                        Text("Lock Now")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(MailrTheme.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MailrTheme.inkTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(lock.isAuthenticating)
            }
        }
        .mailrCard(radius: 20, shadowRadius: 12)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MailrSectionLabel(text: "Status")

            HStack {
                Text("Biometrics")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(lock.canUseBiometrics ? MailrTheme.mint : MailrTheme.inkTertiary)
                        .frame(width: 6, height: 6)
                    Text(lock.canUseBiometrics ? "\(lock.biometryName) available" : "Unavailable")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MailrTheme.surfaceSoft, in: Capsule())
            }

            if !lock.canUseBiometrics, let error = lock.availabilityError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }

            if let error = lock.lastErrorMessage {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mailrCard(radius: 20, shadowRadius: 10)
    }

    private var noteCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MailrTheme.accent)
            Text("Your biometric data never leaves your device. Mailr only receives a yes or no from the system.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MailrTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MailrTheme.accent.opacity(0.10), lineWidth: 1)
        }
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { lock.isEnabled },
            set: { wantsLock in
                if wantsLock {
                    Task { await lock.enable() }
                } else {
                    lock.disable()
                }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            MailrLogoMark(size: 38)

            VStack(alignment: .leading, spacing: 2) {
                MailrSectionLabel(text: "Security")
                Text("Privacy & Security")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkGradient)
                Text("Keep your mail private when Mailr isn’t in use.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(MailrTheme.accent)
            Text("Biometrics are checked by your device, not by Mailr.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background { MailrBarBackground(edge: .top) }
    }

    private var fallbackName: String {
        #if os(macOS)
        "Mac password"
        #else
        "device passcode"
        #endif
    }
}
