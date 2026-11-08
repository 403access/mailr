import Foundation

// MARK: - Errors

public enum ThunderbirdImportError: LocalizedError, Equatable, Sendable {
    case rootNotFound(String)
    case profilesNotFound(String)
    case unreadableProfile(String)
    case unreadablePrefs(String)

    public var errorDescription: String? {
        switch self {
        case .rootNotFound(let path):
            "No Thunderbird profile folder was found at \(path)."
        case .profilesNotFound(let path):
            "No Thunderbird profiles with a prefs.js file were found under \(path)."
        case .unreadableProfile(let path):
            "Could not read the Thunderbird profile at \(path)."
        case .unreadablePrefs(let path):
            "Could not read Thunderbird preferences at \(path)."
        }
    }
}

// MARK: - Profiles

/// One Thunderbird profile folder, as listed by profiles.ini or discovered on
/// disk. The profile is identified by its standardized folder path.
public struct ThunderbirdProfile: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: URL
    public var isDefault: Bool

    public init(name: String, path: URL, isDefault: Bool = false) {
        self.name = name
        self.path = path
        self.isDefault = isDefault
    }

    public var id: String { path.standardizedFileURL.path }
    public var prefsURL: URL { path.appendingPathComponent("prefs.js") }
}

public enum ThunderbirdProfiles {
    /// The platform's default Thunderbird data directory.
    public static func defaultRoots(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL] = []

