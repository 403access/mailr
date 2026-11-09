import Foundation

// MARK: - Tags

/// A user-editable label that the host can apply to mail.
///
/// `detail` and `keywords` are only used to prompt the local classifier. They
/// are never sent anywhere except the Ollama instance on the host machine.
public struct MailTag: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var detail: String
    public var keywords: [String]
    public var colorHex: String
    public var symbolName: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        detail: String = "",
        keywords: [String] = [],
        colorHex: String = "#5B7CFA",
        symbolName: String = "tag",
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.keywords = keywords
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.sortIndex = sortIndex
    }

    /// The starter set shown on a fresh install. The UUIDs are deterministic so
    /// every client and the host agree on the same tag identity.
    public static let defaults: [MailTag] = [
        MailTag(
            id: UUID(uuidString: "A1100000-0000-4000-8000-000000000001")!,
            name: "Action Required",
            detail: "The sender expects a reply, a decision, or a task from the recipient.",
            keywords: ["please", "action", "respond", "reply", "confirm", "approve", "review", "deadline", "asap", "urgent"],
            colorHex: "#E85D75",
            symbolName: "exclamationmark.bubble.fill",
            isBuiltIn: true,
            sortIndex: 0
        ),
        MailTag(
            id: UUID(uuidString: "A1100000-0000-4000-8000-000000000002")!,
            name: "Newsletter",
            detail: "A newsletter, marketing message, product announcement, or promotional digest.",
            keywords: ["newsletter", "unsubscribe", "promotion", "offer", "sale", "digest", "marketing", "webinar"],
            colorHex: "#9B6BF2",
            symbolName: "newspaper.fill",
            isBuiltIn: true,
            sortIndex: 1
        ),
        MailTag(
            id: UUID(uuidString: "A1100000-0000-4000-8000-000000000003")!,
            name: "Receipt/Invoice",
            detail: "A receipt, invoice, order confirmation, shipping notice, or payment record.",
            keywords: ["receipt", "invoice", "order", "payment", "charged", "refund", "shipping", "tracking", "total"],
            colorHex: "#2FAE8F",
            symbolName: "doc.text.fill",
            isBuiltIn: true,
            sortIndex: 2
        ),
        MailTag(
            id: UUID(uuidString: "A1100000-0000-4000-8000-000000000004")!,
            name: "Notification",
            detail: "An automated alert, security notice, build result, or service notification.",
            keywords: ["notification", "alert", "security", "verify", "code", "sign-in", "build", "deploy", "failed"],
            colorHex: "#3D8BFF",
            symbolName: "bell.fill",
            isBuiltIn: true,
            sortIndex: 3
        ),
        MailTag(
            id: UUID(uuidString: "A1100000-0000-4000-8000-000000000005")!,
            name: "Personal",
            detail: "Mail from friends, family, or a personal contact rather than a company or automated system.",
            keywords: ["family", "dinner", "weekend", "birthday", "holiday", "personal", "thanks", "love"],
            colorHex: "#F08A4B",
            symbolName: "person.2.fill",
            isBuiltIn: true,
            sortIndex: 4
        ),
        MailTag(
            id: UUID(uuidString: "A1100000-0000-4000-8000-000000000006")!,
            name: "Work",
            detail: "Work-related mail: projects, meetings, colleagues, clients, or business communication.",
            keywords: ["meeting", "project", "client", "team", "report", "standup", "sprint", "contract", "office"],
            colorHex: "#5B7CFA",
            symbolName: "briefcase.fill",
            isBuiltIn: true,
            sortIndex: 5
        )
    ]
}

// MARK: - Assignments

public enum TagAssignmentSource: String, Codable, Hashable, Sendable {
    case automatic = "auto"
    case manual
}

public struct MailTagAssignment: Identifiable, Hashable, Codable, Sendable {
    public var tagID: UUID
    public var confidence: Double
    public var source: TagAssignmentSource

    public var id: UUID { tagID }

    public init(
        tagID: UUID,
        confidence: Double,
        source: TagAssignmentSource = .automatic
    ) {
        self.tagID = tagID
        self.confidence = confidence
        self.source = source
    }
}

/// One message together with the tags currently applied to it.
public struct TaggedMessage: Hashable, Codable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var uid: UInt32
    public var tags: [MailTagAssignment]

    public init(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        tags: [MailTagAssignment]
    ) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.uid = uid
        self.tags = tags
    }

    public var key: String {
        TaggedMessage.key(accountID: accountID, mailbox: mailbox, uid: uid)
    }

    public static func key(accountID: UUID, mailbox: String, uid: UInt32) -> String {
        "\(accountID.uuidString)|\(mailbox)#\(uid)"
    }
}

