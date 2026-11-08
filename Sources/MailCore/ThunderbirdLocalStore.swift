import Foundation

// MARK: - Local folders

public struct ThunderbirdLocalFolder: Sendable, Hashable, Identifiable {
    public enum Format: Sendable, Hashable {
        case mbox
        case maildir
    }

    /// The mailbox path shown to Mailr, such as `Local Folders/Inbox`.
    public var path: String
    /// The leaf name shown in the sidebar.
    public var name: String
    public var role: MailboxRole
    public var url: URL
    public var format: Format

    public var id: String { path }
}

public struct ThunderbirdStoredMessage: Sendable {
    public var data: Data
    public var fallbackDate: Date
}

public enum ThunderbirdLocalStore {
    /// Discovers mbox files and Maildir folders below a Thunderbird mail
    /// directory, including nested `.sbd` folders.
    public static func discoverFolders(in source: ThunderbirdLocalSource) -> [ThunderbirdLocalFolder] {
        var folders: [ThunderbirdLocalFolder] = []
        walk(
            directory: source.directory,
            prefix: "",
            source: source,
            into: &folders
        )
        return folders.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    public static func messages(in folder: ThunderbirdLocalFolder) throws -> [ThunderbirdStoredMessage] {
        switch folder.format {
        case .mbox:
            let data = try Data(contentsOf: folder.url, options: .mappedIfSafe)
            let fallback = modificationDate(of: folder.url)
            let ranges = MboxReader.messageRanges(in: data)

            return ranges.compactMap { range in
                let raw = MboxReader.unescape(data[range])
                guard !raw.isEmpty else { return nil }
                return ThunderbirdStoredMessage(
                    data: raw,
                    fallbackDate: MboxReader.envelopeDate(for: range, in: data) ?? fallback
                )
            }
        case .maildir:
            return try maildirMessages(in: folder.url)
        }
    }

    /// Counts messages without decoding them. Useful for dry-run reporting.
    public static func messageCount(in folder: ThunderbirdLocalFolder) throws -> Int {
        switch folder.format {
        case .mbox:
            let data = try Data(contentsOf: folder.url, options: .mappedIfSafe)
            return MboxReader.messageRanges(in: data).count
        case .maildir:
            return try maildirURLs(in: folder.url).count
        }
    }

    // MARK: Discovery

    private static func walk(
        directory: URL,
        prefix: String,
        source: ThunderbirdLocalSource,
        into folders: inout [ThunderbirdLocalFolder]
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(".msf") || isMetadataFile(name) {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                if name.hasSuffix(".sbd") || name.hasSuffix(".mozmsgs") {
                    guard name.hasSuffix(".sbd") else { continue }
                    let base = String(name.dropLast(".sbd".count))
                    walk(
                        directory: entry,
                        prefix: join(prefix, base),
                        source: source,
                        into: &folders
                    )
                } else if isMaildir(entry) {
                    let folderPath = join(prefix, name)
                    folders.append(makeFolder(
                        source: source,
                        folderPath: folderPath,
                        url: entry,
                        format: .maildir
                    ))
                }
                continue
            }

            guard isMboxCandidate(entry, name: name) else { continue }
            let folderPath = join(prefix, name)
            folders.append(makeFolder(
                source: source,
                folderPath: folderPath,
                url: entry,
                format: .mbox
            ))
        }
    }

    private static func makeFolder(
        source: ThunderbirdLocalSource,
        folderPath: String,
        url: URL,
        format: ThunderbirdLocalFolder.Format
    ) -> ThunderbirdLocalFolder {
        let name = folderPath.split(separator: "/").last.map(String.init) ?? folderPath
        return ThunderbirdLocalFolder(
            path: "\(source.label)/\(folderPath)",
            name: name,
            role: role(for: name),
            url: url,
            format: format
        )
    }

    private static func join(_ prefix: String, _ name: String) -> String {
        prefix.isEmpty ? name : "\(prefix)/\(name)"
    }

