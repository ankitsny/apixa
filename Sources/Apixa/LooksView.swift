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

extension LookRecipe {
    /// Sony's own looks carry their code in the tile badge, so they show just the name.
    var displayName: String { group == "Sony Creative Looks" ? base.title : name }
}

/// One group of looks in the grid, with the short chip label and a line describing it.
struct LookSection: Identifiable {
    static let favorites = "★ Favorites"
    let id: String
    let looks: [LookRecipe]

    var title: String { id == Self.favorites ? "Favorites" : id }
    var isMine: Bool { id != Self.favorites && !LookRecipe.builtInGroups.contains(id) }

    var chip: String {
        switch id {
        case Self.favorites: "Favorites"
        case "Sony Creative Looks": "Sony Looks"
        case "Fujifilm Simulations": "Fujifilm"
        case "Sony Alpha Recipes": "Alpha Recipes"
        case "Apple Photo Filters": "Apple"
        default: id
        }
    }

    var symbol: String {
        switch id {
        case Self.favorites: "star.fill"
        case "Sony Creative Looks": "camera"
        case "Fujifilm Simulations": "film"
        case "Sony Alpha Recipes": "list.bullet.rectangle"
        case "Apple Photo Filters": "camera.filters"
        default: looks.allSatisfy(\.isProfile) ? "slider.horizontal.below.square.filled.and.square" : "folder"
        }
    }