// MARK: - Classifier status and results

public struct MailClassifierStatus: Hashable, Codable, Sendable {
    public enum Backend: String, Codable, Hashable, Sendable {
        case ollama
        case keywords
        case disabled
    }

    public var available: Bool
    public var backend: Backend
    public var model: String
    public var baseURL: String
    public var message: String?

    public init(
        available: Bool,
        backend: Backend,
        model: String,
        baseURL: String,
        message: String? = nil
    ) {
        self.available = available
        self.backend = backend
        self.model = model
        self.baseURL = baseURL
        self.message = message
    }

    public static let disabled = MailClassifierStatus(
        available: false,
        backend: .disabled,
        model: "",
        baseURL: ""
    )
}

public struct MailTagClassification: Hashable, Codable, Sendable {
    public var tagID: UUID
    public var confidence: Double

    public init(tagID: UUID, confidence: Double) {
        self.tagID = tagID
        self.confidence = confidence
    }
}

public struct TaggingOutcome: Hashable, Sendable {
    public var classifications: [MailTagClassification]
    /// The backend that actually produced the result. It may differ from the
    /// configured backend when Ollama is unreachable and keyword matching is
    /// used as a fallback.
    public var backend: MailClassifierStatus.Backend
    public var error: String?

    public init(
        classifications: [MailTagClassification],
        backend: MailClassifierStatus.Backend,
        error: String? = nil
    ) {
        self.classifications = classifications
        self.backend = backend
        self.error = error
    }
}

// MARK: - Classifier configuration

public struct TaggingConfiguration: Hashable, Sendable {
    public var enabled: Bool
    public var baseURL: URL
    public var model: String
    public var timeout: TimeInterval
    public var minimumConfidence: Double
    public var maximumTags: Int
    public var maximumBodyCharacters: Int

    public init(
        enabled: Bool = true,
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = "qwen2.5:1.5b",
        timeout: TimeInterval = 60,
        minimumConfidence: Double = 0.4,
        maximumTags: Int = 2,
        maximumBodyCharacters: Int = 1_800
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.minimumConfidence = minimumConfidence
        self.maximumTags = maximumTags
        self.maximumBodyCharacters = maximumBodyCharacters
    }

    /// Reads optional `MAILR_OLLAMA_*` and `MAILR_CLASSIFY*` values from the
    /// host environment. Everything has a sensible low-resource default.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidateURLs: [URL]? = nil
    ) -> TaggingConfiguration {
        var values = environment
        // The installed LaunchAgent has no EnvironmentVariables block, so the
        // `.env` file in Application Support is the normal configuration path.
        if let found = try? DotEnv.loadFirst(
            at: candidateURLs ?? EnvironmentAccounts.defaultCandidateURLs()
        ) {
            values = found.dotEnv.merging(overrides: environment).values
        }

        var configuration = TaggingConfiguration()

        if let raw = values["MAILR_CLASSIFY"]?.lowercased() {
            configuration.enabled = !["0", "false", "no", "off", "disabled"].contains(raw)
        }
        if let raw = values["MAILR_OLLAMA_URL"],
           let url = URL(string: raw.contains("://") ? raw : "http://\(raw)") {
            configuration.baseURL = url
        }
        if let model = values["MAILR_OLLAMA_MODEL"], !model.isEmpty {
            configuration.model = model
        }
        if let raw = values["MAILR_OLLAMA_TIMEOUT"], let value = Double(raw), value > 0 {
            configuration.timeout = value
        }
        if let raw = values["MAILR_TAG_CONFIDENCE"], let value = Double(raw) {
            configuration.minimumConfidence = min(max(value, 0), 1)
        }
        if let raw = values["MAILR_TAG_MAX"], let value = Int(raw), value > 0 {
            configuration.maximumTags = min(value, 5)
        }
        return configuration
    }
}

// MARK: - Local classifier

/// Classifies one message with a small Ollama model, falling back to a
/// deterministic keyword matcher when Ollama is unavailable or returns
/// something that cannot be parsed.
public struct EmailTagClassifier: Sendable {
    public let configuration: TaggingConfiguration
    private let session: URLSession

