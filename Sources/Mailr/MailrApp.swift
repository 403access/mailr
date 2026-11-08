import SwiftUI
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
