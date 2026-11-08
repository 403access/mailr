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
            Divider()

            List {
                Section {
                    Toggle(isOn: lockBinding) {
                        HStack(spacing: 12) {
                            Image(systemName: lock.biometrySymbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock with \(lock.biometryName)")
                                Text(lock.isEnabled
                                     ? "App Lock is on."
                                     : "Ask for \(lock.biometryName) whenever Mailr opens.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled((!lock.canUseBiometrics && !lock.isEnabled) || lock.isAuthenticating)
                    .accessibilityHint("Mailr will ask for \(lock.biometryName) every time it opens.")

                    if lock.isEnabled {
                        Button {
                            lock.lock()
                        } label: {
                            Label("Lock Now", systemImage: "lock.fill")
                        }
                        .disabled(lock.isAuthenticating)
                    }
                } header: {
                    Text("App Lock")
                } footer: {
                    Text("Mailr locks every time it launches and whenever it returns from the background. If \(lock.biometryName) isn’t available, your \(fallbackName) is used instead.")
                }

                Section("Status") {
                    LabeledContent("Biometrics") {
                        Text(lock.canUseBiometrics ? "\(lock.biometryName) available" : "Unavailable")
                            .foregroundStyle(lock.canUseBiometrics ? .primary : .secondary)
                    }

                    if !lock.canUseBiometrics, let error = lock.availabilityError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = lock.lastErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Your biometric data never leaves your device. Mailr only receives a yes or no from the system.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .mailrGroupedListStyle()
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
        .modifier(SettingsSizing())
        .background(.background)
        .onAppear { lock.refreshBiometry() }
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Privacy & Security")
                    .font(.title3.weight(.semibold))
                Text("Keep your mail private when Mailr isn’t in use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("Biometrics are checked by your device, not by Mailr.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var fallbackName: String {
        #if os(macOS)
        "Mac password"
        #else
        "device passcode"
        #endif
    }
}