    public init(
        configuration: TaggingConfiguration = TaggingConfiguration(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    /// Checks whether the Ollama server is reachable and whether the configured
    /// model is installed. This only talks to loopback by default.
    public func status() async -> MailClassifierStatus {
        guard configuration.enabled else { return .disabled }

        let endpoint = configuration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("tags")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = min(configuration.timeout, 5)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return MailClassifierStatus(
                    available: false,
                    backend: .ollama,
                    model: configuration.model,
                    baseURL: configuration.baseURL.absoluteString,
                    message: "Ollama responded with an unexpected status."
                )
            }
            let models = (try? JSONDecoder().decode(OllamaTagsResponse.self, from: data))?.models ?? []
            let installed = models.contains { model in
                model.name == configuration.model
                    || model.model == configuration.model
                    || model.name.hasPrefix(configuration.model + ":")
            }
            return MailClassifierStatus(
                available: installed,
                backend: installed ? .ollama : .keywords,
                model: configuration.model,
                baseURL: configuration.baseURL.absoluteString,
                message: installed
                    ? nil
                    : "Ollama is running, but \(configuration.model) is not installed. Run `ollama pull \(configuration.model)`."
            )
        } catch {
            return MailClassifierStatus(
                available: false,
                backend: .keywords,
                model: configuration.model,
                baseURL: configuration.baseURL.absoluteString,
                message: "Ollama is not reachable. Keyword matching will be used instead."
            )
        }
    }

    /// Classifies a message. The returned tags are filtered by confidence and
    /// capped at `maximumTags`; an empty array is a valid result.
    public func classify(message: MailMessage, tags: [MailTag]) async -> TaggingOutcome {
        let enabledTags = tags.filter(\.isEnabled)
        guard configuration.enabled, !enabledTags.isEmpty else {
            return TaggingOutcome(classifications: [], backend: .disabled)
        }

        let prompt = Self.prompt(for: message, tags: enabledTags, configuration: configuration)
        do {
            let response = try await generate(prompt: prompt)
            let parsed = Self.parse(response: response, tags: enabledTags, configuration: configuration)
            if let parsed {
                return TaggingOutcome(
                    classifications: parsed,
                    backend: .ollama,
                    error: nil
                )
            }
            let fallback = Self.keywordClassifications(
                for: message,
                tags: enabledTags,
                configuration: configuration
            )
            return TaggingOutcome(
                classifications: fallback,
                backend: .keywords,
                error: "The model returned an unexpected response; keyword matching was used instead."
            )
        } catch {
            return TaggingOutcome(
                classifications: Self.keywordClassifications(
                    for: message,
                    tags: enabledTags,
                    configuration: configuration
                ),
                backend: .keywords,
                error: error.localizedDescription
            )
        }
    }

    // MARK: Ollama request

