import AppKit
import SwiftUI

@main
struct OrbiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Orbite", id: "main") {
            RootView()
                .environment(model)
                // No scroll bars anywhere: lists and panels scroll without them, sheets included.
                .scrollIndicators(.never)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1480, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Export…") { model.ui.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Map") {
                Button("Search Everything…") { model.ui.showPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Recenter") { model.ui.recenterRequest += 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Deselect All") { model.ui.selection = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                Picker("Period", selection: Binding(
                    get: { model.store.window.span },
                    set: { model.store.window = TimeWindow(span: $0, end: nil) })) {
                    ForEach(WindowSpan.allCases) { span in
                        Text(span.longLabel.capitalizedFirst).tag(span)
                    }
                }
                Divider()
                Button("Journal…") { model.ui.showJournal = true }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Why Is It Slow?") { model.ui.showDiagnosis = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(model.replay == nil ? "Replay the Day" : "Stop the Replay") {
                    if model.replay == nil { model.startReplay() } else { model.stopReplay() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Weekly Recap") { model.ui.showRecap = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Show Inspector") { model.ui.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .scrollIndicators(.never)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With the menu bar item on, closing the window leaves Orbite measuring in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: ViewState.menuBarKey)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.current?.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .orbiteReopen, object: nil) }
        return true
    }
}
