import SwiftUI
import MailCore

struct HostPasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let account: MailAccount

    @State private var password = ""
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                    Text(account.emailAddress)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                }

                Text("The host server uses this password to download mail from \(account.incoming.host). Messages stay on the original mail server.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("App password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                }

                if account.provider == .gmail {
                    Text("Use a Google app password. Mailr cannot use your normal Google password or OAuth sign-in.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
            footer
        }
        .modifier(HostPasswordSizing())
        .background { MailrBackground() }
        .tint(MailrTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                MailrSectionLabel(text: "Host server")
                Text("Account Password")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkGradient)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MailrIconButtonStyle(size: 32))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            Button {
                save()
            } label: {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.mailrPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background { MailrBarBackground(edge: .top) }
    }

    private func save() {
        guard !isSaving, !password.isEmpty else { return }
        isSaving = true
        errorText = nil

        Task {
            do {
                try model.setHostPassword(password, for: account)
                await model.refreshHostNow()
                dismiss()
            } catch {
                isSaving = false
                errorText = error.localizedDescription
            }
        }
    }
}

private struct HostPasswordSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(width: 460, height: 340)
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
