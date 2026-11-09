import SwiftUI
import MailCore

// MARK: - Colors

func mailrTagColor(_ hex: String) -> Color {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let number = UInt64(value, radix: 16) else {
        return MailrTheme.accent
    }
    return Color(
        red: Double((number >> 16) & 0xFF) / 255,
        green: Double((number >> 8) & 0xFF) / 255,
        blue: Double(number & 0xFF) / 255
    )
}

// MARK: - Chips

struct TagChip: View {
    let tag: MailTag
    var compact: Bool = false
    var selected: Bool? = nil

    private var color: Color { mailrTagColor(tag.colorHex) }
    private var isHighlighted: Bool { selected ?? false }

    var body: some View {
        HStack(spacing: compact ? 3.5 : 5) {
            Image(systemName: tag.symbolName)
                .font(.system(size: compact ? 8.5 : 9.5, weight: .bold))
            Text(tag.name)
                .font(.system(
                    size: compact ? 9.5 : 10.5,
                    weight: .semibold,
                    design: .rounded
                ))
                .lineLimit(1)
        }
        .foregroundStyle(isHighlighted ? Color.white : color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2.5 : 4)
        .background(
            isHighlighted ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.11)),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(isHighlighted ? 0 : 0.20), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag: \(tag.name)")
    }
}

struct TagFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Button {
                    model.clearTagFilter()
                } label: {
                    Text("All mail")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            model.selectedTagFilter == nil ? Color.white : MailrTheme.inkSecondary
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            model.selectedTagFilter == nil
                                ? AnyShapeStyle(MailrTheme.accentGradient)
                                : AnyShapeStyle(MailrTheme.surfaceSoft),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)

                ForEach(model.enabledTags) { tag in
                    Button {
                        model.selectedTagFilter = model.selectedTagFilter == tag.id ? nil : tag.id
                    } label: {
                        TagChip(tag: tag, compact: true, selected: model.selectedTagFilter == tag.id)
                    }
                    .buttonStyle(.plain)
                }

                if model.isClassifyingTags {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background(MailrTheme.surfaceSoft)
    }
}

