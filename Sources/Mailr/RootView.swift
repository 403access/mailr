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
    @State private var isDrawerOpen = false
    @GestureState private var drawerDragOffset: CGFloat = 0

    private let drawerWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack(path: $path) {
                MessageListView(compact: true) {
                    isDrawerOpen = true
                }
                .navigationDestination(for: MessageRoute.self) { route in
                    MessageDetailScreen(messageID: route.messageID)
                }
                #if DEBUG
                .onChange(of: model.selectedMessageID) { _, messageID in
                    guard ["message", "attachment"].contains(ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] ?? ""),
                          let messageID, path.isEmpty else {
                        return
                    }
                    path.append(MessageRoute(messageID: messageID))
                }
                #endif
            }
            .allowsHitTesting(!isDrawerOpen)
            .accessibilityHidden(isDrawerOpen)

            if isDrawerOpen {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                    .accessibilityHidden(true)

                MailboxDrawer(
                    onSelect: { selection in
                        model.selection = selection
                        path = NavigationPath()
                        closeDrawer()
                    },
                    onClose: closeDrawer
                )
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background {
                    Color.mailrWindowBackground.ignoresSafeArea()
                }
                .offset(x: drawerDragOffset)
                .gesture(drawerDismissGesture)
                .transition(.move(edge: .leading))
                .shadow(color: .black.opacity(0.18), radius: 20, x: 8)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isDrawerOpen)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: drawerDragOffset)
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] == "drawer" else { return }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            isDrawerOpen = true
        }
        #endif
    }

    private var drawerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drawerDragOffset) { value, state, _ in
                state = min(0, value.translation.width)
            }
            .onEnded { value in
                let shouldClose = value.translation.width < -80
                    || value.predictedEndTranslation.width < -180
                if shouldClose {
                    closeDrawer()
                }
            }
    }

    private func closeDrawer() {
        isDrawerOpen = false
    }
}
