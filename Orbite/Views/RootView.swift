import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            // A closed window stays alive in SwiftUI: without its views (map, rows, animations)
            // Orbite only measures and draws its menu bar item.
            if model.ui.windowOpen { content } else { Color.clear }
        }
        .onAppear {
            model.setWindowOpen(true)
            // The menu bar panel lives outside the SwiftUI scenes: hand it the scene actions.
            model.ui.openMainWindow = { [openWindow] in openWindow(id: "main") }
            model.ui.openSettingsWindow = { [openSettings] in openSettings() }
            // However the window came back (Dock, panel, relaunch), it brings its Dock icon.
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        }
    }

    private var content: some View {
        @Bindable var ui = model.ui
        let hide = ProcessInfo.processInfo.environment["ORBITE_HIDE"] ?? ""
        return NavigationSplitView(columnVisibility: $columns) {
            if hide.contains("sidebar") { Color.clear } else {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
            }
        } detail: {
            Group {
                if hide.contains("map") { Color.gray } else { MapScreen() }
            }
                .inspector(isPresented: $ui.showInspector) {
                    if hide.contains("inspector") { Color.clear } else {
                        InspectorView()
                            .inspectorColumnWidth(min: 310, ideal: 360, max: 480)
                    }
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.ui.windowWidth = $0 }
        .toolbar(removing: .title)
        // The map runs under the toolbar: no bar behind the buttons.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { ui.showPalette.toggle() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search everything (⌘K)")
            }
            ToolbarItem(placement: .primaryAction) {
                let unseen = model.journal.unseen.count
                Button {
                    ui.showJournal = true
                } label: {
                    Label {
                        Text("Journal")
                    } icon: {
                        Image(systemName: "book.pages")
                            .overlay(alignment: .topTrailing) {
                                if unseen > 0 {
                                    Circle().fill(Theme.download).frame(width: 7, height: 7).offset(x: 4, y: -3)
                                }
                            }
                    }
                }
                .help(unseen > 0 ? "Journal: \(Format.plural(unseen, "new item", "new items"))"
                      : "Journal: every first time of your Mac on the network")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Map Style", selection: $ui.mapLook) {
                        ForEach(MapLook.allCases) { look in
                            Label(look.label, systemImage: look.symbol).tag(look)
                        }
                    }
                    .pickerStyle(.inline)
                    if ui.mapLook == .globe {
                        Divider()
                        Toggle("Day and Night", systemImage: "sun.horizon", isOn: $ui.globeDayNight)
                    }
                } label: {
                    Label("Map Style", systemImage: ui.mapLook.symbol)
                }
                .help("Map Style")

                Button {
                    ui.showDiagnosis = true
                } label: {
                    Label("Why Is It Slow?", systemImage: "stethoscope")
                }
                .help("Why is it slow? Network diagnosis")

                Button {
                    model.ui.recenterRequest += 1
                } label: {
                    Label("Recenter", systemImage: "scope")
                }
                .help(ui.mapLook == .globe
                      ? "Recenter the globe on this Mac"
                      : "Frame the places (those of the selection, if any)")
            }
        }
        // The inspector opens by itself on whatever gets selected; its header's ✕ closes it.
        .onChange(of: ui.selection) { _, selection in
            if selection != nil, !ui.showInspector {
                withAnimation(Theme.selection) { ui.showInspector = true }
            }
        }
        .onExitCommand {
            withAnimation(Theme.selection) { model.ui.selection = nil }
        }
        .sheet(isPresented: $ui.showJournal) {
            JournalView().environment(model)
        }
        .sheet(isPresented: $ui.showDiagnosis) {
            DiagnosisView().environment(model)
        }
        .sheet(isPresented: $ui.showExport) {
            ExportSheet().environment(model)
        }
        .overlay {
            if ui.showRecap {
                RecapView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay {
            if ui.showPalette {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: ui.showRecap)
        .animation(.snappy(duration: 0.2), value: ui.showPalette)
    }
}