        #if os(macOS)
        roots.append(homeDirectory.appendingPathComponent("Library/Thunderbird", isDirectory: true))
        #elseif os(Windows)
        if let appData = environment["APPDATA"] {
            roots.append(URL(fileURLWithPath: appData, isDirectory: true)
                .appendingPathComponent("Thunderbird", isDirectory: true))
        }
        #else
        roots.append(homeDirectory.appendingPathComponent(".thunderbird", isDirectory: true))
        roots.append(homeDirectory.appendingPathComponent(".mozilla-thunderbird", isDirectory: true))
        #endif

        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Discovers profiles under `root`. When `root` itself contains a
    /// prefs.js file it is treated as a single profile folder.
    public static func discover(root: URL) throws -> [ThunderbirdProfile] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ThunderbirdImportError.rootNotFound(root.path)
        }

        let root = root.standardizedFileURL

        if !isDirectory.boolValue {
            throw ThunderbirdImportError.rootNotFound(root.path)
        }

        if fileManager.fileExists(atPath: root.appendingPathComponent("prefs.js").path) {
            return [ThunderbirdProfile(name: root.lastPathComponent, path: root, isDefault: true)]
        }

        var found: [ThunderbirdProfile] = []
        var defaultPaths = Set<String>()

        let profilesIni = root.appendingPathComponent("profiles.ini")
        if let text = try? String(contentsOf: profilesIni, encoding: .utf8) {
            let document = IniDocument.parse(text)
            for section in document.sections where section.name.hasPrefix("Profile") {
                guard let rawPath = section.values["Path"], !rawPath.isEmpty else { continue }
                let path = resolve(
                    path: rawPath,
                    relativeTo: root,
                    isRelative: section.values["IsRelative"] != "0"
                )
                guard fileManager.fileExists(atPath: path.appendingPathComponent("prefs.js").path) else {
                    continue
                }

                let isDefault = section.values["Default"] == "1"
                if isDefault { defaultPaths.insert(path.standardizedFileURL.path) }
                found.append(ThunderbirdProfile(
                    name: section.values["Name"] ?? path.lastPathComponent,
                    path: path,
                    isDefault: isDefault
                ))
            }
        }

        // installs.ini names the profile used by a specific Thunderbird
        // installation and is the best default hint on newer versions.
        let installsIni = root.appendingPathComponent("installs.ini")
        if let text = try? String(contentsOf: installsIni, encoding: .utf8) {
            let document = IniDocument.parse(text)
            for section in document.sections {
                guard let rawPath = section.values["Default"], !rawPath.isEmpty else { continue }
                let path = resolve(path: rawPath, relativeTo: root, isRelative: true)
                guard fileManager.fileExists(atPath: path.appendingPathComponent("prefs.js").path) else {
                    continue
                }
                if !found.contains(where: { $0.id == path.standardizedFileURL.path }) {
                    if defaultPaths.isEmpty {
                        defaultPaths.insert(path.standardizedFileURL.path)
                    }
                    found.append(ThunderbirdProfile(
                        name: path.lastPathComponent,
                        path: path,
                        isDefault: defaultPaths.contains(path.standardizedFileURL.path)
                    ))
                }
            }
        }

        // profiles.ini is not always present (or may be stale). Scan the
        // Profiles directory as a fallback.
        let profilesDirectory = root.appendingPathComponent("Profiles", isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                var isProfileDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isProfileDirectory),
                      isProfileDirectory.boolValue,
                      fileManager.fileExists(atPath: entry.appendingPathComponent("prefs.js").path) else {
                    continue
                }
                if !found.contains(where: { $0.id == entry.standardizedFileURL.path }) {
                    found.append(ThunderbirdProfile(
                        name: entry.lastPathComponent,
                        path: entry.standardizedFileURL,
                        isDefault: false
                    ))
                }
            }
        }

        guard !found.isEmpty else {
            throw ThunderbirdImportError.profilesNotFound(root.path)
        }

        // If nothing was marked default, prefer the first discovered profile.
        if !found.contains(where: \.isDefault), !found.isEmpty {
            found[0].isDefault = true
        }

        found.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return found
    }

    /// Discovers profiles under every default Thunderbird data directory.
    public static func discoverAll(roots: [URL]? = nil) throws -> [ThunderbirdProfile] {
        let candidates = roots ?? defaultRoots()
        var profiles: [ThunderbirdProfile] = []
        var errors: [String] = []

        for root in candidates {
            do {
                profiles.append(contentsOf: try discover(root: root))
            } catch let error as ThunderbirdImportError {
                if case .rootNotFound = error {
                    continue
                }
                errors.append(error.localizedDescription)
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if profiles.isEmpty {
            if let first = errors.first {
                throw ThunderbirdImportError.unreadableProfile(first)
            }
            throw ThunderbirdImportError.profilesNotFound(
                candidates.map(\.path).joined(separator: ", ")
            )
        }

        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
    }

    private static func resolve(path: String, relativeTo root: URL, isRelative: Bool) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if isRelative {
            return root.appendingPathComponent(expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

// MARK: - prefs.js

public enum ThunderbirdPreference: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }
}

/// A minimal parser for the `user_pref("key", value);` lines in Thunderbird's
/// prefs.js. It intentionally ignores everything else in the file.
public struct ThunderbirdPrefs: Sendable, Equatable {
    public private(set) var values: [String: ThunderbirdPreference]

    public init(values: [String: ThunderbirdPreference] = [:]) {
        self.values = values
    }

    public subscript(_ key: String) -> ThunderbirdPreference? {
        values[key]
    }

    public func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    public func integer(_ key: String) -> Int? {
        values[key]?.intValue
    }

    public func boolean(_ key: String) -> Bool? {
        values[key]?.boolValue
    }

    public static func load(at url: URL) throws -> ThunderbirdPrefs {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return parse(contents)
        } catch {
            throw ThunderbirdImportError.unreadablePrefs(url.path)
        }
    }

    public static func parse(_ contents: String) -> ThunderbirdPrefs {
        var values: [String: ThunderbirdPreference] = [:]
        let normalized = contents
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("user_pref("),
                  let open = line.firstIndex(of: "(") else {
                continue
            }

            var index = line.index(after: open)
            skipWhitespace(in: line, index: &index)

            guard let (key, afterKey) = parseQuotedString(in: line, from: index) else {
                continue
            }
            index = afterKey
            skipWhitespace(in: line, index: &index)

            if index < line.endIndex, line[index] == "," {
                index = line.index(after: index)
            }
            skipWhitespace(in: line, index: &index)

            guard let (value, _) = parseValue(in: line, from: index) else {
                continue
            }
            values[key] = value
        }

        return ThunderbirdPrefs(values: values)
    }

    // MARK: Parsing helpers

    private static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static func parseQuotedString(
        in text: String,
        from start: String.Index
    ) -> (String, String.Index)? {
        guard start < text.endIndex, text[start] == "\"" else { return nil }

        var result = ""
        var index = text.index(after: start)

        while index < text.endIndex {
            let character = text[index]

            if character == "\"" {
                return (result, text.index(after: index))
            }

            if character != "\\" {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            let escapeIndex = text.index(after: index)
            guard escapeIndex < text.endIndex else { break }
            let escape = text[escapeIndex]

            switch escape {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "u", "x":
                let count = escape == "u" ? 4 : 2
                var cursor = text.index(after: escapeIndex)
                var digits = ""
                while cursor < text.endIndex, digits.count < count {
                    digits.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if digits.count == count,
                   let value = UInt32(digits, radix: 16),
                   let scalar = UnicodeScalar(value) {
                    result.append(Character(scalar))
                } else {
                    result.append(escape)
                    result.append(digits)
                }
                index = cursor
                continue
            default:
                result.append(escape)
            }

            index = text.index(after: escapeIndex)
        }

        return nil
    }

    private static func parseValue(
        in text: String,
        from start: String.Index
    ) -> (ThunderbirdPreference, String.Index)? {
        var index = start
        guard index < text.endIndex else { return nil }

        if text[index] == "\"" {
            guard let (value, end) = parseQuotedString(in: text, from: index) else { return nil }
            return (.string(value), end)
        }

        if text[index...].hasPrefix("true") {
            return (.boolean(true), text.index(index, offsetBy: 4))
        }
        if text[index...].hasPrefix("false") {
            return (.boolean(false), text.index(index, offsetBy: 5))
        }

        var digits = ""
        if text[index] == "-" {
            digits.append("-")
            index = text.index(after: index)
        }
        while index < text.endIndex, text[index].isNumber {
            digits.append(text[index])
            index = text.index(after: index)
        }
        if !digits.isEmpty, digits != "-", let value = Int(digits) {
            return (.integer(value), index)
        }

        // Unknown (usually a constant or expression). Keep the raw token as a
        // string so callers can still inspect it.
        let end = text[index...].firstIndex(of: ")") ?? text.endIndex
        let raw = text[index..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : (.string(raw), end)
    }
}

// MARK: - INI

struct IniDocument {
    struct Section {
        var name: String
        var values: [String: String]
    }

    var sections: [Section]

    static func parse(_ contents: String) -> IniDocument {
        var sections: [Section] = []
        var current: Section?

        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                if let current { sections.append(current) }
                current = Section(
                    name: String(line.dropFirst().dropLast()),
                    values: [:]
                )
                continue
            }

            guard let equals = line.firstIndex(of: "="), var section = current else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            section.values[key] = value
            current = section
        }

        if let current { sections.append(current) }
        return IniDocument(sections: sections)
    }
}
