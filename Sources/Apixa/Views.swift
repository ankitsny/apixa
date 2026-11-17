import SwiftUI
import AppKit
import MapKit

// MARK: - Root

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @ViewState private var showTrashConfirm = false
    @AppStorage(PanelWidth.sidebar.key) private var sidebarWidth = PanelWidth.sidebar.default

    var body: some View {
        @Bindable var store = store

        Group {
            if store.isFullScreen {
                FullScreenViewer()
            } else {
                library
            }
        }
        .toolbarVisibility(store.isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .sheet(isPresented: $store.showGeotag) { GeotagSheet().environment(store) }
        .sheet(isPresented: $store.showSaveCopy) { SaveCopySheet().environment(store) }
        .sheet(isPresented: $store.showSidecars) { SidecarSheet().environment(store) }
        .confirmationDialog("Move \(store.rejectFileCount) file(s) to the Trash?", isPresented: $showTrashConfirm) {
            Button("Move to Trash", role: .destructive) { store.trashRejects() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(store.rejectCount) rejected shot(s), trashing: \(store.trashMode.rawValue). Undo with ⌘Z, or restore from the Trash.")
        }
        .confirmationDialog("Keep the best shot in every stack?", isPresented: $store.showAutoPickConfirm) {
            let p = store.autoPickPreview
            Button("Mark \(p.keeps + p.rejects) Shots") { store.autoPickAll() }
                .disabled(p.keeps + p.rejects == 0)
            Button("Cancel", role: .cancel) {}
        } message: {
            let p = store.autoPickPreview
            Text("In \(p.stacks) stack(s): keep \(p.keeps) best shot(s), reject \(p.rejects) other(s). Shots you already marked are not changed. Nothing is deleted, and ⌘Z undoes it.")
        }
        .onChange(of: store.maxGap) { store.restack() }
        .onChange(of: store.looseness) { store.restack() }
        .onChange(of: store.accurateRaw) { store.reanalyze(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            store.isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            store.isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flushSave()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            store.load(isDir ? u : u.deletingLastPathComponent())
            return true
        }
    }

    private var library: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(sidebarWidth)
        } detail: {
            if store.folder == nil {
                WelcomeView()
            } else if store.mainMode == .map {
                MapHeatView()
            } else if store.mainMode == .looks, let a = store.selectedAsset {
                LooksView(asset: a)
            } else if let stack = store.selectedStack {
                StackDetailView(stack: stack)
            } else if store.isScanning {
                ProgressView("Analyzing photos…")
            } else {
                Text("No photos found").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.folder?.lastPathComponent ?? "Apixa")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.chooseFolder() } label: { Label("Open Folder", systemImage: "folder") }
                    .help("Open a folder of photos (⌘O)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { store.mainMode }, set: { store.switchMode($0) })) {
                    ForEach(MainMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(store.folder == nil)
                .help("Photo (⌘1) · Creative Looks (⌘2) · Map (⌘3)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isScanning {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(store.progress), total: Double(max(store.total, 1)))
                            .frame(width: 110)
                        Text("\(store.progress)/\(store.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button { store.showGeotag = true } label: { Label("Location", systemImage: "mappin.and.ellipse") }
                    .labelStyle(.titleAndIcon)
                    .help("Set the location of one or many shots (⌘L)")
                    .disabled(store.selectedAsset == nil)
                Button { store.showSaveCopy = true } label: { Label("Save Copy", systemImage: "square.and.arrow.down") }
                    .labelStyle(.titleAndIcon)
                    .help("Save edited copies — originals are never changed (⌘S)")
                    .disabled(store.selectedAsset == nil)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full-screen viewer (F). ↑ ↓ groups, ← → shots in a group, Esc to exit")
                Button(role: .destructive) { showTrashConfirm = true } label: {
                    Label(store.rejectCount == 0 ? "Trash" : "Trash \(store.rejectCount) Rejected", systemImage: "trash")
                }
                .labelStyle(.titleAndIcon)
                .help("Move rejected photos to the Trash (undo with ⌘Z)")
                .disabled(store.rejectCount == 0)
            }
        }
    }
}

struct WelcomeView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Apixa").font(.largeTitle.bold())
            Text("Open the folder you copied from your SD card, or drop it here.\nSimilar shots get stacked and rated by sharpness, exposure and faces.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Folder…") { store.chooseFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

// MARK: - Settings window (⌘,)

/// Panel widths shared by the panels themselves (drag to resize) and Settings ▸ Layout.
enum PanelWidth {
    static let sidebar = (key: "sidebarWidth", default: 270.0, range: 200.0...480.0)
    static let photo = (key: "inspectorWidth", default: 320.0, range: 260.0...620.0)
    static let looks = (key: "lookPanelWidth", default: 320.0, range: 260.0...620.0)
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @ViewState private var calibrating = false
    @ViewState private var calibrationReport = ""
    @ViewState private var learnedVersion = 0
    @AppStorage(PanelWidth.sidebar.key) private var sidebarWidth = PanelWidth.sidebar.default
    @AppStorage(PanelWidth.photo.key) private var photoPanelWidth = PanelWidth.photo.default
    @AppStorage(PanelWidth.looks.key) private var looksPanelWidth = PanelWidth.looks.default

    private func widthRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 10)
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Files", systemImage: "doc.badge.gearshape") { files }
            Tab("Looks", systemImage: "camera.filters") { looks }
            Tab("Layout", systemImage: "sidebar.squares.right") { layout }
        }
        .frame(width: 540)
        .frame(minHeight: 420)
    }

    private var layout: some View {
        Form {
            Section("Panel widths") {
                widthRow("Left sidebar", $sidebarWidth, PanelWidth.sidebar.range)
                widthRow("Right panel · Photo", $photoPanelWidth, PanelWidth.photo.range)
                widthRow("Right panel · Looks", $looksPanelWidth, PanelWidth.looks.range)
                HStack {
                    Text("You can also drag a right panel's edge; double-click the edge to reset it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        sidebarWidth = PanelWidth.sidebar.default
                        photoPanelWidth = PanelWidth.photo.default
                        looksPanelWidth = PanelWidth.looks.default
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        @Bindable var store = store
        return Form {
            Section("Stacking") {
                LabeledContent("Max time gap") {
                    HStack {
                        Slider(value: $store.maxGap, in: 1...300)
                        Text("\(Int(store.maxGap)) s").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Similarity") {
                    HStack {
                        Slider(value: $store.looseness, in: 0.2...1.0) {
                            EmptyView()
                        } minimumValueLabel: { Text("Strict").font(.caption) } maximumValueLabel: { Text("Loose").font(.caption) }
                        Text(String(format: "%.2f", store.looseness)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Text("Changing these regroups instantly — no re-analysis needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Analysis") {
                Toggle("Accurate RAW analysis", isOn: $store.accurateRaw)
                    .disabled(store.isScanning)
                Text("Scores sharpness, exposure and blown highlights from the RAW itself (RAW 9) instead of the camera JPEG. Better at telling recoverable highlights from truly clipped ones. About 2 s per shot instead of ~10 ms, once per photo (results are cached).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Analyze New & Changed Shots") { store.reanalyze(force: false) }
                    Button("Re-analyze Everything") { store.reanalyze(force: true) }
                }
                .disabled(store.isScanning || store.assets.isEmpty)
                Text("Reopening a folder only analyzes new or changed files. Marks, ratings, edits and locations are kept either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Trash") {
                Picker("For rejected shots, trash", selection: $store.trashMode) {
                    ForEach(TrashMode.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var files: some View {
        @Bindable var store = store
        return Form {
            Section("Original Files") {
                Toggle("Write locations into files", isOn: $store.writeLocationToFiles)
                Toggle("Write your star ratings into files", isOn: $store.writeRatingToFiles)
                Toggle("Write Keep / Reject as Green / Red labels", isOn: $store.writeLabelToFiles)
                Text("Metadata only. JPEG and HEIC files get their metadata replaced in place; the image data is copied byte-for-byte, so quality is untouched. RAW files get a standard .xmp sidecar (macOS can't safely edit RAW files), which Lightroom, Capture One and Photos read. Undo restores what the file had before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var looks: some View {
        Form {
            Section("Learn from your camera") {
                Text("Apixa learns Sony's Creative Looks from your own RAW+JPEG shots: the camera records which look made each JPEG, so Apixa fits each look and checks it on shots it didn't learn from. Folders without such shots change nothing, and a look you've already learned is only replaced by one learned from at least as many shots.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(calibrating ? "Learning…" : "Learn Looks from Folders…") { learnLooks() }
                        .disabled(calibrating)
                    if calibrating { ProgressView().controlSize(.small) }
                }
                Text("Takes a few minutes (about 3 RAW shots a second); Apixa is slower meanwhile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Learned looks") {
                let _ = learnedVersion
                let learned = CreativeLook.allCases.compactMap { l in LookCalibration.meta(l).map { (l, $0) } }
                let fromSony = CreativeLook.allCases.filter { LookCalibration.table("\($0.rawValue).rel") != nil }
                if learned.isEmpty && fromSony.isEmpty {
                    Text("None yet — Apixa uses its built-in approximations.").foregroundStyle(.secondary)
                }
                ForEach(fromSony, id: \.self) { l in
                    LabeledContent(l.title) {
                        HStack {
                            Text("from Sony's renders").font(.caption).foregroundStyle(.secondary)
                            Button("Forget") { LookCalibration.forget(l); learnedVersion += 1 }.controlSize(.small)
                        }
                    }
                }
                ForEach(learned, id: \.0) { l, m in
                    LabeledContent(l.title) {
                        HStack {
                            Text(String(format: "%d shots · error %.1f → %.1f", m.trainShots, m.deltaEHandTuned, m.deltaELearned))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Forget") { LookCalibration.forget(l); learnedVersion += 1 }
                                .controlSize(.small)
                        }
                    }
                }
                if !learned.isEmpty {
                    Text("Error is the average colour difference from the camera's JPEG (ΔE; under ~2 is hard to see).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !calibrationReport.isEmpty {
                    Text(calibrationReport).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func learnLooks() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders with RAW+JPEG shots taken with Creative Looks (subfolders are included)."
        panel.prompt = "Learn"
        panel.directoryURL = store.folder
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let folders = panel.urls
        calibrating = true
        Task {
            // Sony's own renders (Imaging Edge exports named NAME-<LOOK>.tif beside NAME.ARW), then camera JPEGs.
            let sony = await SonyFit.run(folders, save: true) { store.statusMessage = $0 }
            let lines = sony + (await SelfTest.lookCompare(folders, out: nil, save: true) { store.statusMessage = $0 })
            calibrationReport = lines.joined(separator: "\n")
            learnedVersion += 1
            store.statusMessage = lines.count <= 1 ? "No Creative Look shots or Sony renders found — nothing changed" : "Looks learned — see Settings ▸ Looks"
            calibrating = false
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store

        List(store.visibleStacks, selection: $store.selectedStackIDs) { stack in
            StackRow(stack: stack).tag(stack.id)
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "People, places, file names")
        .searchSuggestions {
            ForEach(store.people.prefix(8), id: \.name) { p in
                Label("\(p.name)  ·  \(p.count)", systemImage: "person.crop.circle").searchCompletion(p.name)
            }
        }
        .searchFocused($searchFocused)
        .onChange(of: searchFocused) { store.isEditingText = searchFocused }
        .onChange(of: store.searchText) { store.sidebarSelectionChanged() }
        .onChange(of: store.selectedStackIDs) { store.sidebarSelectionChanged() }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if !store.assets.isEmpty {
                    let multi = store.stacks.filter { $0.members.count > 1 }.count
                    Text("\(store.assets.count) shots · \(multi) stacks · \(store.stacks.count - multi) singles")
                    HStack(spacing: 10) {
                        Label("\(store.keepCount) kept", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Label("\(store.rejectCount) rejected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        if store.selectedStackIDs.count > 1 {
                            Text("\(store.selectedStackIDs.count) groups selected").foregroundStyle(.secondary)
                        }
                    }
                }
                if let f = store.locationFilter {
                    HStack {
                        Label("\(f.count) shots from the map", systemImage: "mappin.and.ellipse")
                        Spacer()
                        Button("Show All") { store.locationFilter = nil; store.sidebarSelectionChanged() }
                            .controlSize(.small)
                    }
                }
                if let msg = store.statusMessage {
                    Text(msg).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.bar)
        }
    }
}

struct StackRow: View {
    let stack: PhotoStack

    var body: some View {
        let cover = stack.cover
        let keeps = stack.members.filter { $0.decision == .keep }.count
        let rejects = stack.members.filter { $0.decision == .reject }.count

        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ThumbView(asset: cover, size: 56)
                if stack.members.count > 1 {
                    Text("\(stack.members.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(cover.baseName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(stack.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if stack.members.count > 1 { Text("· \(stack.members.count) similar") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 6) {
                    StarsView(stars: cover.displayStars, user: cover.userRating != nil, size: 9)
                    if keeps > 0 { Text("✓\(keeps)").foregroundStyle(.green) }
                    if rejects > 0 { Text("✕\(rejects)").foregroundStyle(.red) }
                    if cover.effectiveLocation != nil {
                        Image(systemName: "mappin").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.bold())
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct StackDetailView: View {
    @Environment(LibraryStore.self) private var store
    let stack: PhotoStack

    var body: some View {
        @Bindable var store = store
        let current = store.selectedAsset ?? stack.cover
        VStack(spacing: 0) {
            TrailingPanelLayout(key: PanelWidth.photo.key, defaultWidth: PanelWidth.photo.default, minWidth: PanelWidth.photo.range.lowerBound, maxWidth: PanelWidth.photo.range.upperBound, show: store.showInspector) {
                VStack(spacing: 0) {
                    PreviewBar(asset: current)
                    Divider()
                    PreviewView(asset: current, chrome: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } panel: {
                VStack(spacing: 0) {
                    Picker("Inspector", selection: $store.inspectorTab) {
                        ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(12)
                    Divider()
                    switch store.inspectorTab {
                    case .rate: MetricsPanel(asset: current, stack: stack)
                    case .adjust: AdjustPanel(asset: current)
                    case .info: InfoPanel(asset: current)
                    }
                }
            }
            // A single shot has nothing to step through, so the strip only appears for stacks.
            if store.showStrip && stack.members.count > 1 {
                Divider()
                Filmstrip(stack: stack, selectedID: current.id)
            }
        }
    }
}

/// The big image. `chrome: false` = bare image (full-screen viewer).
/// Zoom/pan (pinch, ⌘-scroll, double-click, Z) is shared across shots; past the preview's resolution
/// the full-resolution image is rendered so 100% really is 100%.
struct PreviewView: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    var chrome = true
    /// Show this look instead of the applied one (full screen from the Looks page).
    var lookOverride: LookRecipe? = nil

    private struct LoadKey: Hashable {
        let id: UUID
        let raw: Bool
        let adj: Adjustments
        let full: Bool
        let crop: Bool
    }

    @ViewState private var rendered: CGImage?
    @ViewState private var image: NSImage?
    @ViewState private var before: NSImage?
    @ViewState private var beforeKey: LoadKey?
    @ViewState private var originalSize: CGSize = .zero
    @ViewState private var loadedKey: LoadKey?
    @ViewState private var sourceLabel: String?
    @ViewState private var split: CGFloat = 0.5
    /// Full-resolution render made in the background once a photo settles, so zooming in is instant.
    @ViewState private var prefetched: (key: LoadKey, render: Develop.Rendered)?

    private var baseMaxPixel: Int {
        guard !chrome, let s = NSScreen.main else { return 2400 }
        return Int(max(s.frame.width, s.frame.height) * s.backingScaleFactor)
    }

    /// Long side of the original, for deciding when zoom needs full resolution.
    private var originalLongSide: Double {
        Double(max(asset.info?.width ?? 6000, asset.info?.height ?? 4000))
    }

    private var key: LoadKey {
        var adj = asset.adjustments
        if let lookOverride { adj.look = lookOverride }
        if store.cropMode { adj.crop = nil }   // the crop tool shows the whole (straightened) frame
        let previewScale = Double(baseMaxPixel) / originalLongSide
        let full = !store.cropMode && (store.zoom.scale ?? 0) > previewScale * 1.05
        return LoadKey(id: asset.id, raw: asset.isRawOnly || (asset.isPair && store.previewRaw), adj: adj,
                       full: full, crop: store.cropMode)
    }

    /// The "before" image: no edits, but the same crop/straighten so the two line up.
    private var beforeLoadKey: LoadKey {
        var adj = Adjustments()
        adj.crop = store.cropMode ? nil : asset.adjustments.crop
        adj.angle = asset.adjustments.angle
        return LoadKey(id: asset.id, raw: key.raw, adj: adj, full: false, crop: store.cropMode)
    }

    private var background: (Color, NSColor) {
        switch store.viewerBackground {
        case .black: (.black, .black)
        case .gray: (Color(white: 0.45), NSColor(white: 0.45, alpha: 1))
        case .white: (.white, .white)
        case .auto: chrome ? (Color(nsColor: .underPageBackgroundColor), .underPageBackgroundColor) : (.black, .black)
        }
    }

    private var comparing: Bool { store.compareMode != .off && !store.cropMode && !asset.adjustments.isIdentity }

    var body: some View {
        @Bindable var store = store
        let bg = background
        ZStack(alignment: .topLeading) {
            bg.0
            if let img = (loadedKey?.id == asset.id ? image : nil) ?? asset.thumbnail {
                if store.cropMode && chrome {
                    CropCanvas(image: img, asset: asset)
                } else if comparing, let b = (beforeKey?.id == asset.id ? before : nil) {
                    compareView(before: b, after: img, bg: bg)
                } else {
                    ZoomableImage(image: img,
                                  originalSize: loadedKey?.id == asset.id && originalSize != .zero ? originalSize : estimatedSize(of: img),
                                  zoom: $store.zoom, background: bg.1, margin: chrome || store.viewerMargin != .none ? store.viewerMargin.points : 0)
                        .opacity(chrome && asset.decision == .reject ? 0.5 : 1)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if chrome {
                DecisionBadge(decision: asset.decision).padding(20).allowsHitTesting(false)
            }
            VStack(alignment: .trailing, spacing: 6) {
                let busy = loadedKey != key || (comparing && beforeKey != beforeLoadKey)
                if chrome || busy {
                    HStack(spacing: 6) {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Rendering…")
                        } else if let sourceLabel, loadedKey?.id == asset.id {
                            Text(sourceLabel + (asset.adjustments.isIdentity ? "" : " · edited"))
                        }
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .animation(.easeOut(duration: 0.15), value: busy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(16)
        }
        .task(id: key) { await renderAfter() }
        .task(id: comparing ? beforeLoadKey : nil) { await renderBefore() }
        .task(id: ClipKey(image: rendered.map(ObjectIdentifier.init), on: store.showClipping)) { await applyClipping() }
    }

    private struct ClipKey: Hashable { let image: ObjectIdentifier?; let on: Bool }

    @ViewBuilder
    private func compareView(before: NSImage, after: NSImage, bg: (Color, NSColor)) -> some View {
        @Bindable var store = store
        let size = originalSize != .zero ? originalSize : estimatedSize(of: after)
        switch store.compareMode {
        case .sideBySide:
            HStack(spacing: 2) {
                ZStack(alignment: .top) {
                    ZoomableImage(image: before, originalSize: size, zoom: $store.zoom, background: bg.1)
                    CompareLabel(text: "Before")
                }
                ZStack(alignment: .top) {
                    ZoomableImage(image: after, originalSize: size, zoom: $store.zoom, background: bg.1)
                    CompareLabel(text: "After")
                }
            }
        default:
            GeometryReader { geo in
                let avail = CGRect(origin: .zero, size: geo.size).insetBy(dx: 14, dy: 14)
                let a = after.size.width / max(1, after.size.height)
                let w = min(avail.width, avail.height * a), h = w / a
                let frame = CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
                let x = frame.minX + frame.width * split
                ZStack(alignment: .topLeading) {
                    Image(nsImage: before).resizable().frame(width: w, height: h).offset(x: frame.minX, y: frame.minY)
                    Image(nsImage: after).resizable().frame(width: w, height: h).offset(x: frame.minX, y: frame.minY)
                        .mask(Rectangle().frame(width: max(0, frame.maxX - x), height: h).offset(x: x, y: frame.minY)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
                    Rectangle().fill(Color.white).frame(width: 2, height: h).offset(x: x - 1, y: frame.minY)
                        .shadow(radius: 2)
                    Circle().fill(Color.white).frame(width: 26, height: 26)
                        .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                        .offset(x: x - 13, y: frame.midY - 13)
                    CompareLabel(text: "Before").offset(x: frame.minX + 8, y: frame.minY + 8)
                    CompareLabel(text: "After").offset(x: frame.maxX - 60, y: frame.minY + 8)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    split = min(1, max(0, (g.location.x - frame.minX) / max(1, frame.width)))
                })
            }
        }
    }

    /// Before the first render: the thumbnail's aspect at the original's size.
    private func estimatedSize(of img: NSImage) -> CGSize {
        let a = img.size.width / max(1, img.size.height)
        let l = originalLongSide
        return a >= 1 ? CGSize(width: l, height: l / a) : CGSize(width: l * a, height: l)
    }

    private func renderAfter() async {
        let k = key
        let jpeg = asset.jpegURL, raw = asset.rawURL
        let px: Int? = k.full ? nil : baseMaxPixel
        let label = k.raw ? raw.map(RAWDecoder.label(for:)) ?? "RAW" : (jpeg?.pathExtension.uppercased() ?? "Preview")
        let editing = loadedKey?.id == k.id && loadedKey?.adj != k.adj
        if k.full, let p = prefetched, p.key == k {
            show(p.render, k, label + " · full res")
            return
        }

        // Slider drags: instant approximate render from the cached decode, then exact when idle.
        if editing {
            if let r = await Develop.renderScaled(raw: raw, jpeg: jpeg, useRaw: k.raw, adjustments: k.adj,
                                                  maxPixel: px, draft: false, applyCrop: !k.crop, interactive: true),
               !Task.isCancelled {
                show(r, k, label)
            }
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        // (No quick draft first for a new photo: a RAW 9 draft decode costs nearly as much as the real
        // one (~400 vs ~450 ms), so it only doubled the wait. The thumbnail shows meanwhile.)
        if let r = await Develop.renderScaled(raw: raw, jpeg: jpeg, useRaw: k.raw, adjustments: k.adj,
                                              maxPixel: px, draft: false, applyCrop: !k.crop), !Task.isCancelled {
            show(r, k, label + (k.full ? " · full res" : ""))
            if chrome && !k.full {
                let box = ImageBox(image: r.image)
                let s = await Blocking.run { box.image.flatMap(Scopes.compute).map(ScopesBox.init) }
                if !Task.isCancelled { store.scopes = s?.scopes }
            }
            // Idle on this photo: render full resolution in the background so a zoom doesn't wait for it.
            let fk = LoadKey(id: k.id, raw: k.raw, adj: k.adj, full: true, crop: false)
            if chrome && !k.full && !k.crop && prefetched?.key != fk {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                if let f = await Develop.renderScaled(raw: raw, jpeg: jpeg, useRaw: k.raw, adjustments: k.adj,
                                                      maxPixel: nil, draft: false, applyCrop: true) {
                    // Keep it even if this task was superseded by the zoom itself — that zoom wants exactly this.
                    if key == fk { show(f, fk, label + " · full res") }
                    prefetched = (fk, f)
                }
            }
            // Then decode the photos the arrow keys lead to, so stepping through a burst is instant.
            if chrome && !k.full && !k.crop {
                for n in store.neighbors(of: asset) where n.rawURL != nil {
                    guard !Task.isCancelled else { return }
                    let useRaw = n.isRawOnly || (n.isPair && store.previewRaw)
                    guard useRaw, let nraw = n.rawURL else { continue }
                    await Develop.warm(raw: nraw, adjustments: n.adjustments, maxPixel: baseMaxPixel)
                }
            }
        }
    }

    private func renderBefore() async {
        guard comparing else { return }
        let k = beforeLoadKey
        if let r = await Develop.renderScaled(raw: asset.rawURL, jpeg: asset.jpegURL, useRaw: k.raw, adjustments: k.adj,
                                              maxPixel: baseMaxPixel, draft: false, applyCrop: !k.crop), !Task.isCancelled {
            before = NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
            beforeKey = k
        }
    }

    private func show(_ r: Develop.Rendered, _ k: LoadKey, _ label: String) {
        let cg = r.image
        rendered = cg
        if !store.showClipping { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        originalSize = CGSize(width: Double(cg.width) / r.scale, height: Double(cg.height) / r.scale)
        sourceLabel = label
        loadedKey = k
    }

    /// Red = blown highlights, blue = crushed shadows (on the displayed image).
    private func applyClipping() async {
        guard let cg = rendered else { return }
        guard store.showClipping else {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            return
        }
        let box = ImageBox(image: cg)
        let out = await Blocking.run { ImageBox(image: box.image.flatMap(ClippingOverlay.apply)) }
        if let o = out.image, !Task.isCancelled { image = NSImage(cgImage: o, size: NSSize(width: o.width, height: o.height)) }
    }
}

struct CompareLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(8)
            .allowsHitTesting(false)
    }
}

enum ClippingOverlay {
    static func apply(_ src: CGImage) -> CGImage? {
        let w = src.width, h = src.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        px.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let r = p[i], g = p[i + 1], b = p[i + 2]
                if r >= 254 || g >= 254 || b >= 254 { p[i] = 255; p[i + 1] = 0; p[i + 2] = 0 }
                else if r <= 1 && g <= 1 && b <= 1 { p[i] = 0; p[i + 1] = 90; p[i + 2] = 255 }
            }
        }
        return ctx.makeImage()
    }
}

/// Crop tool: the straightened frame with a draggable crop rectangle (rule-of-thirds grid).
struct CropCanvas: View {
    @Environment(LibraryStore.self) private var store
    let image: NSImage
    @Bindable var asset: PhotoAsset

    var body: some View {
        GeometryReader { geo in
            let avail = CGRect(origin: .zero, size: geo.size).insetBy(dx: 24, dy: 24)
            let ia = image.size.width / max(1, image.size.height)
            let fw = min(avail.width, avail.height * ia), fh = fw / ia
            let frame = CGRect(x: avail.midX - fw / 2, y: avail.midY - fh / 2, width: fw, height: fh)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                CropOverlay(rect: Binding(get: { asset.adjustments.crop ?? .full },
                                          set: { asset.adjustments.crop = $0 == .full ? nil : $0 }),
                            aspect: store.cropAspect.ratio(imageAspect: ia), frame: frame)
            }
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", square = "1:1", r4x5 = "4:5", r3x2 = "3:2", r2x3 = "2:3", r16x9 = "16:9", r9x16 = "9:16"
    var id: String { rawValue }

    /// Width / height in pixels, or nil when free.
    func ratio(imageAspect: Double) -> Double? {
        switch self {
        case .free: nil
        case .original: imageAspect
        case .square: 1
        case .r4x5: 4.0 / 5
        case .r3x2: 3.0 / 2
        case .r2x3: 2.0 / 3
        case .r16x9: 16.0 / 9
        case .r9x16: 9.0 / 16
        }
    }
}

struct CropOverlay: View {
    @Binding var rect: CropRect
    let aspect: Double?
    let frame: CGRect
    @ViewState private var start: CropRect?

    private var viewRect: CGRect {
        CGRect(x: frame.minX + rect.x * frame.width, y: frame.minY + rect.y * frame.height,
               width: rect.w * frame.width, height: rect.h * frame.height)
    }

    var body: some View {
        let r = viewRect
        ZStack(alignment: .topLeading) {
            Path { p in p.addRect(frame); p.addRect(r) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Path { p in
                for f in [1.0 / 3, 2.0 / 3] {
                    p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle().path(in: r).stroke(Color.white, lineWidth: 1.5).allowsHitTesting(false)
            // Move: drag inside.
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                .gesture(DragGesture().onChanged { g in
                    let s0 = start ?? rect; start = s0
                    var n = s0
                    n.x = min(1 - n.w, max(0, s0.x + g.translation.width / frame.width))
                    n.y = min(1 - n.h, max(0, s0.y + g.translation.height / frame.height))
                    rect = n
                }.onEnded { _ in start = nil })
            ForEach(0..<4, id: \.self) { c in
                let pt = CGPoint(x: c % 2 == 0 ? r.minX : r.maxX, y: c < 2 ? r.minY : r.maxY)
                RoundedRectangle(cornerRadius: 2).fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .offset(x: pt.x - 7, y: pt.y - 7)
                    .gesture(DragGesture().onChanged { g in
                        let s0 = start ?? rect; start = s0
                        rect = resized(s0, corner: c, dx: g.translation.width / frame.width, dy: g.translation.height / frame.height)
                    }.onEnded { _ in start = nil })
            }
        }
        .onChange(of: aspect) { if let a = aspect { rect = fitted(rect, aspect: a) } }
    }

    /// Normalized w/h ratio that gives the requested pixel aspect on this frame.
    private func normRatio(_ a: Double) -> Double { a * frame.height / frame.width }

    private func resized(_ s: CropRect, corner c: Int, dx: Double, dy: Double) -> CropRect {
        let minS = 0.05
        var x0 = s.x, y0 = s.y, x1 = s.x + s.w, y1 = s.y + s.h
        if c % 2 == 0 { x0 = min(x1 - minS, max(0, x0 + dx)) } else { x1 = max(x0 + minS, min(1, x1 + dx)) }
        if c < 2 { y0 = min(y1 - minS, max(0, y0 + dy)) } else { y1 = max(y0 + minS, min(1, y1 + dy)) }
        var n = CropRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        if let a = aspect {
            let k = normRatio(a)
            var w = n.w, h = w / k
            // Anchor at the opposite corner and keep inside the frame.
            let maxH = c < 2 ? y1 : 1 - y0, maxW = c % 2 == 0 ? x1 : 1 - x0
            if h > maxH { h = maxH; w = h * k }
            if w > maxW { w = maxW; h = w / k }
            n = CropRect(x: c % 2 == 0 ? x1 - w : x0, y: c < 2 ? y1 - h : y0, w: w, h: h)
        }
        return n
    }

    /// Largest rect of the given aspect centred on the current one.
    private func fitted(_ s: CropRect, aspect a: Double) -> CropRect {
        let k = normRatio(a)
        var w = s.w, h = w / k
        if h > s.h { h = s.h; w = h * k }
        return CropRect(x: s.x + (s.w - w) / 2, y: s.y + (s.h - h) / 2, w: w, h: h)
    }
}

struct ScopesBox: @unchecked Sendable { let scopes: Scopes }

/// Full screen: just the image. ↑ ↓ change group, ← → move within the group (menu shortcuts).
struct FullScreenViewer: View {
    @Environment(LibraryStore.self) private var store
    @ViewState private var hudVisible = false
    @ViewState private var hudTask: Task<Void, Never>?
    @ViewState private var controlsVisible = false
    @ViewState private var controlsTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let a = store.selectedAsset {
                let look = store.mainMode == .looks ? store.lookFocus : nil
                PreviewView(asset: a, chrome: false, lookOverride: look)
                    .ignoresSafeArea()
                if hudVisible, let s = store.selectedStack {
                    let i = (s.members.firstIndex { $0.id == a.id } ?? 0) + 1
                    HStack(spacing: 12) {
                        Text(a.baseName).bold()
                        if let l = store.mainMode == .looks ? store.lookFocus : a.adjustments.look { Text(l.name) }
                        if s.members.count > 1 { Text("\(i) of \(s.members.count)") }
                        StarsView(stars: a.displayStars, user: a.userRating != nil, size: 12)
                        if a.decision == .keep { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        if a.decision == .reject { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                    }
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.bottom, 28)
                    .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .top) {
            if controlsVisible { controls.transition(.opacity).padding(.top, 18) }
        }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onChange(of: store.selectedAsset?.id) { flashHUD() }
        .onChange(of: store.lookFocus?.id) { flashHUD() }
        .onChange(of: store.selectedAsset?.decision) { flashHUD() }
        .onChange(of: store.selectedAsset?.userRating) { flashHUD() }
    }

    /// Appears when the mouse moves; hides after a moment so the photo stays alone.
    private var controls: some View {
        @Bindable var store = store
        return HStack(spacing: 14) {
            Picker("View", selection: Binding(get: { store.mainMode }, set: { store.switchMode($0) })) {
                Text("Photo").tag(MainMode.photo)
                Text("Looks").tag(MainMode.looks)
            }
            .pickerStyle(.segmented).fixedSize()
            .help("In full screen: Photo shows your edit; Looks shows the look you have open")
            Picker("Background", selection: $store.viewerBackground) {
                Text("Black").tag(ViewerBackground.black)
                Text("Gray").tag(ViewerBackground.gray)
                Text("White").tag(ViewerBackground.white)
            }
            .pickerStyle(.segmented).fixedSize()
            Picker("Margin", selection: $store.viewerMargin) {
                ForEach(ViewerMargin.allCases) { Text($0 == .none ? "No margin" : "\($0.rawValue) margin").tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Toggle(isOn: $store.showClipping) { Label("Clipping", systemImage: "exclamationmark.triangle") }
                .toggleStyle(.button)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Label("Exit", systemImage: "xmark") }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .onHover { inside in if inside { controlsTask?.cancel() } else { showControls() } }
    }

    private func showControls() {
        controlsTask?.cancel()
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
        controlsTask = Task {
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { controlsVisible = false }
        }
    }

    /// Brief overlay after navigating or marking, then the screen is image-only again.
    private func flashHUD() {
        hudTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { hudVisible = true }
        hudTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { hudVisible = false }
        }
    }
}

struct DecisionBadge: View {
    let decision: Decision

    var body: some View {
        switch decision {
        case .keep:
            Label("KEEP", systemImage: "checkmark.circle.fill")
                .font(.headline).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.green)).foregroundStyle(.white)
        case .reject:
            Label("REJECT", systemImage: "xmark.circle.fill")
                .font(.headline).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.red)).foregroundStyle(.white)
        case .undecided:
            EmptyView()
        }
    }
}

// MARK: - Rate tab

struct MetricsPanel: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("showShortcuts") private var showShortcuts = false
    @AppStorage("showRatingBreakdown") private var showBreakdown = true
    let asset: PhotoAsset
    let stack: PhotoStack

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RatingControl(asset: asset)
                    Spacer()
                    if asset.isBest && stack.members.count > 1 {
                        Label("Best", systemImage: "crown.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.yellow)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.baseName).font(.title3.bold()).lineLimit(1)
                    HStack(spacing: 4) {
                        if let j = asset.jpegURL { TypeTag(text: j.pathExtension.uppercased()) }
                        if asset.rawURL != nil { TypeTag(text: "RAW") }
                        Text(asset.captureDate, format: .dateTime.hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                MetricBar(title: "Overall", value: asset.score)
                    .help("How this shot ranks against the rest of the folder: face quality, aesthetics and exposure, with soft shots marked down. The stars come from this.")
                MetricBar(title: "Sharpness", value: asset.sharpnessScore,
                          note: asset.isBlurry ? "Looks blurry / missed focus" : nil)
                MetricBar(title: "Exposure", value: asset.exposureScore, note: asset.exposureNote)
                if let f = asset.faceQuality {
                    MetricBar(title: "Face quality", value: f)
                }
                if let a = asset.aesthetic {
                    MetricBar(title: "Aesthetics", value: (a + 1) / 2)
                }
                Text("Sharpness & exposure from: \(asset.metricsSource.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !asset.adjustments.isIdentity {
                    Divider()
                    EditedScores(asset: asset, useRaw: asset.isRawOnly || (asset.isPair && store.previewRaw))
                }

                Divider()
                DisclosureGroup("Rating breakdown", isExpanded: $showBreakdown) {
                    RatingBreakdown(asset: asset).padding(.top, 6)
                }
                .font(.callout)

                Divider()

                HStack {
                    decisionButton("Keep", "checkmark", .keep, .green)
                    decisionButton("Reject", "xmark", .reject, .red)
                    Button { store.setDecision(asset, .undecided) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Clear mark (U)")
                }
                if stack.members.count > 1 {
                    Button {
                        store.keepBest(in: stack)
                    } label: {
                        Label("Keep best in this stack", systemImage: "crown")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Keeps the 👑 shot and rejects the others you haven't marked yet (B). Undo with ⌘Z.")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(asset.allURLs)
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }

                Divider()
                DisclosureGroup("Keyboard shortcuts", isExpanded: $showShortcuts) {
                    Text("P keep · X reject · U clear · ⌘Z undo\n1–5 rate · 0 automatic rating\n← → photo · ↑ ↓ group · B keep best\nR JPEG/RAW · F full screen · Z zoom\nC crop · Y compare · J clipping · G background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
            .padding(16)
        }
        .scrollIndicators(.visible, axes: .vertical)   // fixed scrollbar: panel width never jumps
    }

    private func decisionButton(_ title: String, _ icon: String, _ d: Decision, _ color: Color) -> some View {
        Button {
            store.toggleDecision(asset, d)
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        // Coloured only once chosen, so the current mark is obvious at a glance.
        .buttonStyle(.bordered)
        .tint(asset.decision == d ? color : nil)
        .fontWeight(asset.decision == d ? .semibold : .regular)
    }
}

/// The same scores as above, measured on the edited render (RAW or JPEG, whichever is being previewed)
/// next to the unedited render of the same source, so the two are directly comparable.
struct EditedScores: View {
    let asset: PhotoAsset
    let useRaw: Bool
    @ViewState private var result: (key: Key, before: Analyzer.Measured, after: Analyzer.Measured)?
    @ViewState private var busy = false

    struct Key: Hashable { let id: UUID; let adj: Adjustments; let raw: Bool }
    private var key: Key { Key(id: asset.id, adj: asset.adjustments, raw: useRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Edited version · \(useRaw ? "RAW" : (asset.jpegURL?.pathExtension.uppercased() ?? "JPEG"))")
                    .font(.callout.weight(.semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if let r = result, r.key.id == asset.id {
                line("Sharpness", r.before.sharpness, r.after.sharpness)
                line("Exposure", r.before.exposure, r.after.exposure)
                if let b = r.before.face, let a = r.after.face { line("Face quality", b, a) }
                if let b = r.before.aesthetic, let a = r.after.aesthetic { line("Aesthetics", b, a) }
                detail("Brightness", r.before.mean, r.after.mean)
                detail("Highlights clipped", r.before.highClip, r.after.highClip, worseWhenHigher: true)
                detail("Shadows crushed", r.before.shadowClip, r.after.shadowClip, worseWhenHigher: true)
                Text("Original → edited, both measured on the \(useRaw ? "RAW" : "JPEG") render. The stars and rank above stay based on the original file.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Measuring the edited photo…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await measure() }
    }

    private func line(_ title: String, _ before: Double, _ after: Double) -> some View {
        let d = Int((after * 100).rounded()) - Int((before * 100).rounded())
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Int((before * 100).rounded())) → \(Int((after * 100).rounded()))").font(.subheadline.monospacedDigit())
                Text(d == 0 ? "±0" : String(format: "%+d", d)).font(.caption.monospacedDigit().bold())
                    .foregroundStyle(d > 0 ? Color.green : d < 0 ? Color.orange : Color.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            ProgressView(value: min(max(after, 0), 1)).tint(d < 0 ? Color.orange : Color.accentColor)
        }
    }

    private func detail(_ title: String, _ before: Double, _ after: Double, worseWhenHigher: Bool = false) -> some View {
        let fmt: (Double) -> String = { String(format: $0 < 0.1 && worseWhenHigher ? "%.1f%%" : "%.0f%%", $0 * 100) }
        let worse = worseWhenHigher && after > before + 0.002
        return HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(fmt(before)) → \(fmt(after))").font(.caption.monospacedDigit())
                .foregroundStyle(worse ? Color.orange : Color.primary)
        }
    }

    private func measure() async {
        let k = key
        try? await Task.sleep(for: .milliseconds(500))   // wait for the sliders to settle
        if Task.isCancelled { return }
        busy = true
        defer { busy = false }
        var plain = Adjustments(); plain.crop = k.adj.crop; plain.angle = k.adj.angle   // same framing
        let raw = asset.rawURL, jpeg = asset.jpegURL
        let ai = ImageBox(image: await Develop.render(raw: raw, jpeg: jpeg, useRaw: k.raw, adjustments: k.adj, maxPixel: 1600, draft: false))
        let bi = ImageBox(image: await Develop.render(raw: raw, jpeg: jpeg, useRaw: k.raw, adjustments: plain, maxPixel: 1600, draft: false))
        guard !Task.isCancelled, let am = await Analyzer.measure(ai), let bm = await Analyzer.measure(bi), !Task.isCancelled else { return }
        result = (k, bm, am)
    }
}

/// Every aspect behind a shot's automatic stars: what was measured, how much it counts, where the shot
/// ranks in the folder, and how it compares inside its stack.
struct RatingBreakdown: View {
    let asset: PhotoAsset

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }

    private func row(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(value).font(.caption.monospacedDigit())
            }
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        let d = asset.ratingDetail
        let hasFace = d.faceRank != nil
        VStack(alignment: .leading, spacing: 9) {
            if d.total > 0 {
                row("Rank in this folder", "#\(d.rank) of \(d.total)",
                    d.total >= 8 ? "Top 10% get 5★, the next 25% 4★, then 35% 3★, 20% 2★, the rest 1★. This rank gives \(d.rankedStars)★."
                                 : "Too few shots to rank, so everything gets 3★.")
            }
            if let cap = d.cap {
                Label(cap, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if let u = asset.userRating {
                Label("You rated this \(u)★, which overrides the automatic \(asset.stars)★.", systemImage: "person.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let f = d.faceRank, let q = asset.faceQuality {
                row("Face", "\(pct(q)) · beats \(pct(f))%",
                    "Expression, open eyes and pose of the best face (Apple Vision). Counts 50%.")
            } else {
                row("Face", "none found", "No face detected, so aesthetics and exposure carry the score.")
            }
            if let r = d.aestheticRank, let a = asset.aesthetic {
                row("Aesthetics", "\(pct((a + 1) / 2)) · beats \(pct(r))%",
                    "Composition, light and subject appeal (Apple Vision). Counts \(hasFace ? 35 : 70)%.")
            }
            row("Exposure", pct(d.exposure),
                "Brightness \(pct(asset.meanLuma))%, highlights clipped \(String(format: "%.1f", asset.highlightClip * 100))%, shadows crushed \(String(format: "%.1f", asset.shadowClip * 100))%. Counts \(hasFace ? 15 : 30)%.")
            row("Focus check", pct(d.focus),
                "Sharpness of the frame \(pct(d.frameSharpness))" + (d.faceSharpness.map { ", of the face \(pct($0))" } ?? "")
                + ". Sharp enough scores 100; soft shots lose up to half their score. Extra texture earns nothing.")
            row("Overall", pct(asset.score),
                "The three weighted parts (\(pct(d.content))) × the focus check.")
            if d.stackSize > 1 {
                Divider()
                row("In its stack", asset.isBest ? "Best of \(d.stackSize)" : "#\(d.pickRank) of \(d.stackSize)",
                    "Picked on " + (hasFace ? "face quality first, then " : "") + "sharpness against the sharpest shot in the stack (\(pct(d.relativeSharpness))%, measured on \(d.sharpnessUsesFace ? "the face" : "the frame")), aesthetics and exposure. Your own stars always win.")
            }
        }
    }
}

/// Click a star to set your rating (click it again to go back to the automatic rating).
struct RatingControl: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    @ViewState private var hover: Int?

    var body: some View {
        let shown = hover ?? asset.displayStars
        let isUser = hover != nil || asset.userRating != nil
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= shown ? "star.fill" : "star")
                    .font(.system(size: 17))
                    .foregroundStyle(i <= shown ? Color.yellow.opacity(isUser ? 1 : 0.45) : Color.secondary)
                    .contentShape(Rectangle())
                    .onHover { inside in hover = inside ? i : (hover == i ? nil : hover) }
                    .onTapGesture { store.setRating(asset, i) }
            }
            Text(asset.userRating == nil ? "auto" : "yours")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .help("Click to rate (1–5 keys). Click the same star again, or press 0, to use the automatic rating.")
    }
}

// MARK: - Adjust tab

enum ScopeKind: String, CaseIterable, Identifiable {
    case histogram = "Histogram", waveform = "Waveform", vectorscope = "Vectorscope"
    var id: String { rawValue }
}

struct AdjustPanel: View {
    @Environment(LibraryStore.self) private var store
    @Bindable var asset: PhotoAsset
    @ViewState private var scopeKind = ScopeKind.histogram
    @AppStorage("scopeHeight") private var scopeHeight = 180.0
    @ViewState private var channel = CurveChannel.master
    @ViewState private var dragStart: Adjustments?
    @ViewState private var autoBusy = false
    @ViewState private var confirmAuto = false

    private func runAuto(_ usesRaw: Bool) {
        autoBusy = true
        Task {
            await store.toggleAuto(asset, usesRaw: usesRaw)
            autoBusy = false
        }
    }

    var body: some View {
        let usesRaw = asset.isRawOnly || (asset.isPair && store.previewRaw)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScopesView(scopes: store.scopes, kind: scopeKind)
                    .frame(height: scopeHeight)
                ResizeGrip(height: $scopeHeight, range: 90...480, defaultHeight: 180)
                Picker("Scope", selection: $scopeKind) {
                    ForEach(ScopeKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                HStack {
                    Text(usesRaw ? "Editing RAW" : "Editing \(asset.jpegURL?.pathExtension.uppercased() ?? "image")")
                        .font(.headline)
                    Spacer()
                    Toggle(isOn: Binding(get: { asset.adjustments.isAutoOn }, set: { _ in
                        // Manual tone edits would be replaced: ask first (turning Auto off brings them back).
                        if !asset.adjustments.isAutoOn && asset.adjustments.tone != ToneSet() { confirmAuto = true } else { runAuto(usesRaw) }
                    })) {
                        Label("Auto", systemImage: "wand.and.stars")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(autoBusy)
                    .help(asset.adjustments.isAutoOn
                          ? "Auto is on. Click to turn it off and get back what you had. Changing a Light, Curves or colour slider also turns it off."
                          : "Apple's auto-enhance: sets Shadows, Highlights, Vibrance and the RGB curve for this photo.")
                    .confirmationDialog("Replace your edits with Auto?", isPresented: $confirmAuto) {
                        Button("Replace with Auto") { runAuto(usesRaw) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your Light, Curves, Vibrance and Saturation edits will be replaced. Turning Auto off, or ⌘Z, brings them back.")
                    }
                    Menu {
                        Button("Copy Edits") { store.copiedAdjustments = asset.adjustments }
                        Button("Paste Edits") { paste([asset]) }
                            .disabled(store.copiedAdjustments == nil)
                        Button("Paste Edits to Selected Groups (\(store.selectedGroupAssets.count))") {
                            paste(store.selectedGroupAssets)
                        }
                        .disabled(store.copiedAdjustments == nil)
                        Divider()
                        Button("Reset All Edits") { store.resetAdjustments(asset) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if let look = asset.adjustments.look {
                    HStack {
                        Label(look.name, systemImage: "camera.filters").font(.callout)
                        Spacer()
                        Button("Change…") { store.mainMode = .looks; store.lookFocus = look }.controlSize(.small)
                        Button("Remove") { store.applyLook(nil, to: [asset]) }.controlSize(.small)
                    }
                    Divider()
                }
                group("Crop & Straighten") {
                    if store.cropMode {
                        Picker("Aspect", selection: Binding(get: { store.cropAspect }, set: { store.cropAspect = $0 })) {
                            ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                        }
                        slider("Straighten", \.angle, -45...45, format: "%+.1f°", hint: "Rotate to level the horizon")
                        HStack {
                            Button("Reset") {
                                asset.adjustments.crop = nil
                                asset.adjustments.angle = 0
                            }
                            Spacer()
                            Button("Cancel") { store.endCrop(apply: false) }
                                .keyboardShortcut(.cancelAction)
                            Button("Done") { store.endCrop(apply: true) }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        HStack {
                            Button { store.beginCrop() } label: { Label("Crop…", systemImage: "crop") }
                                .help("Crop and straighten (C)")
                            Spacer()
                            if asset.adjustments.crop != nil || asset.adjustments.angle != 0 {
                                Text("Cropped" + (asset.adjustments.angle != 0 ? String(format: ", %+.1f°", asset.adjustments.angle) : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                group("Light") {
                    slider("Exposure", \.exposure, -5...5, format: "%+.2f EV")
                    slider("Contrast", \.contrast, -1...1)
                    slider("Highlights", \.highlights, -1...1, hint: "Left recovers bright areas, right brightens them")
                    slider("Shadows", \.shadows, -1...1, hint: "Left deepens dark areas, right lifts them")
                    slider("Whites", \.whites, -1...1)
                    slider("Blacks", \.blacks, -1...1)
                    if usesRaw {
                        slider("Tone mapping", \.toneMapping, -1...1, hint: "RAW 9 local tone mapping")
                    }
                }
                group("Curves") {
                    Picker("Channel", selection: $channel) {
                        ForEach(CurveChannel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    CurveEditor(points: Binding(get: { asset.adjustments.curves[channel] },
                                                set: { asset.adjustments.curves[channel] = $0 }),
                                channel: channel,
                                histogram: store.scopes.map { s in
                                    switch channel {
                                    case .master: s.luma
                                    case .red: s.red
                                    case .green: s.green
                                    case .blue: s.blue
                                    }
                                },
                                onBegin: { dragStart = dragStart ?? asset.adjustments },
                                onEnd: { commit("Curve") })
                        .frame(height: 220)
                    HStack {
                        Text("Click to add a point · drag off the graph to remove")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset \(channel.rawValue)") {
                            let old = asset.adjustments
                            asset.adjustments.curves[channel] = Curves.identity
                            store.commitAdjustments(asset, from: old, name: "Reset Curve")
                        }
                        .controlSize(.small)
                        .disabled(asset.adjustments.curves[channel] == Curves.identity)
                    }
                }
                group("Color") {
                    slider("Temperature", \.temperature, -3000...3000, format: "%+.0f K")
                    slider("Tint", \.tint, -100...100, format: "%+.0f")
                    slider("Vibrance", \.vibrance, -1...1)
                    slider("Saturation", \.saturation, -1...1)
                }
                group("Detail") {
                    slider("Noise reduction", \.noiseReduction, 0...1)
                    slider("Strong NR", \.strongNoise, 0...1, hint: "Extra denoise pass for high-ISO shots; above 50% adds a median filter")
                    slider("Colour noise", \.colorNoise, 0...1, hint: "Removes red/green colour speckle without softening detail")
                    slider("Sharpening", \.sharpening, 0...1)
                    HStack {
                        Text("Noise and sharpening only show up close — judge them at 100%.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(store.zoom.scale == nil ? "View at 100%" : "Back to Fit") {
                            ZoomCommand.toggle.post()
                        }
                        .controlSize(.small)
                    }
                }

                Button {
                    store.showSaveCopy = true
                } label: {
                    Label("Save Copy…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .help("Writes a new file with your edits (⌘S). Originals are never modified.")
                Text(usesRaw
                     ? "Exposure, white balance, contrast, tone mapping, noise and sharpening are applied inside the RAW 9 decoder."
                     : "Switch the preview to RAW for more latitude when a RAW file is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .scrollIndicators(.visible, axes: .vertical)   // fixed scrollbar: panel width never jumps
    }

    private func paste(_ targets: [PhotoAsset]) {
        if let adj = store.copiedAdjustments { store.pasteAdjustments(adj, to: targets) }
    }

    private func commit(_ name: String) {
        if let old = dragStart { store.commitAdjustments(asset, from: old, name: name) }
        dragStart = nil
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        CollapsibleSection(title: title, content: content)
        Divider()
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double>,
                        format: String = "%+.2f", hint: String? = nil) -> some View {
        let bipolar = range.lowerBound < 0
        let reset = {
            let old = dragStart ?? asset.adjustments
            dragStart = nil
            asset.adjustments[keyPath: kp] = 0
            store.commitAdjustments(asset, from: old, name: "Reset \(title)")
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, asset.adjustments[keyPath: kp]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(asset.adjustments[keyPath: kp] == 0 ? .secondary : .primary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: reset)
            ZStack {
                if bipolar {
                    // Centre tick: zero is in the middle for two-way sliders.
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 12)
                }
                Slider(value: Binding(get: { asset.adjustments[keyPath: kp] },
                                      set: { asset.adjustments[keyPath: kp] = $0 }),
                       in: range) { editing in
                    if editing { dragStart = dragStart ?? asset.adjustments } else { commit(title) }
                }
                .controlSize(.small)
            }
        }
        .help((hint.map { $0 + ". " } ?? "") + "Double-click to reset.")
    }
}

struct ScopesView: View {
    let scopes: Scopes?
    let kind: ScopeKind

    private static let grid = Color.white.opacity(0.14)
    private static let label = Color.white.opacity(0.55)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.88))
            if let s = scopes {
                switch kind {
                case .histogram: histogram(s)
                case .waveform: waveform(s)
                case .vectorscope: vectorscope(s)
                }
            } else {
                Text("Scopes appear when the preview loads").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Histogram — dark tones on the left, bright on the right; the edges are the clipping points.

    private func histogram(_ s: Scopes) -> some View {
        let lo = s.clippedShadows, hi = s.clippedHighlights
        return VStack(spacing: 2) {
            HStack {
                Label(lo > 0.0005 ? "Shadows clipped \(pct(lo))" : "Shadows OK", systemImage: "arrowtriangle.left.fill")
                    .foregroundStyle(lo > 0.0005 ? Color.cyan : Self.label)
                Spacer()
                Label(hi > 0.0005 ? "Highlights clipped \(pct(hi))" : "Highlights OK", systemImage: "arrowtriangle.right.fill")
                    .labelStyle(TrailingIconLabelStyle())
                    .foregroundStyle(hi > 0.0005 ? Color.orange : Self.label)
            }
            .font(.caption2.bold())
            Canvas { ctx, size in
                // Zones: quarter lines, and the two clipping edges.
                for q in 1...3 {
                    let x = size.width * CGFloat(q) / 4
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(Self.grid), lineWidth: 1)
                }
                ctx.drawLayer { layer in
                    layer.blendMode = .screen
                    for (bins, color) in [(s.red, Color.red), (s.green, Color.green), (s.blue, Color.blue)] {
                        layer.fill(area(bins, size), with: .color(color.opacity(0.5)))
                    }
                    layer.stroke(line(s.luma, size), with: .color(.white.opacity(0.85)), lineWidth: 1)
                }
                // Clipping bars at the very edges: taller = more of the photo is clipped.
                func bar(_ x: CGFloat, _ amount: Double, _ color: Color) {
                    let h = size.height * CGFloat(min(1, amount * 12))
                    ctx.fill(Path(CGRect(x: x, y: size.height - max(h, amount > 0.0005 ? 6 : 0), width: 4, height: max(h, amount > 0.0005 ? 6 : 0))),
                             with: .color(color))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x + 2, y: 0)); $0.addLine(to: CGPoint(x: x + 2, y: size.height)) },
                               with: .color(color.opacity(amount > 0.0005 ? 0.7 : 0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                bar(0, lo, .cyan)
                bar(size.width - 4, hi, .orange)
            }
            HStack {
                Text("Blacks"); Spacer(); Text("Shadows"); Spacer(); Text("Midtones"); Spacer(); Text("Highlights"); Spacer(); Text("Whites")
            }
            .font(.system(size: 9)).foregroundStyle(Self.label)
        }
        .padding(6)
    }

    // MARK: Waveform — left to right is across the photo, bottom to top is dark to bright.

    private func waveform(_ s: Scopes) -> some View {
        HStack(spacing: 4) {
            VStack {
                ForEach(["100", "75", "50", "25", "0"], id: \.self) { t in
                    Text(t)
                    if t != "0" { Spacer(minLength: 0) }
                }
            }
            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Self.label)
            ZStack {
                if let img = s.waveform { Image(decorative: img, scale: 1).resizable().interpolation(.medium) }
                Canvas { ctx, size in
                    for q in 0...4 {
                        let y = size.height * CGFloat(q) / 4
                        let edge = q == 0 || q == 4
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(q == 0 ? Color.orange.opacity(0.7) : q == 4 ? Color.cyan.opacity(0.7) : Self.grid),
                                   style: StrokeStyle(lineWidth: 1, dash: edge ? [4, 3] : []))
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .overlay(alignment: .topTrailing) {
            Text("R G B · white = neutral").font(.system(size: 9)).foregroundStyle(Self.label).padding(.trailing, 8).padding(.top, 10)
        }
        .help("Across = position in the photo, up = brightness (0 black, 100 white). Anything on the orange line is blown out; on the blue line, crushed. Where red, green and blue separate, there is a colour cast.")
    }

    // MARK: Vectorscope — centre is grey; direction is hue, distance from the centre is saturation.

    private func vectorscope(_ s: Scopes) -> some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2
                let k = CGFloat(0.5 / Scopes.vectorRadius)
                func pt(_ cb: Double, _ cr: Double) -> CGPoint { CGPoint(x: c.x + CGFloat(cb) * k * 2 * r, y: c.y - CGFloat(cr) * k * 2 * r) }
                for f in [1.0, 0.66, 0.33] {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * f, y: c.y - r * f, width: 2 * r * f, height: 2 * r * f)),
                               with: .color(Self.grid), lineWidth: 1)
                }
                ctx.stroke(Path { $0.move(to: CGPoint(x: c.x - r, y: c.y)); $0.addLine(to: CGPoint(x: c.x + r, y: c.y))
                                  $0.move(to: CGPoint(x: c.x, y: c.y - r)); $0.addLine(to: CGPoint(x: c.x, y: c.y + r)) },
                           with: .color(Self.grid), lineWidth: 1)
                // Skin-tone line: faces of every complexion fall along it.
                let skin = Scopes.chroma(0.8, 0.6, 0.5), sl = (skin.cb * skin.cb + skin.cr * skin.cr).squareRoot()
                let end = CGPoint(x: c.x + CGFloat(skin.cb / sl) * r, y: c.y - CGFloat(skin.cr / sl) * r)
                ctx.stroke(Path { $0.move(to: c); $0.addLine(to: end) }, with: .color(Color.orange.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                // Colour targets at moderate saturation, each in its own colour.
                let targets: [(String, Double, Double, Double)] = [("R", 1, 0, 0), ("Y", 1, 1, 0), ("G", 0, 1, 0), ("C", 0, 1, 1), ("B", 0, 0, 1), ("M", 1, 0, 1)]
                for (name, tr, tg, tb) in targets {
                    let ch = Scopes.chroma(tr, tg, tb), len = (ch.cb * ch.cb + ch.cr * ch.cr).squareRoot()
                    let dir = CGPoint(x: CGFloat(ch.cb / len), y: CGFloat(-ch.cr / len))
                    let p = CGPoint(x: c.x + dir.x * r * 0.86, y: c.y + dir.y * r * 0.86)
                    let color = Color(red: 0.35 + 0.65 * tr, green: 0.35 + 0.65 * tg, blue: 0.35 + 0.65 * tb)
                    ctx.stroke(Path(CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(color), lineWidth: 1)
                    ctx.draw(Text(name).font(.system(size: 10, weight: .bold)).foregroundStyle(color),
                             at: CGPoint(x: c.x + dir.x * (r - 4), y: c.y + dir.y * (r - 4)))
                }
                _ = pt
            }
            if let img = s.vectorscope { Image(decorative: img, scale: 1).resizable().interpolation(.medium) }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) {
            Text("centre = grey\nedge = saturated\ndashed = skin").font(.system(size: 9)).foregroundStyle(Self.label).padding(8)
        }
        .help("Each dot is a colour in the photo: its direction is the hue (towards the R, Y, G, C, B, M marks), its distance from the centre is how saturated it is. A cloud pulled off-centre means a colour cast. Faces should sit along the dashed skin-tone line.")
    }

    private func pct(_ v: Double) -> String { String(format: v < 0.1 ? "%.1f%%" : "%.0f%%", v * 100) }

    private func area(_ bins: [Double], _ size: CGSize) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in bins.enumerated() {
            p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height * (1 - CGFloat(v))))
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        return p
    }

    private func line(_ bins: [Double], _ size: CGSize) -> Path {
        var p = Path()
        for (i, v) in bins.enumerated() {
            let pt = CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height * (1 - CGFloat(v)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

/// Free-form curve: click to add a point, drag to move, drag a point off the graph to remove it.
/// Endpoints stay at x = 0 and x = 1 but can move up/down (fade blacks / dim whites).
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    let channel: CurveChannel
    let histogram: [Double]?
    let onBegin: () -> Void
    let onEnd: () -> Void
    @ViewState private var dragIndex: Int?

    private var color: Color {
        switch channel {
        case .master: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, sz in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 6), with: .color(.black.opacity(0.85)))
                if let h = histogram {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: sz.height))
                    for (i, v) in h.enumerated() {
                        p.addLine(to: CGPoint(x: CGFloat(i) / 255 * sz.width, y: sz.height * (1 - CGFloat(v) * 0.9)))
                    }
                    p.addLine(to: CGPoint(x: sz.width, y: sz.height))
                    ctx.fill(p, with: .color(color.opacity(0.18)))
                }
                var grid = Path()
                for f in [0.25, 0.5, 0.75] {
                    grid.move(to: CGPoint(x: f * sz.width, y: 0)); grid.addLine(to: CGPoint(x: f * sz.width, y: sz.height))
                    grid.move(to: CGPoint(x: 0, y: f * sz.height)); grid.addLine(to: CGPoint(x: sz.width, y: f * sz.height))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                var diag = Path()
                diag.move(to: CGPoint(x: 0, y: sz.height)); diag.addLine(to: CGPoint(x: sz.width, y: 0))
                ctx.stroke(diag, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var curve = Path()
                for i in 0...200 {
                    let x = Double(i) / 200
                    let pt = CGPoint(x: x * sz.width, y: (1 - CurveMath.eval(points, x)) * sz.height)
                    i == 0 ? curve.move(to: pt) : curve.addLine(to: pt)
                }
                ctx.stroke(curve, with: .color(color), lineWidth: 2)
                for p in points {
                    let c = CGPoint(x: p.x * sz.width, y: (1 - p.y) * sz.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(color))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.black), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                drag(g.location, size)
            }.onEnded { _ in
                dragIndex = nil
                onEnd()
            })
        }
    }

    private func drag(_ loc: CGPoint, _ size: CGSize) {
        let x = min(1, max(0, loc.x / size.width))
        let y = min(1, max(0, 1 - loc.y / size.height))
        var pts = points.sorted { $0.x < $1.x }
        if dragIndex == nil {
            onBegin()
            if let i = pts.indices.min(by: { dist(pts[$0], loc, size) < dist(pts[$1], loc, size) }),
               dist(pts[i], loc, size) < 12 {
                dragIndex = i
            } else {
                pts.append(CurvePoint(x: x, y: y))
                pts.sort { $0.x < $1.x }
                dragIndex = pts.firstIndex { $0.x == x && $0.y == y }
            }
        }
        guard let i = dragIndex, pts.indices.contains(i) else { return }
        let isEnd = i == 0 || i == pts.count - 1
        if !isEnd && (loc.y < -24 || loc.y > size.height + 24) {
            pts.remove(at: i)   // dragged off the graph
            dragIndex = nil
            points = pts
            onEnd()
            return
        }
        let lo = i == 0 ? 0 : pts[i - 1].x + 0.01
        let hi = i == pts.count - 1 ? 1 : pts[i + 1].x - 0.01
        pts[i] = CurvePoint(x: isEnd ? pts[i].x : min(hi, max(lo, x)), y: y)
        points = pts
    }

    private func dist(_ p: CurvePoint, _ loc: CGPoint, _ size: CGSize) -> CGFloat {
        hypot(p.x * size.width - loc.x, (1 - p.y) * size.height - loc.y)
    }
}

// MARK: - Info tab

struct InfoPanel: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(asset.baseName).font(.title3.bold())
                Text(asset.captureDate, format: .dateTime.weekday().day().month().year().hour().minute().second())
                    .font(.callout).foregroundStyle(.secondary)

                if let i = asset.info {
                    VStack(alignment: .leading, spacing: 4) {
                        if let c = i.camera { row("Camera", c) }
                        if let l = i.lens { row("Lens", l) }
                        let exposure = [i.focalLength.map { "\(Int($0)) mm" },
                                        i.aperture.map { String(format: "ƒ/%.1f", $0) },
                                        i.shutter.map(shutterText),
                                        i.iso.map { "ISO \($0)" }].compactMap { $0 }
                        if !exposure.isEmpty { row("Exposure", exposure.joined(separator: "  ")) }
                        if let w = i.width, let h = i.height {
                            row("Size", "\(w) × \(h)  (\(String(format: "%.1f", Double(w * h) / 1e6)) MP)")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(asset.allURLs, id: \.self) { u in
                        Text(u.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }

                Divider()
                HStack {
                    Text("Location").font(.subheadline.bold())
                    Spacer()
                    Button(asset.effectiveLocation == nil ? "Set…" : "Change…") { store.showGeotag = true }
                        .controlSize(.small)
                }
                if let loc = asset.effectiveLocation {
                    let c = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                    Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 4000, longitudinalMeters: 4000)),
                        interactionModes: []) {
                        Marker("", coordinate: c)
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id("\(loc.latitude),\(loc.longitude)")
                    if let name = loc.placeName { Text(name).font(.callout) }
                    Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude) + (asset.location == nil ? " · from camera" : " · set in Apixa"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("No location").font(.callout).foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    Text("People").font(.subheadline.bold())
                    Spacer()
                    if store.isIndexingFaces { ProgressView().controlSize(.mini); Text("indexing faces").font(.caption2).foregroundStyle(.secondary) }
                }
                if asset.faces.isEmpty {
                    Text("No faces detected").font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], alignment: .leading, spacing: 12) {
                        ForEach(Array(asset.faces.enumerated()), id: \.offset) { i, _ in
                            FaceCell(asset: asset, index: i)
                        }
                    }
                    Text("Click a face to name it. Names are saved in Apixa, searchable from the sidebar, and can go into XMP sidecars as keywords.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.visible, axes: .vertical)   // fixed scrollbar: panel width never jumps
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            Text(v).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func shutterText(_ s: Double) -> String {
        s >= 1 ? String(format: "%.1f s", s) : "1/\(Int((1 / s).rounded())) s"
    }
}

/// Square crop of a face from the cached thumbnail.
struct FaceThumb: View {
    let asset: PhotoAsset
    let face: FaceRegion

    var body: some View {
        Group {
            if let crop {
                Image(decorative: crop, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.square").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var crop: CGImage? {
        guard let cg = asset.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        // Vision rects are normalized with a bottom-left origin; pad 40% for context.
        let r = face.rect
        let side = max(r.width * W, r.height * H) * 1.4
        let cx = r.midX * W, cy = (1 - r.midY) * H
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        return rect.isEmpty ? nil : cg.cropping(to: rect.integral)
    }
}

// MARK: - Bars / filmstrip

struct MetricBar: View {
    let title: String
    let value: Double
    var note: String? = nil

    var body: some View {
        let v = min(max(value, 0), 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Int((v * 100).rounded()))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: v)
                .tint(note != nil ? Color.orange : Color.accentColor)
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct Filmstrip: View {
    @Environment(LibraryStore.self) private var store
    let stack: PhotoStack
    let selectedID: UUID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(stack.members) { a in
                        FilmCell(asset: a, selected: a.id == selectedID, showBest: stack.members.count > 1)
                            .id(a.id)
                            .onTapGesture { store.selectAsset(a.id) }
                            .contextMenu {
                                Button("Keep") { store.setDecision(a, .keep) }
                                Button("Reject") { store.setDecision(a, .reject) }
                                Button("Clear Mark") { store.setDecision(a, .undecided) }
                                Menu("Rating") {
                                    ForEach(1...5, id: \.self) { r in
                                        Button(String(repeating: "★", count: r)) { store.setRating(a, r) }
                                    }
                                    Divider()
                                    Button("Automatic") { store.setRating(a, nil) }
                                }
                                Divider()
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(a.allURLs)
                                }
                                Button("Open in Default App") { NSWorkspace.shared.open(a.displayURL) }
                            }
                    }
                }
                .padding(12)
            }
            .frame(height: 165)
            .onChange(of: selectedID) {
                withAnimation { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }
    }
}

struct FilmCell: View {
    let asset: PhotoAsset
    let selected: Bool
    let showBest: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let t = asset.thumbnail {
                        Image(nsImage: t).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 150, height: 100)
                .opacity(asset.decision == .reject ? 0.35 : 1)

                if showBest && asset.isBest {
                    Image(systemName: "crown.fill")
                        .foregroundStyle(.yellow)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) { decisionIcon.padding(4) }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))

            HStack(spacing: 4) {
                StarsView(stars: asset.displayStars, user: asset.userRating != nil, size: 9)
                if asset.rawURL != nil { TypeTag(text: "RAW") }
                if asset.jpegURL != nil { TypeTag(text: "JPG") }
                if !asset.adjustments.isIdentity {
                    Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.secondary).help("Edited")
                }
                if asset.effectiveLocation != nil {
                    Image(systemName: "mappin").font(.caption2).foregroundStyle(.secondary).help("Has location")
                }
                if asset.isBlurry {
                    Image(systemName: "camera.metering.unknown").font(.caption2).foregroundStyle(.orange)
                        .help("Looks blurry")
                }
            }
        }
    }

    @ViewBuilder private var decisionIcon: some View {
        switch asset.decision {
        case .keep:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .green)
        case .reject:
            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .red)
        case .undecided:
            EmptyView()
        }
    }
}

// MARK: - Small pieces

struct ThumbView: View {
    let asset: PhotoAsset
    let size: CGFloat

    var body: some View {
        ZStack {
            if let t = asset.thumbnail {
                Image(nsImage: t).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Stars: solid when you rated it, faded when it's the automatic rating.
struct StarsView: View {
    let stars: Int
    var user = false
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= stars ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i <= stars ? Color.yellow.opacity(user ? 1 : 0.45) : Color.secondary)
            }
        }
    }
}

struct TypeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(text == "RAW" ? Color.orange.opacity(0.3) : Color.blue.opacity(0.3)))
    }
}

/// One detected face: crop, name (or suggestion), click to name.
struct FaceCell: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    let index: Int
    @ViewState private var editing = false

    var body: some View {
        let face = asset.faces[index]
        let name = asset.name(of: face)
        let suggestion = name == nil ? store.suggestion(for: asset, faceIndex: index) : nil
        VStack(spacing: 4) {
            FaceThumb(asset: asset, face: face)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(name != nil ? Color.accentColor : Color.clear, lineWidth: 2))
            if let name {
                Text(name).font(.caption).lineLimit(1)
            } else if let s = suggestion {
                Button { store.nameFace(asset, face, s.name) } label: {
                    Text("\(s.name)?").font(.caption).lineLimit(1)
                }
                .buttonStyle(.link)
                .help("Looks like \(s.name). Click to confirm.")
            } else {
                Text("Unknown").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            FaceNamePopover(asset: asset, index: index, initial: name ?? suggestion?.name ?? "") { editing = false }
                .environment(store)
        }
    }
}

struct FaceNamePopover: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    let index: Int
    let initial: String
    let done: () -> Void
    @ViewState private var text = ""
    @ViewState private var named: String?
    @FocusState private var focused: Bool

    var body: some View {
        let face = asset.faces[index]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FaceThumb(asset: asset, face: face)
                VStack(alignment: .leading) {
                    Text("Who is this?").font(.headline)
                    TextField("Name", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { save(text) }
                        .frame(width: 180)
                }
            }
            let known = store.people.map(\.name).filter { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }.prefix(6)
            if !known.isEmpty {
                FlowNames(names: Array(known)) { save($0) }
            }
            if let n = named {
                let similar = store.similarUnnamedFaces(to: asset, faceIndex: index)
                if !similar.isEmpty {
                    Divider()
                    Text("\(similar.count) unnamed face\(similar.count == 1 ? "" : "s") look like \(n).").font(.callout)
                    HStack {
                        Button("Name Them \(n)") { store.nameFaces(similar, n); done() }
                            .buttonStyle(.borderedProminent)
                        Button("Not Now") { done() }
                    }
                    Text("Undo with ⌘Z if any are wrong.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                if asset.name(of: face) != nil {
                    Button("Remove Name", role: .destructive) { store.nameFace(asset, face, nil); done() }
                }
                Spacer()
                if named == nil {
                    Button("Save") { save(text) }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { text = initial; focused = true; store.isEditingText = true }
        .onDisappear { store.isEditingText = false }
    }

    private func save(_ n: String) {
        let t = n.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.nameFace(asset, asset.faces[index], t)
        text = t
        if store.similarUnnamedFaces(to: asset, faceIndex: index).isEmpty { done() } else { named = t }
    }
}

/// Existing names as quick-pick buttons.
struct FlowNames: View {
    let names: [String]
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { n in
                Button(n) { pick(n) }.controlSize(.small).lineLimit(1)
            }
        }
    }
}

/// Controls for the photo itself, above the preview: source, compare, clipping, background, zoom.
struct PreviewBar: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            if asset.isPair {
                Picker("Source", selection: $store.previewRaw) {
                    Text("JPEG").tag(false)
                    Text("RAW").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Preview the camera JPEG or the RAW 9 render (R)")
            } else {
                Text(asset.isRawOnly ? "RAW" : (asset.jpegURL?.pathExtension.uppercased() ?? ""))
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            // Comparing only means something once the photo has edits.
            if !asset.adjustments.isIdentity {
                Divider().frame(height: 18)
                Picker("Compare", selection: $store.compareMode) {
                    Text("Edited").tag(CompareMode.off)
                    Text("Side by Side").tag(CompareMode.sideBySide)
                    Text("Split").tag(CompareMode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Compare with the unedited photo (Y)")
            }
            Toggle(isOn: $store.showClipping) { Label("Clipping", systemImage: "exclamationmark.triangle") }
                .toggleStyle(.button)
                .help("Red = blown highlights, blue = crushed shadows (J)")
            Menu {
                Picker("Background", selection: $store.viewerBackground) {
                    ForEach(ViewerBackground.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Margin", selection: $store.viewerMargin) {
                    ForEach(ViewerMargin.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Background", systemImage: "square.inset.filled")
            }
            .fixedSize()
            .help("Background and border around the photo (G)")
            Spacer()
            // One zoom control that shows where you are (not what the button would do).
            Menu {
                Button("Fit") { ZoomCommand.fit.post() }
                Button("100%") { ZoomCommand.actual.post() }
                Divider()
                Button("Zoom In") { ZoomCommand.zoomIn.post() }
                Button("Zoom Out") { ZoomCommand.zoomOut.post() }
            } label: {
                Label(store.zoom.scale.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit", systemImage: "magnifyingglass")
                    .monospacedDigit()
            } primaryAction: {
                ZoomCommand.toggle.post()
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .help("Zoom: click to switch between Fit and 100% (Z), or pick a level. Pinch or ⌘-scroll also zooms.")
            .disabled(store.cropMode)
            Divider().frame(height: 18)
            Toggle(isOn: $store.showStrip) { Image(systemName: "rectangle.bottomthird.inset.filled") }
                .toggleStyle(.button)
                .help(store.showStrip ? "Hide the strip below (⌥⌘B)" : "Show the strip below (⌥⌘B)")
            Toggle(isOn: $store.showInspector) { Image(systemName: "sidebar.right") }
                .toggleStyle(.button)
                .help(store.showInspector ? "Hide the right panel (⌥⌘I)" : "Show the right panel (⌥⌘I)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// A titled section of the Adjust tab that folds away (remembered per section).
struct CollapsibleSection<Content: View>: View {
    let title: String
    @AppStorage private var open: Bool
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        // Everyday sections start open; the bulkier ones start folded.
        _open = AppStorage(wrappedValue: !["Curves", "Detail"].contains(title), "adjust.open.\(title)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).font(.subheadline.bold())
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide \(title)" : "Show \(title)")
            if open { content }
        }
    }
}

/// Main content with a trailing panel you can resize by dragging the divider (width remembered;
/// double-click the divider to reset).
struct TrailingPanelLayout<Main: View, Panel: View>: View {
    @AppStorage private var width: Double
    private let defaultWidth: Double, minWidth: Double, maxWidth: Double
    private let main: Main, panel: Panel
    @ViewState private var dragStart: Double?
    @ViewState private var hovering = false

    private let show: Bool

    init(key: String, defaultWidth: Double, minWidth: Double = 240, maxWidth: Double = 620, show: Bool = true,
         @ViewBuilder main: () -> Main, @ViewBuilder panel: () -> Panel) {
        _width = AppStorage(wrappedValue: defaultWidth, key)
        self.show = show
        self.defaultWidth = defaultWidth; self.minWidth = minWidth; self.maxWidth = maxWidth
        self.main = main(); self.panel = panel()
    }

    var body: some View {
        HStack(spacing: 0) {
            main.frame(maxWidth: .infinity, maxHeight: .infinity)
            if show { handleAndPanel }
        }
    }

    private var handleAndPanel: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(hovering || dragStart != nil ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
                .frame(width: hovering || dragStart != nil ? 2 : 1)
                .overlay(
                    Color.clear.frame(width: 9).contentShape(Rectangle())
                        .onHover { inside in
                            hovering = inside
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(maxWidth, max(minWidth, start - g.translation.width))
                            }
                            .onEnded { _ in dragStart = nil })
                        .onTapGesture(count: 2) { width = defaultWidth }
                        .help("Drag to resize · double-click to reset")
                )
            panel.frame(width: min(maxWidth, max(minWidth, width)))
        }
    }
}

/// A small grab bar: drag vertically to resize the view above it; double-click to reset.
struct ResizeGrip: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    let defaultHeight: Double
    @ViewState private var start: Double?

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(start == nil ? 0.35 : 0.7))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, minHeight: 10)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let s0 = start ?? height
                    start = s0
                    height = min(range.upperBound, max(range.lowerBound, s0 + g.translation.height))
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { height = defaultHeight }
            .help("Drag to resize · double-click to reset")
    }
}
