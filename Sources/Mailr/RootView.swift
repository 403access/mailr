import SwiftUI
import MailCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        Group {
            if horizontalSizeClass == .compact {
                CompactRootView()
            } else {
                RegularRootView()
            }
        }
        .modifier(MailrWindowSizing())
        .sheet(item: $model.compose) { draft in
            ComposeView(draft: draft)
                .environment(model)
                .mailrLargeDetent()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environment(model)
                .mailrLargeDetent()
        }
        .alert(
            "Mailr",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { newValue in if !newValue { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let status = model.statusText {
                Text(status)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.statusText)
        .task { await model.start() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .background, newPhase == .active else { return }
            Task { await model.refreshAll() }
        }
    }
}

struct RegularRootView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .mailrSidebarWidth()
        } content: {
            MessageListView()
                .mailrListWidth()
        } detail: {
            MessageDetailView()
                .mailrDetailWidth()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct CompactRootView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            CompactMailboxListView { selection in
                model.selection = selection
                path.append(selection)
            }
            .navigationTitle("Mailr")
            .navigationDestination(for: MailboxSelection.self) { _ in
                MessageListView(compact: true)
                    .mailrInlineNavigationTitle()
            }
            #if DEBUG
            .onChange(of: model.selection) { _, selection in
                guard ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] == "inbox",
                      path.isEmpty, let selection else {
                    return
                }
                path.append(selection)
            }
            .onChange(of: model.selectedMessageID) { _, messageID in
                guard ["message", "attachment"].contains(ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] ?? ""),
                      let messageID else {
                    return
                }

                Task { @MainActor in
                    if path.isEmpty, let selection = model.selection {
                        path.append(selection)
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    path.append(MessageRoute(messageID: messageID))
                }
            }
            #endif
        }
    }
}
