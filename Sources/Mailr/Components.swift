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
            Color(red: 0.30, green: 0.49, blue: 0.90),
            Color(red: 0.85, green: 0.42, blue: 0.31),
            Color(red: 0.24, green: 0.63, blue: 0.52),
            Color(red: 0.62, green: 0.42, blue: 0.82),
            Color(red: 0.83, green: 0.59, blue: 0.20),
            Color(red: 0.29, green: 0.60, blue: 0.72)
        ]
        let hash = address.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.95), color.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread")
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

struct AttachmentChip: View {
    let attachment: MailAttachment
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(attachment.byteCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Button(action: onSave) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .mailrHelp("Save attachment")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 250)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