    private func generate(prompt: String) async throws -> String {
        let endpoint = configuration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("generate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = OllamaGenerateRequest(
            model: configuration.model,
            prompt: prompt,
            stream: false,
            format: "json",
            options: OllamaGenerateOptions(
                temperature: 0,
                numPredict: 160,
                numCtx: 2_048
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClassifierError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw ClassifierError.server(status: http.statusCode, detail: detail)
        }
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        return decoded.response
    }

    // MARK: Prompting and parsing

    static func prompt(
        for message: MailMessage,
        tags: [MailTag],
        configuration: TaggingConfiguration
    ) -> String {
        // Short aliases are much easier for a 1–2B model to copy correctly than
        // 36-character UUIDs. The alias order is deterministic because it is
        // derived from the same `tags` array used by `parse(response:...)`.
        let tagLines = tags.enumerated().map { index, tag in
            var line = "T\(index + 1) = \(tag.name):"
            if !tag.detail.isEmpty {
                line += " \(tag.detail)"
            }
            if !tag.keywords.isEmpty {
                line += " Keywords: \(tag.keywords.joined(separator: ", "))."
            }
            return line
        }.joined(separator: "\n")

        let sender = message.summary.from.first.map { address in
            address.name.map { "\($0) <\(address.address)>" } ?? address.address
        } ?? "unknown"
        let body = Self.plainText(for: message)
        let clipped = String(body.prefix(max(0, configuration.maximumBodyCharacters)))

        return """
        You classify one email into the single best tag. Return JSON only, in this shape:
        {"tags":[{"id":"T1","confidence":0.0}]}
        Use at most two tags only when two clearly independent categories apply. The id must be one of the short aliases below.
        If no tag applies, return {"tags":[]}. Confidence must be between 0 and 1. Do not include explanations.

        Tags:
        \(tagLines)

        Email:
        From: \(sender)
        To: \(message.summary.to.map(\.address).joined(separator: ", "))
        Subject: \(message.summary.subject)
        Snippet: \(message.summary.snippet)
        Body:
        \(clipped)
        """
    }

    /// Converts `T1`, `t2`, or a bare `3` into a zero-based tag index.
    static func aliasIndex(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasPrefix("T"), let number = Int(trimmed.dropFirst()), number >= 1 {
            return number - 1
        }
        if let number = Int(trimmed), number >= 1 {
            return number - 1
        }
        return nil
    }

    static func parse(
        response: String,
        tags: [MailTag],
        configuration: TaggingConfiguration
    ) -> [MailTagClassification]? {
        guard let json = jsonObject(in: response),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawItems: [[String: Any]]
        if let items = object["tags"] as? [[String: Any]] {
            rawItems = items
        } else if object["id"] != nil {
            // Some small models ignore the array wrapper and return one object.
            rawItems = [object]
        } else if let item = object["tag"] as? [String: Any] {
            rawItems = [item]
        } else if let tag = object["tag"] as? String {
            rawItems = [["id": tag]]
        } else if let items = object["tags"] as? [String] {
            rawItems = items.map { ["name": $0] }
        } else {
            rawItems = []
        }

        var results: [MailTagClassification] = []
        for item in rawItems {
            let rawID = item["id"] as? String
            let rawName = item["name"] as? String
            let confidence = (item["confidence"] as? Double)
                ?? (item["confidence"] as? NSNumber)?.doubleValue
                ?? 0.75

            let tag = tags.first { tag in
                if let rawID {
                    if let index = aliasIndex(rawID), tags.indices.contains(index) {
                        return tags[index].id == tag.id
                    }
                    if tag.id.uuidString.caseInsensitiveCompare(rawID) == .orderedSame {
                        return true
                    }
                }
                if let rawName {
                    return tag.name.caseInsensitiveCompare(rawName) == .orderedSame
                }
                return false
            }
            guard let tag else { continue }
            let clamped = min(max(confidence, 0), 1)
            guard clamped >= configuration.minimumConfidence else { continue }
            if results.contains(where: { $0.tagID == tag.id }) { continue }
            results.append(MailTagClassification(tagID: tag.id, confidence: clamped))
        }

        results.sort { $0.confidence > $1.confidence }
        return Array(results.prefix(max(1, configuration.maximumTags)))
    }

    static func keywordClassifications(
        for message: MailMessage,
        tags: [MailTag],
        configuration: TaggingConfiguration
    ) -> [MailTagClassification] {
        let subject = message.summary.subject.lowercased()
        let sender = message.summary.senderAddress.lowercased()
        let body = plainText(for: message).lowercased()
        let haystack = "\(subject)\n\(sender)\n\(body)"

        var scored: [(MailTag, Double)] = []
        for tag in tags {
            var score = 0.0
            if subject.contains(tag.name.lowercased()) {
                score += 2
            }
            if haystack.contains(tag.name.lowercased()) {
                score += 1
            }
            for keyword in tag.keywords {
                let needle = keyword.lowercased()
                guard !needle.isEmpty else { continue }
                if subject.contains(needle) {
                    score += 1.5
                } else if body.contains(needle) {
                    score += 0.75
                }
            }
            guard score > 0 else { continue }
            let confidence = min(0.9, 0.45 + score * 0.08)
            guard confidence >= configuration.minimumConfidence else { continue }
            scored.append((tag, confidence))
        }

        scored.sort { $0.1 > $1.1 }
        return scored
            .prefix(max(1, configuration.maximumTags))
            .map { MailTagClassification(tagID: $0.0.id, confidence: $0.1) }
    }

    /// Finds the first complete JSON object in a model response, tolerating
    /// markdown fences or a short preface that some small models add.
    static func jsonObject(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    static func plainText(for message: MailMessage) -> String {
        if let text = message.text, !text.isEmpty {
            return text
        }
        if let html = message.html, !html.isEmpty {
            return stripHTML(html)
        }
        return message.summary.snippet
    }

    static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?is)<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

private enum ClassifierError: LocalizedError {
    case invalidResponse
    case server(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The local classifier returned an invalid response."
        case .server(let status, let detail):
            "The local classifier returned HTTP \(status): \(detail)"
        }
    }
}

// MARK: - Ollama wire types

private struct OllamaGenerateRequest: Encodable {
    var model: String
    var prompt: String
    var stream: Bool
    var format: String
    var options: OllamaGenerateOptions
}

private struct OllamaGenerateOptions: Encodable {
    var temperature: Double
    var numPredict: Int
    var numCtx: Int

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
        case numCtx = "num_ctx"
    }
}

private struct OllamaGenerateResponse: Decodable {
    var response: String
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        var name: String
        var model: String?
    }
    var models: [Model]
}
