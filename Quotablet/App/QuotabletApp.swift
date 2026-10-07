import AppKit
import SwiftUI

@MainActor
final class QuotabletAppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var terminationTask: Task<Void, Never>?
    private var shutdownComplete = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await store.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownComplete { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.shutdown()
            self.shutdownComplete = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct QuotabletApp: App {
    @NSApplicationDelegateAdaptor(QuotabletAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