    private static func isMaildir(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        let cur = directory.appendingPathComponent("cur", isDirectory: true)
        let new = directory.appendingPathComponent("new", isDirectory: true)
        var isDirectory: ObjCBool = false
        let hasCur = fileManager.fileExists(atPath: cur.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let hasNew = fileManager.fileExists(atPath: new.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        return hasCur || hasNew
    }

    private static func isMboxCandidate(_ url: URL, name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { return false }
        return true
    }

    private static func isMetadataFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        let blockedExtensions = [
            "json", "jsonlz4", "sqlite", "sqlite3", "db", "dat", "mab",
            "html", "htm", "log", "ini", "bak", "tmp", "lock"
        ]
        let ext = (lower as NSString).pathExtension
        if blockedExtensions.contains(ext) { return true }
        return lower == "msgfilterrules.dat"
            || lower == "session.json"
            || lower.hasPrefix("filterlog")
    }

    private static func role(for name: String) -> MailboxRole {
        var key = name.lowercased()
        // Thunderbird names shared local folders like
        // `Sent Items-user@example.com`. Match the folder part.
        if let dash = key.firstIndex(of: "-"),
           key[key.index(after: dash)...].contains("@") {
            key = key[..<dash].trimmingCharacters(in: .whitespaces)
        }

        switch key {
        case "inbox":
            return .inbox
        case "drafts", "draft", "entwürfe", "entwurf":
            return .drafts
        case "sent", "sent mail", "sent items", "sent messages", "gesendet", "gesendete elemente", "gesendete objekte":
            return .sent
        case "archives", "archive", "archiv":
            return .archive
        case "junk", "spam", "bulk mail", "unerwünschte mail":
            return .junk
        case "trash", "deleted", "deleted items", "deleted messages", "deleted mail", "papierkorb", "gelöschte elemente", "gelöschte objekte":
            return .trash
        default:
            return .other
        }
    }

    // MARK: Maildir

    private static func maildirURLs(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []

        for subdirectory in ["cur", "new"] {
            let folder = directory.appendingPathComponent(subdirectory, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            urls.append(contentsOf: entries.filter { entry in
                (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            })
        }

        urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return urls
    }

    private static func maildirMessages(in directory: URL) throws -> [ThunderbirdStoredMessage] {
        try maildirURLs(in: directory).compactMap { url in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { return nil }
            return ThunderbirdStoredMessage(
                data: data,
                fallbackDate: modificationDate(of: url)
            )
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }
}

// MARK: - mbox

enum MboxReader {
    private static let fromPrefix = Data("From ".utf8)
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Splits an mbox file into message ranges. A separator is a line that
    /// starts with `From ` at the start of the file or after a blank line.
    static func messageRanges(in data: Data) -> [Range<Data.Index>] {
        guard !data.isEmpty else { return [] }

        var ranges: [Range<Data.Index>] = []
        var currentStart: Data.Index?
        var lineStart = data.startIndex
        var previousLineBlank = true

        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            var contentEnd = lineEnd
            if contentEnd > lineStart, data[data.index(before: contentEnd)] == 0x0D {
                contentEnd = data.index(before: contentEnd)
            }
            let line = data[lineStart..<contentEnd]

            if previousLineBlank && line.starts(with: fromPrefix) {
                if let start = currentStart {
                    ranges.append(trimmed(start..<lineStart, in: data))
                }
                currentStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
                previousLineBlank = false
            } else {
                previousLineBlank = line.isEmpty
            }

            if lineEnd == data.endIndex { break }
            lineStart = data.index(after: lineEnd)
        }

        if let start = currentStart {
            ranges.append(trimmed(start..<data.endIndex, in: data))
        }

        if ranges.isEmpty {
            let whole = trimmed(data.startIndex..<data.endIndex, in: data)
            if !whole.isEmpty { ranges.append(whole) }
        }
        return ranges
    }

    /// Removes one level of mboxrd quoting from lines beginning with `>From `.
    static func unescape(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        var output = Data()
        output.reserveCapacity(data.count)
        var lineStart = data.startIndex

        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            var contentEnd = lineEnd
            if contentEnd > lineStart, data[data.index(before: contentEnd)] == 0x0D {
                contentEnd = data.index(before: contentEnd)
            }
            let line = data[lineStart..<contentEnd]

            if line.first == 0x3E,
               line.dropFirst().starts(with: fromPrefix) {
                output.append(line.dropFirst())
            } else {
                output.append(line)
            }

            if lineEnd < data.endIndex {
                output.append(0x0A)
                lineStart = data.index(after: lineEnd)
            } else {
                break
            }
        }

        return output
    }

    /// Finds the mbox separator line immediately before a message range and
    /// parses its envelope date.
    static func envelopeDate(for range: Range<Data.Index>, in data: Data) -> Date? {
        guard range.lowerBound > data.startIndex else { return nil }

        var index = data.index(before: range.lowerBound)
        while index > data.startIndex,
              data[index] == 0x0A || data[index] == 0x0D {
            index = data.index(before: index)
        }

        let lineStart = data[..<index].lastIndex(of: 0x0A)
            .map { data.index(after: $0) } ?? data.startIndex
        let line = data[lineStart...index]
        guard line.starts(with: fromPrefix) else { return nil }
        return envelopeDate(from: line)
    }

    static func envelopeDate(from data: Data) -> Date? {
        let lineEnd = data.firstIndex(of: 0x0A) ?? data.endIndex
        var text = String(decoding: data[..<lineEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("From ") else { return nil }
        text = String(text.dropFirst("From ".count))

        // Envelope lines look like `From sender@example.com Mon Jan  1 ...`
        // or `From - Mon Jan  1 ...`. Start parsing at the weekday token.
        guard let weekday = weekdays
            .compactMap({ text.range(of: $0)?.lowerBound })
            .min() else {
            return nil
        }
        let dateText = String(text[weekday...])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE MMM d HH:mm:ss yyyy",
            "EEE MMM d HH:mm:ss Z yyyy",
            "EEE MMM d HH:mm:ss zzz yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateText) {
                return date
            }
        }
        return nil
    }

    private static func trimmed(
        _ range: Range<Data.Index>,
        in data: Data
    ) -> Range<Data.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound

        while lower < upper, isWhitespace(data[lower]) {
            lower = data.index(after: lower)
        }
        while upper > lower {
            let previous = data.index(before: upper)
            guard isWhitespace(data[previous]) else { break }
            upper = previous
        }
        return lower..<upper
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09
    }
}