    var blurb: String {
        switch id {
        case Self.favorites: "Looks you starred."
        case "Sony Creative Looks": "The camera's own looks, as Apixa renders them from your photo."
        case "Fujifilm Simulations": "Fuji film simulations built from Creative Looks, by Veres Deni Alex. Fuji renders darker: lower Exposure 0.3–0.7 to match."
        case "Sony Alpha Recipes": "Published on Sony's Alpha Recipes site."
        case "Apple Photo Filters": "Apple's built-in photo effects; the sliders still work on top."
        default: looks.allSatisfy(\.isProfile) ? "Your Picture Profile recipes." : "Your looks."
        }
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

    /// ← → step through the looks in view (the chosen group, or every group).
    func moveLook(_ d: Int) {
        let list = lookFocus.map(stripLooks(for:)) ?? visibleLooks
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

    /// Sections of the Looks grid: Favorites, Sony's looks and the built-in recipes, your own groups,
    /// then Apple's filters.
    var lookSections: [LookSection] {
        var out: [LookSection] = []
        let favs = allLooks.filter { favoriteLooks.contains($0.id) }
        if !favs.isEmpty { out.append(LookSection(id: LookSection.favorites, looks: favs)) }
        let groups = lookGroups
        let rank = { (g: String) -> Int in
            switch g {
            case "Sony Creative Looks": 0
            case "Fujifilm Simulations": 1
            case "Sony Alpha Recipes": 2
            case "Apple Photo Filters": 9
            default: 5
            }
        }
        for (g, looks) in groups.enumerated().sorted(by: { (rank($0.element.0), $0.offset) < (rank($1.element.0), $1.offset) }).map(\.element) {
            out.append(LookSection(id: g, looks: looks))
        }
        return out
    }

    /// Sections after the group chip and search are applied.
    var visibleLookSections: [LookSection] {
        let q = lookSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return lookSections
            .filter { lookFilter == "All" ? true : $0.id == lookFilter }
            .compactMap { sec in
                guard !q.isEmpty else { return sec }
                let hit = sec.looks.filter { r in
                    [r.name, r.notes ?? "", r.credit ?? "", r.group, r.base.title, r.base.rawValue].contains { $0.lowercased().contains(q) }
                }
                return hit.isEmpty ? nil : LookSection(id: sec.id, looks: hit)
            }
    }

    /// Every look in view, once each, in grid order.
    var visibleLooks: [LookRecipe] {
        var seen = Set<String>()
        return visibleLookSections.flatMap(\.looks).filter { seen.insert($0.id).inserted }
    }

    /// The looks shown under an enlarged look: its section in view (or its own group).
    func stripLooks(for r: LookRecipe) -> [LookRecipe] {
        let secs = visibleLookSections
        if lookFilter != "All", let s = secs.first(where: { $0.looks.contains { $0.id == r.id } }) { return s.looks }
        return lookSections.first { $0.id == r.group }?.looks ?? allLooks
    }

    func toggleFavorite(_ r: LookRecipe) {
        if favoriteLooks.contains(r.id) { favoriteLooks.remove(r.id) } else { favoriteLooks.insert(r.id) }
    }

    /// Move one of your looks to another of your groups (or a new one).
    func moveMyLook(_ r: LookRecipe, to group: String) {
        guard let i = myLooks.firstIndex(where: { $0.id == r.id }), !group.isEmpty, group != r.group else { return }
        let wasFav = favoriteLooks.contains(r.id)
        myLooks[i].group = group
        if wasFav { favoriteLooks.remove(r.id); favoriteLooks.insert(myLooks[i].id) }
        MyLooksStore.save(myLooks)
        statusMessage = "Moved “\(r.name)” to \(group)"
    }

    /// Rename one of your groups (built-in groups keep their names).
    func renameLookGroup(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old, !LookRecipe.builtInGroups.contains(old) else { return }
        for i in myLooks.indices where myLooks[i].group == old {
            let oldID = myLooks[i].id
            myLooks[i].group = name
            if favoriteLooks.contains(oldID) { favoriteLooks.remove(oldID); favoriteLooks.insert(myLooks[i].id) }
        }
        if lookFilter == old { lookFilter = name }
        MyLooksStore.save(myLooks)
        statusMessage = "Renamed group to \(name)"
    }

    /// Your own groups, for "Move to Group".
    var myLookGroups: [String] {
        var seen: [String] = []
        for r in myLooks where !seen.contains(r.group) { seen.append(r.group) }
        if !seen.contains("My Looks") { seen.append("My Looks") }
        return seen
    }

    func deleteMyLook(_ r: LookRecipe) {
        favoriteLooks.remove(r.id)
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
    @ViewState private var renaming: String?
    @ViewState private var newGroupName = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("lookTileArea") private var tileSize = 210.0
    @AppStorage("collapsedLookGroups") private var collapsedRaw = ""

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private func toggleCollapsed(_ id: String) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        collapsedRaw = c.sorted().joined(separator: "\n")
    }

    var body: some View {
        if let focus = store.lookFocus {
            LookDetailView(asset: asset, preset: focus)
                .id(focus.id)   // a different look starts with fresh (uncustomised) settings
        } else {
            VStack(spacing: 0) {
                header
                chips
                Divider()
                grid
            }
            .sheet(isPresented: $showImport) { RecipeImportSheet().environment(store) }
            .alert("Rename Group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Group name", text: $newGroupName)
                Button("Rename") { if let r = renaming { store.renameLookGroup(r, to: newGroupName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Looks").font(.title2.bold())
                Text(asset.rawURL != nil ? "\(asset.baseName) · from the RAW, with your edits" : "\(asset.baseName) · JPEG only, white balance is approximate")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let applied = asset.adjustments.look {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(applied.name).lineLimit(1)
                    Button { store.applyLook(nil, to: [asset]) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove the look from this photo")
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .help("Look applied to this photo")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search looks", text: Binding(get: { store.lookSearch }, set: { store.lookSearch = $0 }))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: searchFocused) { _, f in store.isEditingText = f }
                    .onExitCommand { store.lookSearch = ""; searchFocused = false }
                if !store.lookSearch.isEmpty {
                    Button { store.lookSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(width: 200)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $tileSize, in: 140...420).frame(width: 90).controlSize(.mini)
                Image(systemName: "square.grid.2x2.fill").font(.caption).foregroundStyle(.secondary)
            }
            .help("Tile size")
            Button { showImport = true } label: { Label("Import", systemImage: "square.and.arrow.down.on.square") }
                .help("Import recipes from text (a blog post, Sony's site, a PDF you own)")
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }

    // MARK: Group chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(id: "All", label: "All", symbol: "square.grid.2x2", count: Set(store.allLooks.map(\.id)).count)
                ForEach(store.lookSections) { sec in
                    chip(id: sec.id, label: sec.chip, symbol: sec.symbol, count: sec.looks.count)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private func chip(id: String, label: String, symbol: String, count: Int) -> some View {
        let on = store.lookFilter == id
        return Button { store.lookFilter = id } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(label)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(on ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Grid

    private var grid: some View {
        let sections = store.visibleLookSections
        let aspect = asset.thumbnail.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
        return ScrollView {
            if sections.isEmpty {
                ContentUnavailableView.search(text: store.lookSearch).padding(.top, 60)
            }
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { sec in
                    let open = !collapsed.contains(sec.id) || !store.lookSearch.isEmpty
                    Section {
                        if open {
                            // Same visual size for landscape and portrait photos: width follows the photo's shape.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize * sqrt(aspect / 1.5) * 1.15), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                                ForEach(sec.looks) { r in
                                    LookTile(asset: asset, recipe: r, aspect: aspect)
                                        .onTapGesture { store.lookFocus = r }
                                        .contextMenu { menu(r) }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    } header: {
                        sectionHeader(sec, open: open)
                    }
                }
                Text("Sony's Creative Look processing is proprietary; these are Apixa's renderings, learned from Sony's own output where available.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }

    private func sectionHeader(_ sec: LookSection, open: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.bold()).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
            Image(systemName: sec.symbol).foregroundStyle(.secondary)
            Text(sec.title).font(.headline)
            Text("\(sec.looks.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Text(sec.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .help(sec.blurb)
            Spacer(minLength: 8)
            if sec.isMine {
                Menu {
                    Button("Rename Group…") { newGroupName = sec.id; renaming = sec.id }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { toggleCollapsed(sec.id) } }
    }

    @ViewBuilder private func menu(_ r: LookRecipe) -> some View {
        Button("Apply to Photo") { store.applyLook(r, to: [asset]) }
        Button("Apply to Selected Groups") { store.applyLook(r, to: store.selectedGroupAssets) }
        Button("Save JPEG…") { store.saveLookJPEG(asset, r) }
        Divider()
        Button(store.favoriteLooks.contains(r.id) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(r) }
        if !LookRecipe.builtIn.contains(r) {
            Menu("Move to Group") {
                ForEach(store.myLookGroups.filter { $0 != r.group }, id: \.self) { g in
                    Button(g) { store.moveMyLook(r, to: g) }
                }
            }
            Divider()
            Button("Delete Look", role: .destructive) { store.deleteMyLook(r) }
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
    var aspect: Double = 1.5
    var compact = false
    @ViewState private var image: NSImage?
    @ViewState private var hovering = false

    private struct Key: Hashable { let id: UUID; let recipe: LookRecipe; let adj: Adjustments; let raw: Bool }

    /// What kind of look this is, as a short badge: the Creative Look code, PP or Apple.
    private var badge: String { recipe.isProfile ? "PP" : recipe.appleFilter != nil ? "Apple" : recipe.base.rawValue }

    var body: some View {
        let applied = asset.adjustments.look == recipe
        let fav = store.favoriteLooks.contains(recipe.id)
        VStack(alignment: .leading, spacing: compact ? 3 : 7) {
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.06))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if let t = asset.thumbnail {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).opacity(0.35)
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .topLeading) {
                if !compact {
                    Text(badge).font(.caption2.weight(.semibold).monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !compact && (fav || hovering) {
                    Button { store.toggleFavorite(recipe) } label: {
                        Image(systemName: fav ? "star.fill" : "star")
                            .foregroundStyle(fav ? Color.yellow : Color.white)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).padding(6)
                    .help(fav ? "Remove from Favorites" : "Add to Favorites")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !compact && hovering && !applied {
                    Button { store.applyLook(recipe, to: [asset]) } label: { Label("Apply", systemImage: "checkmark") }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                        .padding(8)
                        .help("Apply this look to the photo")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if applied && !compact {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 10)
                .strokeBorder(applied ? Color.accentColor : (hovering ? Color.primary.opacity(0.25) : Color.clear), lineWidth: applied ? 2.5 : 1))
            if compact {
                Text(recipe.displayName).font(.caption2).lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    // Sony's own looks carry their code in the badge; show just the name.
                    Text(recipe.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(recipe.notes ?? recipe.settingsLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(recipe.credit.map { "\(recipe.settingsLine)\n\($0)" } ?? recipe.settingsLine)
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
                HStack(spacing: 10) {
                    Button { store.lookFocus = nil } label: { Label("All Looks", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                    Text(r.name).font(.headline)
                    Text(LookSection(id: preset.group, looks: []).chip)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Button { store.toggleFavorite(preset) } label: {
                        Image(systemName: store.favoriteLooks.contains(preset.id) ? "star.fill" : "star")
                            .foregroundStyle(store.favoriteLooks.contains(preset.id) ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(store.favoriteLooks.contains(preset.id) ? "Remove from Favorites" : "Add to Favorites")
                    Spacer()
                    if asset.adjustments.look == preset {
                        Label("Applied", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LookSection(id: preset.group, looks: []).title.uppercased())
                            .font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        Text(r.name).font(.title3.bold())
                        if let n = r.notes { Text(n).font(.callout).foregroundStyle(.secondary) }
                        if let c = r.credit { Text(c).font(.caption).foregroundStyle(.tertiary) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("In camera").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(r.settingsLine).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
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

/// The current group's looks as small thumbnails under the enlarged photo; click to switch (or use ← →).
struct LookStrip: View {
    @Environment(LibraryStore.self) private var store
    let asset: PhotoAsset
    let current: LookRecipe

    var body: some View {
        let looks = store.stripLooks(for: current)
        let aspect = asset.thumbnail.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LookSection(id: current.group, looks: []).chip).font(.caption.weight(.semibold))
                Text("\((looks.firstIndex { $0.id == current.id } ?? 0) + 1) of \(looks.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)
            .padding(.leading, 12)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(looks) { r in
                            LookTile(asset: asset, recipe: r, aspect: aspect, compact: true)
                                .frame(width: 74 * min(1.6, max(0.7, aspect)))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(r.id == current.id ? Color.accentColor : Color.clear, lineWidth: 2.5)
                                    .padding(.bottom, 16))
                                .id(r.id)
                                .onTapGesture { store.lookFocus = r }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
                .onChange(of: current.id) { withAnimation { proxy.scrollTo(current.id, anchor: .center) } }
            }
        }
        .frame(height: 104)
        .help("← → previous / next look in this group · ↑ ↓ previous / next photo")
    }
}
