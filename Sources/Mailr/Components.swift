import SwiftUI
import UniformTypeIdentifiers
import MailCore

// MARK: - Avatar

struct AvatarView: View {
    let name: String
    let address: String
    var size: CGFloat = 30

    private var initials: String {
        let source = name.isEmpty ? address : name
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "@" })
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(source.prefix(2)).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.36, green: 0.26, blue: 0.96),
            Color(red: 0.00, green: 0.69, blue: 0.94),
            Color(red: 0.64, green: 0.35, blue: 0.98),
            Color(red: 0.10, green: 0.78, blue: 0.68),
            Color(red: 0.94, green: 0.41, blue: 0.62),
            Color(red: 0.96, green: 0.64, blue: 0.21)
        ]
        let hash = address.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.24), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.72
                    )
                )

            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
        }
        .accessibilityLabel(Text(name.isEmpty ? address : name))
    }
}

// MARK: - Dates

enum MailDateFormat {
    static func listDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    static func detailDate(_ date: Date) -> String {
        #if os(iOS)
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        #else
        date.formatted(date: .complete, time: .shortened)
        #endif
    }
}

// MARK: - Small pieces

struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(MailrTheme.accentGradient)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread")
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(MailrTheme.accentDeep)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(MailrTheme.accent.opacity(0.11), in: Capsule())
            .overlay {
                Capsule().strokeBorder(MailrTheme.accent.opacity(0.13), lineWidth: 1)
            }
    }
}

struct AttachmentChip: View {
    let attachment: MailAttachment
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MailrTheme.accent.opacity(0.10))
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MailrTheme.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MailrTheme.ink)
                    .lineLimit(1)
                Text(attachment.byteCountLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
            }
            Spacer(minLength: 4)
            Button(action: onSave) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(MailrTheme.accent)
            }
            .buttonStyle(.plain)
            .mailrHelp("Save attachment")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 260)
        .background(MailrTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MailrTheme.border, lineWidth: 1)
        }
    }

    private var iconName: String {
        let type = attachment.mimeType.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("video/") { return "film" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("archive") { return "archivebox" }
        if type.hasPrefix("text/") { return "doc.text" }
        return "paperclip"
    }
}

/// File wrapper used by `.fileExporter` for attachments on both iOS and macOS.
struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum AttachmentContentType {
    static func type(for attachment: MailAttachment) -> UTType {
        if let type = UTType(mimeType: attachment.mimeType) {
            return type
        }
        let ext = (attachment.filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .strokeBorder(MailrTheme.accent.opacity(0.10), lineWidth: 1)
                    .frame(width: 132, height: 132)
                Circle()
                    .strokeBorder(MailrTheme.cyan.opacity(0.12), lineWidth: 1)
                    .frame(width: 106, height: 106)
                Circle()
                    .fill(MailrTheme.accent.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(MailrTheme.accentGradient)
            }

            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(MailrTheme.ink)

            Text(message)
                .font(.system(size: 13.5, weight: .regular, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
