import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MainMode: String, CaseIterable, Identifiable {
    case photo = "Photo", looks = "Looks", map = "Map"
    var id: String { rawValue }
}

/// Your own looks (customised presets, or recipes you enter). Stored in Apixa's Application Support,
/// never inside the app, so licensed recipes stay personal.
enum MyLooksStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apixa/my-looks.json")
    }

    static func load() -> [LookRecipe] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([LookRecipe].self, from: $0) } ?? []
    }

    static func save(_ looks: [LookRecipe]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(looks).write(to: url, options: .atomic)
    }
}

extension LibraryStore {
    var allLooks: [LookRecipe] { LookRecipe.builtIn + myLooks }

    func addMyLook(_ r: LookRecipe) {
        var r = r
        r.group = "My Looks"
        myLooks.removeAll { $0.name == r.name }
        myLooks.append(r)
        MyLooksStore.save(myLooks)
    }

    /// A look is open (enlarged): arrows browse looks (← →) and photos (↑ ↓).
    var browsingLooks: Bool { mainMode == .looks && lookFocus != nil }

    func arrowHorizontal(_ d: Int) {
        if browsingLooks { moveLook(d) } else { movePhoto(d) }
    }

    func arrowVertical(_ d: Int) {
        if browsingLooks { stepPhoto(d) } else { moveStack(d) }
    }

