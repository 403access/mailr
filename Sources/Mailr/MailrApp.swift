import SwiftUI
import MailCore
#if os(macOS)
import AppKit
#endif

@main
struct MailrApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var model = AppModel()
    @State private var lock = AppLock()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(model)
                .environment(lock)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    model.newCompose()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Refresh Mail") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isRefreshing)
            }

            CommandMenu("Message") {
                Button("Reply") {
                    model.replyToCurrentMessage()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.currentMessage == nil)

                Divider()

                Button("Mark as Read") {
                    model.markRead()
                }
                .disabled(model.currentMessage == nil)

                Button("Mark as Unread") {
                    model.markUnread()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.currentMessage == nil)

                Button("Delete") {
                    model.delete()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.currentMessage == nil)
            }
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .environment(lock)
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hostArchive: HostMailServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        startHostArchiveIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Start the loopback host archive when the Mac app is the archive host.
    /// If a standalone `MailrServer` already owns the port, binding fails and
    /// the client simply keeps using that server.
    private func startHostArchiveIfNeeded() {
        guard let configuration = HostMailConfiguration.load() else { return }
        let host = configuration.baseURL.host?.lowercased() ?? ""
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return
        }
        let port = UInt16(configuration.baseURL.port ?? 8787)
        let server = HostMailServer(
            port: port,
            database: MailDatabase(fileURL: MailDatabase.hostURL)
        )
        do {
            try server.start()
            hostArchive = server
            print("Mailr host archive listening on \(configuration.displayAddress)")
        } catch {
            // Port already owned by a standalone MailrServer; use it instead.
        }
    }
}
#endif
