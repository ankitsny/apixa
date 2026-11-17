import SwiftUI
import AppKit

@main
struct ApixaApp: App {
    @ViewState private var store = LibraryStore()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        SelfTest.runIfRequested()
    }

    /// `--uidemo <folder> <rate|adjust|info|looks|lookdetail|map>`: open straight into a screen (for UI review).
    private func uiDemo() async {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--uidemo"), i + 2 < a.count else { return }
        store.load(URL(fileURLWithPath: a[i + 1]))
        while store.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(800))
        if let s = store.visibleStacks.first(where: { $0.members.count > 2 }) { store.selectGroup(s.id) }
        switch a[i + 2] {
        case "adjust": store.inspectorTab = .adjust
        case "info": store.inspectorTab = .info
        case "looks": store.switchMode(.looks)
        case "lookdetail": store.switchMode(.looks); store.lookFocus = LookRecipe.presets.first { $0.base == .FL }
        case "map": store.switchMode(.map)
        default: store.inspectorTab = .rate
        }
        // Optional 4th argument: render the window to a PNG (works with the display asleep) and quit.
        guard i + 3 < a.count else { return }
        try? await Task.sleep(for: .seconds(a[i + 2].hasPrefix("look") ? 14 : 5))
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
           let v = w.contentView?.superview ?? w.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[i + 3]))
        }
        exit(0)
    }

    var body: some Scene {
        WindowGroup("Apixa") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .task { await uiDemo() }
        }
        .commands {
            // Single-key shortcuts must not fire while typing in a sheet (e.g. a place search).
            let typing = store.showGeotag || store.showSaveCopy || store.showSidecars || store.isEditingText
            let noPhoto = store.selectedAsset == nil

            CommandGroup(after: .newItem) {
                Button("Open Folder…") { store.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Copy…") { store.showSaveCopy = true }
                    .keyboardShortcut("s")
                    .disabled(noPhoto)
                Button("Write Metadata to Files…") { store.showSidecars = true }
                    .disabled(store.assets.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoTitle.map { "Undo \($0)" } ?? "Undo") { store.undo() }
                    .keyboardShortcut("z")
                    .disabled(store.undoTitle == nil || typing)
                Button(store.redoTitle.map { "Redo \($0)" } ?? "Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(store.redoTitle == nil || typing)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Edits") { store.copiedAdjustments = store.selectedAsset?.adjustments }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(noPhoto || typing)
                Button("Paste Edits to Selection") {
                    if let adj = store.copiedAdjustments {
                        let targets = store.selectedStackIDs.count > 1 ? store.selectedGroupAssets : [store.selectedAsset].compactMap { $0 }
                        store.pasteAdjustments(adj, to: targets)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(store.copiedAdjustments == nil || noPhoto || typing)
            }
            CommandGroup(after: .toolbar) {
                Button("Photo") { store.switchMode(.photo) }.keyboardShortcut("1")
                    .disabled(store.folder == nil)
                Button("Creative Looks") { store.switchMode(.looks) }.keyboardShortcut("2")
                    .disabled(store.assets.isEmpty)
                Button("Map") { store.switchMode(.map) }.keyboardShortcut("3")
                    .disabled(store.folder == nil)
                Divider()
                Button(store.showInspector ? "Hide Right Panel" : "Show Right Panel") { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button(store.showStrip ? "Hide Bottom Strip" : "Show Bottom Strip") { store.showStrip.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button(store.isFullScreen ? "Exit Viewer" : "Full-Screen Viewer") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled(typing)
                Divider()
                Picker("Compare Before / After", selection: Binding(get: { store.compareMode }, set: { store.compareMode = $0 })) {
                    ForEach(CompareMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Cycle Before / After") {
                    let all = CompareMode.allCases
                    store.compareMode = all[(all.firstIndex(of: store.compareMode)! + 1) % all.count]
                }
                .keyboardShortcut("y", modifiers: [])
                .disabled(typing || noPhoto)
                Button(store.showClipping ? "Hide Clipping" : "Show Clipping") { store.showClipping.toggle() }
                    .keyboardShortcut("j", modifiers: [])
                    .disabled(typing || noPhoto)
                Picker("Background", selection: Binding(get: { store.viewerBackground }, set: { store.viewerBackground = $0 })) {
                    ForEach(ViewerBackground.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Cycle Background") {
                    let all = ViewerBackground.allCases
                    store.viewerBackground = all[(all.firstIndex(of: store.viewerBackground)! + 1) % all.count]
                }
                .keyboardShortcut("g", modifiers: [])
                .disabled(typing)
                Divider()
                Button("Zoom to 100% / Fit") { ZoomCommand.toggle.post() }
                    .keyboardShortcut("z", modifiers: [])
                    .disabled(typing || noPhoto || store.cropMode)
                Button("Zoom In") { ZoomCommand.zoomIn.post() }
                    .keyboardShortcut("+")
                    .disabled(noPhoto || store.cropMode)
                Button("Zoom Out") { ZoomCommand.zoomOut.post() }
                    .keyboardShortcut("-")
                    .disabled(noPhoto || store.cropMode)
                Button("Actual Size") { ZoomCommand.actual.post() }
                    .keyboardShortcut("0")
                    .disabled(noPhoto || store.cropMode)
                Button("Fit in Window") { ZoomCommand.fit.post() }
                    .keyboardShortcut("9")
                    .disabled(noPhoto || store.cropMode)
                Divider()
            }
            CommandMenu("Cull") {
                Group {
                    Button("Keep") { store.mark(.keep) }
                        .keyboardShortcut("p", modifiers: [])
                    Button("Reject") { store.mark(.reject) }
                        .keyboardShortcut("x", modifiers: [])
                    Button("Clear Mark") { store.mark(.undecided) }
                        .keyboardShortcut("u", modifiers: [])
                    Divider()
                    ForEach(1...5, id: \.self) { r in
                        Button("Rate \(String(repeating: "★", count: r))") { store.rateSelected(r) }
                            .keyboardShortcut(KeyEquivalent(Character("\(r)")), modifiers: [])
                    }
                    Button("Automatic Rating") { store.rateSelected(nil) }
                        .keyboardShortcut("0", modifiers: [])
                }
                .disabled(typing || noPhoto)
                Divider()
                Group {
                    Button(store.browsingLooks ? "Previous Look" : "Previous Photo in Group") { store.arrowHorizontal(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button(store.browsingLooks ? "Next Look" : "Next Photo in Group") { store.arrowHorizontal(1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button(store.browsingLooks ? "Previous Photo" : "Previous Group") { store.arrowVertical(-1) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button(store.browsingLooks ? "Next Photo" : "Next Group") { store.arrowVertical(1) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                }
                .disabled(typing)
                Divider()
                Group {
                    Button("Keep Best in This Stack") { store.keepBestInSelectedStack() }
                        .keyboardShortcut("b", modifiers: [])
                    Button("Keep Best in All Stacks…") { store.showAutoPickConfirm = true }
                        .disabled(store.stacks.isEmpty)
                    Button("Clear All Marks") { store.clearAllMarks() }
                    Divider()
                    Button(store.previewRaw ? "Show JPEG" : "Show RAW") { store.togglePreviewRaw() }
                        .keyboardShortcut("r", modifiers: [])
                    Button("Set Location…") { store.showGeotag = true }
                        .keyboardShortcut("l")
                        .disabled(noPhoto)
                    Button(store.cropMode ? "Finish Crop" : "Crop & Straighten") {
                        store.cropMode ? store.endCrop(apply: true) : store.beginCrop()
                    }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(noPhoto || store.isFullScreen)
                }
                .disabled(typing)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