    func moveLook(_ d: Int) {
        let list = allLooks
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == lookFocus?.id } ?? 0
        lookFocus = list[(i + d + list.count) % list.count]
    }

    /// Next/previous photo across groups (keeps the open look).
    func stepPhoto(_ d: Int) {
        let flat = visibleStacks.flatMap(\.members)
        guard let cur = selectedAsset, let i = flat.firstIndex(where: { $0 === cur }) else { return }
        let j = i + d
        guard flat.indices.contains(j) else { return }
        let target = flat[j]
        if let s = visibleStacks.first(where: { $0.members.contains { $0 === target } }), s.id != selectedStackID {
            selectGroup(s.id)
        }
        selectedAssetID = target.id
    }

    /// Photos the arrow keys go to next from `a`: right, left, then the next and previous group.
    func neighbors(of a: PhotoAsset) -> [PhotoAsset] {
        let stacks = visibleStacks
        let flat = stacks.flatMap(\.members)
        guard let i = flat.firstIndex(where: { $0 === a }) else { return [] }
        var out: [PhotoAsset] = []
        func add(_ x: PhotoAsset?) { if let x, x !== a, !out.contains(where: { $0 === x }) { out.append(x) } }
        add(flat.indices.contains(i + 1) ? flat[i + 1] : nil)
        add(flat.indices.contains(i - 1) ? flat[i - 1] : nil)
        if let si = stacks.firstIndex(where: { $0.members.contains { $0 === a } }) {
            if stacks.indices.contains(si + 1) { add(stacks[si + 1].members.first { $0.isBest } ?? stacks[si + 1].members.first) }
            if stacks.indices.contains(si - 1) { add(stacks[si - 1].members.first { $0.isBest } ?? stacks[si - 1].members.first) }
        }
        return out
    }

    /// Photo / Looks / Map from anywhere (toolbar, menu, full screen). Looks needs a photo, so pick one.
    func switchMode(_ m: MainMode) {
        lookFocus = nil
        if m == .looks, selectedAsset == nil { selectGroup(visibleStacks.first?.id) }
        mainMode = m
    }

    func importLooks(_ looks: [LookRecipe]) {
        for r in looks {
            myLooks.removeAll { $0.id == r.id }
            myLooks.append(r)
        }
        MyLooksStore.save(myLooks)
        statusMessage = "Added \(looks.count) look(s)"
    }

    /// Built-ins first, then your groups in the order they were added.
    var lookGroups: [(String, [LookRecipe])] {
        var order: [String] = []
        var map: [String: [LookRecipe]] = [:]
        for r in allLooks {
            if map[r.group] == nil { order.append(r.group) }
            map[r.group, default: []].append(r)
        }
        return order.map { ($0, map[$0]!) }
    }

    func deleteMyLook(_ r: LookRecipe) {
        myLooks.removeAll { $0.id == r.id }
        MyLooksStore.save(myLooks)
    }

    func applyLook(_ r: LookRecipe?, to targets: [PhotoAsset]) {
        change(targets, name: r == nil ? "Remove Look" : "Apply \(r!.name)") { $0.adjustments.look = r }
    }

    /// A full-resolution JPEG of the photo with this look (and your edits). Never overwrites.
    func saveLookJPEG(_ a: PhotoAsset, _ r: LookRecipe) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.jpeg]
        let safe = r.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        p.nameFieldStringValue = "\(a.baseName)-\(safe).jpg"
        p.directoryURL = a.folder
        guard p.runModal() == .OK, let dest = p.url else { return }
        if assets.contains(where: { $0.allURLs.contains { $0.standardizedFileURL == dest.standardizedFileURL } }) {
            statusMessage = "Not saved: that would replace an original photo. Choose another name."
            return
        }
        var adj = a.adjustments
        adj.look = r
        let raw = a.rawURL, jpeg = a.jpegURL, loc = a.location, rating = a.userRating
        statusMessage = "Saving \(dest.lastPathComponent)…"
        Task {
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
                try await Develop.saveCopy(raw: raw, jpeg: jpeg, useRaw: raw != nil, adjustments: adj, location: loc,
                                           rating: rating, options: .init(), to: dest)
                statusMessage = "Saved \(dest.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Grid of every look on the current photo

struct LooksView: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    @ViewState private var showImport = false
    @AppStorage("lookTileSize") private var tileSize = 360.0

    var body: some View {
        if let focus = store.lookFocus {
            LookDetailView(asset: asset, preset: focus)
                .id(focus.id)   // a different look starts with fresh (uncustomised) settings
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Creative Looks").font(.title2.bold())
                        Text(asset.baseName).foregroundStyle(.secondary)
                        Spacer()
                        if let applied = asset.adjustments.look {
                            Text("Applied: \(applied.name)").font(.callout)
                            Button("Remove") { store.applyLook(nil, to: [asset]) }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $tileSize, in: 220...640).frame(width: 120).controlSize(.small)
                            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                        }
                        .help("Tile size")
                        Button { showImport = true } label: { Label("Import Recipes…", systemImage: "square.and.arrow.down.on.square") }
                    }
                    Text(asset.rawURL != nil
                         ? "Rendered from the RAW with your edits. Click a look to enlarge, customise or save it as a JPEG."
                         : "This shot has no RAW file. Looks are applied to the JPEG, so white balance changes are approximate.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(store.lookGroups, id: \.0) { title, looks in
                        Text(title).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 16)], spacing: 18) {
                            ForEach(looks) { r in
                                LookTile(asset: asset, recipe: r, height: tileSize * 0.68)
                                    .onTapGesture { store.lookFocus = r }
                                    .contextMenu {
                                        Button("Apply to Photo") { store.applyLook(r, to: [asset]) }
                                        Button("Apply to Selected Groups") { store.applyLook(r, to: store.selectedGroupAssets) }
                                        Button("Save JPEG…") { store.saveLookJPEG(asset, r) }
                                        if !LookRecipe.builtIn.contains(r) {
                                            Divider()
                                            Button("Delete Look", role: .destructive) { store.deleteMyLook(r) }
                                        }
                                    }
                            }
                        }
                    }
                    Text("Sony's Creative Look processing is proprietary; these are Apixa's approximations built from the same controls the camera uses.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .sheet(isPresented: $showImport) { RecipeImportSheet().environment(store) }
        }
    }


}

/// Rendered tiles, so returning to the grid (or to a photo) is instant.
@MainActor
enum LookTileCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()
    static func key(_ id: UUID, _ adj: Adjustments, _ raw: Bool) -> NSString { "\(id)|\(adj.hashValue)|\(raw)" as NSString }
    static func get(_ k: NSString) -> NSImage? { cache.object(forKey: k) }
    static func put(_ k: NSString, _ img: NSImage) { cache.setObject(img, forKey: k) }
}

