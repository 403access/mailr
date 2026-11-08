import SwiftUI
import MailCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        ZStack {
            MailrBackground()

            Group {
                if horizontalSizeClass == .compact {
                    CompactRootView()
                } else {
                    RegularRootView()
                }
            }
            .allowsHitTesting(!lock.isLocked)
            .accessibilityHidden(lock.isLocked)

            if lock.isLocked {
                LockScreenView()
                    .environment(lock)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .modifier(MailrWindowSizing())
        .preferredColorScheme(.light)
        .tint(MailrTheme.accent)
        .animation(.easeInOut(duration: 0.18), value: lock.isLocked)
        .sheet(item: $model.compose) { draft in
            ComposeView(draft: draft)
                .environment(model)
                .mailrLargeDetent()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environment(model)
                .environment(lock)
                .mailrLargeDetent()
        }
        .alert(
            "Mailr",
            isPresented: Binding(
                get: { model.errorMessage != nil && !lock.isLocked },
                set: { newValue in if !newValue { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let status = model.statusText, !lock.isLocked {
                Text(status)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(MailrTheme.accentGradient, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: MailrTheme.accent.opacity(0.35), radius: 16, y: 8)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.statusText)
        .task { await model.start() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                lock.lock()
            } else if oldPhase == .background, newPhase == .active, !lock.isLocked {
                Task { await model.refreshAll() }
            }
        }
        .onChange(of: lock.isLocked) { wasLocked, isLocked in
            if isLocked {
                model.suspendForLock()
            } else if wasLocked {
                model.restoreAfterUnlock()
                if model.hasLoadedInitialMail {
                    Task { await model.refreshAll() }
                }
            }
        }
    }
}

struct RegularRootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if model.isShowingOverview {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .mailrSidebarWidth()
            } detail: {
                OverviewView()
                    .mailrDetailWidth()
            }
            .navigationSplitViewStyle(.balanced)
        } else {
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
                Group {
                    if model.isShowingOverview {
                        OverviewView(compact: true) {
                            isDrawerOpen = true
                        }
                    } else {
                        MessageListView(compact: true) {
                            isDrawerOpen = true
                        }
                    }
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
                MailrTheme.ink.opacity(0.34)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                    .accessibilityHidden(true)

                MailboxDrawer(
                    onSelect: { selection in
                        model.selectMailbox(selection)
                        path = NavigationPath()
                        closeDrawer()
                    },
                    onSelectOverview: {
                        model.showOverview()
                        path = NavigationPath()
                        closeDrawer()
                    },
                    onClose: closeDrawer
                )
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background {
                    ZStack {
                        MailrTheme.baseTop
                        LinearGradient(
                            colors: [MailrTheme.violet.opacity(0.14), MailrTheme.cyan.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .ignoresSafeArea()
                }
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 30,
                        topTrailingRadius: 30,
                        style: .continuous
                    )
                )
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 30,
                        topTrailingRadius: 30,
                        style: .continuous
                    )
                    .strokeBorder(MailrTheme.border, lineWidth: 1)
                }
                .offset(x: drawerDragOffset)
                .gesture(drawerDismissGesture)
                .transition(.move(edge: .leading))
                .shadow(color: MailrTheme.accent.opacity(0.20), radius: 30, x: 12)
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
