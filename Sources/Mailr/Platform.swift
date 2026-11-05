import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Platform helpers

extension View {
    /// `.help` exists on macOS only.
    @ViewBuilder
    func mailrHelp(_ text: String) -> some View {
        #if os(macOS)
        self.help(text)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mailrInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mailrNumberPad() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mailrLargeDetent() -> some View {
        #if os(iOS)
        self.presentationDetents([.large])
        #else
        self
        #endif
    }

    @ViewBuilder
    func mailrGroupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    /// Comfortable content width for iPad sheets/readers.
    @ViewBuilder
    func mailrReadableWidth() -> some View {
        #if os(iOS)
        self.frame(maxWidth: 900)
        #else
        self
        #endif
    }
}

extension Color {
    static var mailrWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

enum URLOpener {
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Platform sizing

struct MailrWindowSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 1050, minHeight: 640)
        #else
        content
        #endif
    }
}

struct ComposeSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(width: 740, height: 640)
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

struct SettingsSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(width: 700, height: 520)
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

struct AccountEditorSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(width: 660, height: 720)
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

// MARK: - Column widths (macOS only modifier)

extension View {
    @ViewBuilder
    func mailrSidebarWidth() -> some View {
        #if os(macOS)
        self.navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 340)
        #else
        self.navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        #endif
    }

    @ViewBuilder
    func mailrListWidth() -> some View {
        #if os(macOS)
        self.navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 540)
        #else
        self.navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 430)
        #endif
    }

    @ViewBuilder
    func mailrDetailWidth() -> some View {
        #if os(macOS)
        self.navigationSplitViewColumnWidth(min: 480, ideal: 700)
        #else
        self.navigationSplitViewColumnWidth(min: 320, ideal: 560)
        #endif
    }
}