struct LookTile: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    let recipe: LookRecipe
    var height: Double = 240
    var compact = false
    @ViewState private var image: NSImage?

    private struct Key: Hashable { let id: UUID; let recipe: LookRecipe; let adj: Adjustments; let raw: Bool }

    var body: some View {
        let applied = asset.adjustments.look == recipe
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.2))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if let t = asset.thumbnail {
                    Image(nsImage: t).resizable().scaledToFit().opacity(0.35)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(applied ? Color.accentColor : Color.clear, lineWidth: 3))
            if compact {
                Text(recipe.name).font(.caption2).lineLimit(1)
            } else {
                Text(recipe.name).font(.callout.bold()).lineLimit(1)
                Text(recipe.notes ?? recipe.settingsLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let c = recipe.credit { Text(c).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .contentShape(Rectangle())
        .task(id: Key(id: asset.id, recipe: recipe, adj: asset.adjustments, raw: asset.rawURL != nil)) {
            var adj = asset.adjustments
            adj.look = recipe
            let ck = LookTileCache.key(asset.id, adj, asset.rawURL != nil)
            if let hit = LookTileCache.get(ck) { image = hit; return }
            image = nil
            // One decode serves every tile; white balance per look is approximated on the GPU.
            if let r = await Develop.renderScaled(raw: asset.rawURL, jpeg: asset.jpegURL, useRaw: asset.rawURL != nil,
                                                  adjustments: adj, maxPixel: 900, draft: true, interactive: true),
               !Task.isCancelled {
                let img = NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
                LookTileCache.put(ck, img)
                image = img
            }
        }
    }
}

// MARK: - One look, enlarged, with Sony-style controls

struct LookDetailView: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    let preset: LookRecipe
    @ViewState private var draft: LookRecipe?
    @ViewState private var newName = ""
    @ViewState private var naming = false
    @ViewState private var customising = false


    var body: some View {
        let r = draft ?? preset
        TrailingPanelLayout(key: PanelWidth.looks.key, defaultWidth: PanelWidth.looks.default, minWidth: PanelWidth.looks.range.lowerBound, maxWidth: PanelWidth.looks.range.upperBound, show: store.showInspector) {
            VStack(spacing: 0) {
                HStack {
                    Button { store.lookFocus = nil } label: { Label("All Looks", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                    Text(r.name).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                PreviewBar(asset: asset)
                Divider()
                PreviewView(asset: asset, chrome: true, lookOverride: r)
                if store.showStrip {
                    Divider()
                    LookStrip(asset: asset, current: preset)
                }
            }
        } panel: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(r.name).font(.title3.bold())
                    if let n = r.notes { Text(n).font(.callout).foregroundStyle(.secondary) }
                    if let c = r.credit { Text(c).font(.caption).foregroundStyle(.tertiary) }
                    Text("Camera: " + r.settingsLine).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .help("What you'd dial into a Sony body for this recipe")

                    Button { store.applyLook(r, to: [asset]); store.lookFocus = nil; store.mainMode = .photo } label: {
                        Label("Use This Look", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button { store.saveLookJPEG(asset, r) } label: {
                        Label("Save as JPEG…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    Text("Your edits from the Adjust tab (including noise reduction) are already in this preview; the look goes on top.")
                        .font(.caption2).foregroundStyle(.secondary)

                    DisclosureGroup(isExpanded: $customising) {
                        VStack(alignment: .leading, spacing: 12) {
                            LookEditor(recipe: Binding(get: { draft ?? preset }, set: { draft = $0 }))
                            if naming {
                                HStack {
                                    TextField("Look name", text: $newName)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit(saveLook)
                                        .onAppear { store.isEditingText = true }
                                        .onDisappear { store.isEditingText = false }
                                    Button("Save", action: saveLook).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            } else {
                                Button { newName = draft == nil ? r.name + " (mine)" : r.name; naming = true } label: {
                                    Label("Save as My Look…", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                                }
                            }
                            if draft != nil {
                                Button("Reset to \(preset.name)") { draft = nil }.controlSize(.small)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label(draft == nil ? "Customise" : "Customise (edited)", systemImage: "slider.horizontal.3").font(.headline)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.visible, axes: .vertical)
        }
    }

    private func saveLook() {
        var r = draft ?? preset
        r.name = newName.trimmingCharacters(in: .whitespaces)
        r.notes = nil
        guard !r.name.isEmpty else { return }
        store.addMyLook(r)
        naming = false
        store.statusMessage = "Saved look “\(r.name)”"
    }
}

/// Every control a Sony Creative Look exposes, in the camera's own units and ranges (Sony Help Guide).
struct LookEditor: View {
    @Binding var recipe: LookRecipe

    var body: some View {
        if recipe.profile != nil {
            ProfileEditor(recipe: $recipe, wbAndShift: AnyView(wbControls))
        } else {
            creativeLook
        }
    }

    private var wbControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("White Balance", selection: $recipe.wb) {
                ForEach(WhiteBalance.allCases) { Text($0.rawValue).tag($0) }
            }
            if recipe.wb == .colorTemp {
                let k = recipe.kelvin ?? 5500
                row("Color temp", "\(k) K") {
                    Slider(value: Binding(get: { Double(recipe.kelvin ?? 5500) }, set: { recipe.kelvin = Int(($0 / 100).rounded()) * 100 }),
                           in: 2500...9900)
                }
            }
            shiftRow("Color Filter A–B", \.shiftAB, "A", "B")
            shiftRow("Color Filter G–M", \.shiftGM, "M", "G")
        }
    }

    private func shiftRow(_ title: String, _ kp: WritableKeyPath<LookRecipe, Double>, _ pos: String, _ neg: String) -> some View {
        let v = recipe[keyPath: kp]
        let txt = v == 0 ? "0" : (v > 0 ? pos : neg) + String(format: "%g", abs(v))
        return row(title, txt, isDefault: v == 0, reset: { recipe[keyPath: kp] = 0 }) {
            Slider(value: Binding(get: { recipe[keyPath: kp] }, set: { recipe[keyPath: kp] = ($0 * 4).rounded() / 4 }),
                   in: -7...7, step: 0.25)
        }
    }

    private var creativeLook: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Creative Look", selection: $recipe.base) {
                ForEach(CreativeLook.allCases) { Text("\($0.rawValue) · \($0.title)").tag($0) }
            }
            Text(recipe.base.summary).font(.caption).foregroundStyle(.secondary)
            Text("Sliders show the look's total effect. The camera itself hides a look's own character and starts every slider at 0; that camera value is the “Camera:” line above.")
                .font(.caption2).foregroundStyle(.secondary)
            step("Contrast", \.contrast, -9...9, base: recipe.base.baseContrast)
            step("Highlights", \.highlights, -9...9, base: recipe.base.baseHighlights)
            step("Shadows", \.shadows, -9...9)
            step("Fade", \.fade, 0...9, base: recipe.base.baseFade)
            step("Saturation", \.saturation, -9...9, base: recipe.base.baseSaturation)
                .disabled(recipe.base.isMono)
            step("Sharpness", \.sharpness, 0...9)
            step("Sharpness Range", \.sharpnessRange, 1...5, zero: 3)
            step("Clarity", \.clarity, 0...9)
            Divider()
            Picker("White Balance", selection: $recipe.wb) {
                ForEach(WhiteBalance.allCases) { Text($0.rawValue).tag($0) }
            }
            if recipe.wb == .colorTemp {
                let k = recipe.kelvin ?? 5500
                row("Color temp", "\(k) K") {
                    Slider(value: Binding(get: { Double(recipe.kelvin ?? 5500) }, set: { recipe.kelvin = Int(($0 / 100).rounded()) * 100 }),
                           in: 2500...9900)
                }
            }
            shiftRow("Shift A–B", \.shiftAB, "A", "B")
            shiftRow("Shift G–M", \.shiftGM, "M", "G")
            Picker("DRO", selection: $recipe.dro) {
                Text("Off").tag(0)
                ForEach(1...5, id: \.self) { Text("Lv\($0)").tag($0) }
            }
        }
        .controlSize(.small)
    }

    /// `base` = the look's own value on this scale; the slider shows base + recipe offset.
    private func step(_ title: String, _ kp: WritableKeyPath<LookRecipe, Int>, _ range: ClosedRange<Int>,
                      zero: Int = 0, base: Int = 0, label: ((Int) -> String)? = nil) -> some View {
        let shown = base + recipe[keyPath: kp]
        let lo = min(range.lowerBound, base), hi = max(range.upperBound, base)
        return row(title, label?(shown) ?? (shown > 0 && range.lowerBound < 0 ? "+\(shown)" : "\(shown)"),
                   isDefault: recipe[keyPath: kp] == zero, reset: { recipe[keyPath: kp] = zero }) {
            Slider(value: Binding(get: { Double(base + recipe[keyPath: kp]) },
                                  set: { recipe[keyPath: kp] = Int($0.rounded()) - base }),
                   in: Double(lo)...Double(hi), step: 1)
        }
    }

    private func row(_ title: String, _ value: String, isDefault: Bool = false, reset: (() -> Void)? = nil,
                     @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(isDefault ? .secondary : .primary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset?() }
            .help(reset == nil ? "" : "Double-click to reset")
            control()
        }
    }
}

/// Picture Profile controls (PP menu), camera units and ranges.
struct ProfileEditor: View {
    @Binding var recipe: LookRecipe
    let wbAndShift: AnyView

    private var p: Binding<PictureProfile> {
        Binding(get: { recipe.profile ?? PictureProfile() }, set: { recipe.profile = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Picture Profile").font(.headline)
            Text("Rendered from the RAW with the camera's tone curve bypassed, like a PP on the body. S-Log follows Sony's published curves; Still/Movie/Cine and colour modes are approximations.")
                .font(.caption2).foregroundStyle(.secondary)
            int("Black Level", \.blackLevel, -15...15)
            Picker("Gamma", selection: p.gamma) { ForEach(PictureProfile.Gamma.allCases) { Text($0.rawValue).tag($0) } }
            HStack {
                Picker("Black Gamma", selection: p.blackGammaRange) {
                    ForEach(PictureProfile.BlackGammaRange.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            int("Black Gamma Level", \.blackGammaLevel, -7...7)
            Toggle("Knee: Auto", isOn: p.kneeAuto)
            if !(recipe.profile?.kneeAuto ?? true) {
                labeled("Knee Point", String(format: "%g%%", recipe.profile?.kneePoint ?? 90)) {
                    Slider(value: p.kneePoint, in: 75...105, step: 2.5)
                }
                int("Knee Slope", \.kneeSlope, -5...5)
            }
            Picker("Color Mode", selection: p.colorMode) { ForEach(PictureProfile.ColorMode.allCases) { Text($0.rawValue).tag($0) } }
            int("Saturation", \.saturation, -32...32)
            int("Color Phase", \.colorPhase, -7...7)
            Text("Color Depth").font(.callout)
            ForEach(0..<6, id: \.self) { i in
                labeled("  " + PictureProfile.depthNames[i], signed(recipe.profile?.colorDepth[i] ?? 0)) {
                    Slider(value: Binding(get: { Double(recipe.profile?.colorDepth[i] ?? 0) },
                                          set: { recipe.profile?.colorDepth[i] = Int($0.rounded()) }), in: -7...7, step: 1)
                }
            }
            int("Detail", \.detail, -7...2)
            Divider()
            wbAndShift
        }
        .controlSize(.small)
    }

    private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }

    private func int(_ title: String, _ kp: WritableKeyPath<PictureProfile, Int>, _ r: ClosedRange<Int>) -> some View {
        let v = recipe.profile?[keyPath: kp] ?? 0
        return labeled(title, signed(v), reset: { recipe.profile?[keyPath: kp] = 0 }) {
            Slider(value: Binding(get: { Double(recipe.profile?[keyPath: kp] ?? 0) },
                                  set: { recipe.profile?[keyPath: kp] = Int($0.rounded()) }),
                   in: Double(r.lowerBound)...Double(r.upperBound), step: 1)
        }
    }

    private func labeled(_ title: String, _ value: String, reset: (() -> Void)? = nil, @ViewBuilder _ c: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.caption.monospacedDigit()).frame(minWidth: 44, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset?() }
            c()
        }
    }
}

/// Every look as a small thumbnail under the enlarged photo; click to switch (or use ← →).
struct LookStrip: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    let current: LookRecipe

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(store.allLooks) { r in
                        LookTile(asset: asset, recipe: r, height: 74, compact: true)
                            .frame(width: 112)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(r.id == current.id ? Color.accentColor : Color.clear, lineWidth: 3)
                                .padding(.bottom, 18))
                            .id(r.id)
                            .onTapGesture { store.lookFocus = r }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(height: 112)
            .onAppear { proxy.scrollTo(current.id, anchor: .center) }
            .onChange(of: current.id) { withAnimation { proxy.scrollTo(current.id, anchor: .center) } }
        }
        .help("← → previous / next look · ↑ ↓ previous / next photo")
    }
}