struct TagPickerMenu: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary

    var body: some View {
        Menu {
            if model.enabledTags.isEmpty {
                Text("No tags configured")
            } else {
                ForEach(model.enabledTags) { tag in
                    Button {
                        Task { await model.toggleTag(tag, on: message) }
                    } label: {
                        Label(
                            tag.name,
                            systemImage: model.hasTag(tag, on: message)
                                ? "checkmark.circle.fill"
                                : tag.symbolName
                        )
                    }
                }
            }

            Divider()

            Button {
                Task { await model.classifyCurrentMailbox(force: true) }
            } label: {
                Label("Classify this mailbox", systemImage: "wand.and.stars")
            }

            Button {
                model.showSettings = true
            } label: {
                Label("Manage Tags…", systemImage: "tag")
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
    }
}

// MARK: - Tag settings

struct TagSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var editorRequest: TagEditorRequest?

    private struct TagEditorRequest: Identifiable {
        let id = UUID()
        let tag: MailTag?
    }

    var body: some View {
        NavigationStack {
            List {
                classifierSection
                tagsSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { MailrBackground() }
            .navigationTitle("Tags & Classification")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorRequest = TagEditorRequest(tag: nil)
                    } label: {
                        Label("Add Tag", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorRequest) { request in
                TagEditorView(tag: request.tag)
                    .environment(model)
            }
            .task { await model.refreshClassifierStatus() }
        }
    }

    private var classifierSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(classifierColor.opacity(0.13))
                    Image(systemName: classifierSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(classifierColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(classifierTitle)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                    Text(classifierDetail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if model.isClassifyingTags {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)

            Button {
                Task { await model.classifyCurrentMailbox(force: true) }
            } label: {
                Label("Classify current mailbox now", systemImage: "wand.and.stars")
            }
            .disabled(model.selection == nil || model.isClassifyingTags)

            Button {
                Task { await model.refreshClassifierStatus() }
            } label: {
                Label("Check local model", systemImage: "bolt.horizontal.circle")
            }
        } header: {
            Text("Local classifier")
        } footer: {
            Text("Mailr asks a small model running in Ollama on the host Mac to tag mail. If Ollama is not running, a fast keyword matcher is used instead. Email text never leaves your network.")
        }
    }

    private var tagsSection: some View {
        Section {
            ForEach(model.tags) { tag in
                Button {
                    editorRequest = TagEditorRequest(tag: tag)
                } label: {
                    HStack(spacing: 11) {
                        TagChip(tag: tag, compact: true)
                        Spacer()
                        if !tag.isEnabled {
                            Text("OFF")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(MailrTheme.inkTertiary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MailrTheme.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await model.deleteTag(tag) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Tags")
        } footer: {
            Text("Descriptions and keywords guide the classifier. You can always add or remove a tag manually from a message.")
        }
    }

    private var classifierTitle: String {
        guard let status = model.classifierStatus else { return "Checking…" }
        switch status.backend {
        case .ollama:
            return status.available ? "Ollama ready" : "Ollama needs the model"
        case .keywords:
            return "Keyword fallback"
        case .disabled:
            return "Classification disabled"
        }
    }

    private var classifierDetail: String {
        guard let status = model.classifierStatus else {
            return "Looking for a local Ollama instance."
        }
        if let message = status.message { return message }
        if status.available {
            return "\(status.model) · \(status.baseURL)"
        }
        return "Tags will still be suggested from keywords."
    }

    private var classifierColor: Color {
        guard let status = model.classifierStatus else { return MailrTheme.inkTertiary }
        switch status.backend {
        case .ollama: return MailrTheme.mint
        case .keywords: return MailrTheme.amber
        case .disabled: return MailrTheme.inkTertiary
        }
    }

    private var classifierSymbol: String {
        guard let status = model.classifierStatus else { return "ellipsis" }
        switch status.backend {
        case .ollama: return status.available ? "bolt.fill" : "exclamationmark.triangle.fill"
        case .keywords: return "text.magnifyingglass"
        case .disabled: return "power"
        }
    }
}

struct TagEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let tag: MailTag?

    @State private var name: String
    @State private var detail: String
    @State private var keywords: String
    @State private var colorHex: String
    @State private var symbolName: String
    @State private var isEnabled: Bool
    @State private var confirmDelete = false

    init(tag: MailTag?) {
        self.tag = tag
        _name = State(initialValue: tag?.name ?? "")
        _detail = State(initialValue: tag?.detail ?? "")
        _keywords = State(initialValue: tag?.keywords.joined(separator: ", ") ?? "")
        _colorHex = State(initialValue: tag?.colorHex ?? "#5B7CFA")
        _symbolName = State(initialValue: tag?.symbolName ?? "tag.fill")
        _isEnabled = State(initialValue: tag?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Tag name", text: $name)
                }

                Section {
                    TextField("What belongs in this tag?", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Keywords, comma separated", text: $keywords, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Guidance")
                } footer: {
                    Text("The description and keywords are sent only to the local Ollama model on the host Mac.")
                }

                Section("Appearance") {
                    HStack(spacing: 8) {
                        ForEach(Self.palette, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(mailrTagColor(hex))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        if colorHex == hex {
                                            Circle()
                                                .strokeBorder(Color.white, lineWidth: 2)
                                                .padding(2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    TextField("SF Symbol", text: $symbolName)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                if let tag {
                    if tag.isBuiltIn {
                        Section {
                            Text("This is a starter tag. You can rename it or remove it; Mailr will not re-create it.")
                                .font(.footnote)
                                .foregroundStyle(MailrTheme.inkSecondary)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete Tag", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(
                "Delete “\(tag?.name ?? "tag")”?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Tag", role: .destructive) {
                    guard let tag else { return }
                    Task { await model.deleteTag(tag) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Messages keep their other tags. This cannot be undone.")
            }
        }
    }

    private func save() {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }

        let updated = MailTag(
            id: tag?.id ?? UUID(),
            name: cleanedName,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: keywords
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            colorHex: colorHex,
            symbolName: symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "tag.fill"
                : symbolName.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: isEnabled,
            isBuiltIn: tag?.isBuiltIn ?? false,
            sortIndex: tag?.sortIndex ?? model.tags.count
        )
        Task { await model.saveTag(updated) }
        dismiss()
    }

    private static let palette = [
        "#5B7CFA",
        "#9B6BF2",
        "#E85D75",
        "#F08A4B",
        "#2FAE8F",
        "#3D8BFF",
        "#D4A72C",
        "#6B7A90"
    ]
}
