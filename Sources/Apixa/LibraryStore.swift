import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryStore {
    var folder: URL? = nil
    var assets: [PhotoAsset] = []
    var stacks: [PhotoStack] = []

    /// Sidebar selection (multi-select for bulk actions); `selectedStackID` is the group shown in the detail.
    var selectedStackIDs: Set<UUID> = []
    var selectedStackID: UUID? = nil
    var selectedAssetID: UUID? = nil

    // Settings (remembered between launches)
    var maxGap: Double = LibraryStore.pref("maxGap", 15) { didSet { if Self.persistSettings { UserDefaults.standard.set(maxGap, forKey: "maxGap") } } }
    var looseness: Double = LibraryStore.pref("looseness", 0.45) { didSet { if Self.persistSettings { UserDefaults.standard.set(looseness, forKey: "looseness") } } }
    var trashMode = TrashMode(rawValue: UserDefaults.standard.string(forKey: "trashMode") ?? "") ?? .both {
        didSet { if Self.persistSettings { UserDefaults.standard.set(trashMode.rawValue, forKey: "trashMode") } }
    }
    /// Compute sharpness/exposure from a RAW 9 render (slower; stacking still uses the fast preview).
    var accurateRaw = UserDefaults.standard.bool(forKey: "accurateRaw") {
        didSet { if Self.persistSettings { UserDefaults.standard.set(accurateRaw, forKey: "accurateRaw") } }
    }
    // Writing into the original files (metadata only).
    var writeLocationToFiles = UserDefaults.standard.object(forKey: "writeLocationToFiles") as? Bool ?? true {
        didSet { if Self.persistSettings { UserDefaults.standard.set(writeLocationToFiles, forKey: "writeLocationToFiles") } }
    }
    var writeRatingToFiles = UserDefaults.standard.object(forKey: "writeRatingToFiles") as? Bool ?? true {
        didSet { if Self.persistSettings { UserDefaults.standard.set(writeRatingToFiles, forKey: "writeRatingToFiles") } }
    }
    var writeLabelToFiles = UserDefaults.standard.bool(forKey: "writeLabelToFiles") {
        didSet { if Self.persistSettings { UserDefaults.standard.set(writeLabelToFiles, forKey: "writeLabelToFiles") } }
    }
    var pendingFileWrites = 0

    /// Preview pane shows the RAW 9 render instead of the JPEG for RAW+JPEG pairs.
    var previewRaw = false

    var showAutoPickConfirm = false
    var showGeotag = false
    var showSaveCopy = false
    var showSidecars = false
    var cropMode = false
    var mainMode = MainMode.photo
    var lookFocus: LookRecipe? = nil
    var myLooks: [LookRecipe] = MyLooksStore.load()
    var locationFilter: Set<UUID>? = nil
    var compareMode = CompareMode.off
    var showClipping = false
    var showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { if Self.persistSettings { UserDefaults.standard.set(showInspector, forKey: "showInspector") } }
    }
    var showStrip = UserDefaults.standard.object(forKey: "showStrip") as? Bool ?? true {
        didSet { if Self.persistSettings { UserDefaults.standard.set(showStrip, forKey: "showStrip") } }
    }
    var viewerMargin = ViewerMargin(rawValue: UserDefaults.standard.string(forKey: "viewerMargin") ?? "") ?? .small {
        didSet { if Self.persistSettings { UserDefaults.standard.set(viewerMargin.rawValue, forKey: "viewerMargin") } }
    }
    var viewerBackground = ViewerBackground(rawValue: UserDefaults.standard.string(forKey: "viewerBackground") ?? "") ?? .auto {
        didSet { if Self.persistSettings { UserDefaults.standard.set(viewerBackground.rawValue, forKey: "viewerBackground") } }
    }
    var zoom = ZoomState()
    var searchText = ""
    var isIndexingFaces = false
    /// True while a text field has focus — single-key shortcuts are disabled then.
    var isEditingText = false
    var inspectorTab = InspectorTab.rate
    var isFullScreen = false
    var scopes: Scopes? = nil

    var isScanning = false
    var progress = 0
    var total = 0
    var statusMessage: String? = nil

    @ObservationIgnored private var db: LibraryDB?
    @ObservationIgnored private var cache: [String: CachedAnalysis] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Self-test runs never change the user's saved preferences.
    static let persistSettings = !CommandLine.arguments.contains {
        ["--selftest", "--developtest", "--statetest", "--trashtest", "--metatest", "--perftest", "--stackdump", "--facedump", "--looktest", "--importlooks", "--darktest", "--nrtest", "--lookcompare", "--uidemo", "--measuretest", "--scopetest", "--autoundo", "--autotest", "--auditdump", "--sonyfit", "--refexport", "--refcompare", "--lookfit", "--camfit", "--handcheck", "--matchtest", "--basecheck"].contains($0)
    }

    private static func pref(_ key: String, _ def: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? def
    }

    // MARK: Derived

    var visibleStacks: [PhotoStack] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        var out = stacks
        if let f = locationFilter { out = out.filter { $0.members.contains { f.contains($0.id) } } }
        if !q.isEmpty { out = out.filter { $0.members.contains { matches($0, q) } } }
        return out
    }

    var selectedStack: PhotoStack? {
        visibleStacks.first { $0.id == selectedStackID }
    }

    var selectedAsset: PhotoAsset? {
        guard let s = selectedStack else { return nil }
        return s.members.first { $0.id == selectedAssetID } ?? s.cover
    }

    /// Shots in every selected sidebar group (falls back to the shown group).
    var selectedGroupAssets: [PhotoAsset] {
        let ids = selectedStackIDs.isEmpty ? Set([selectedStackID].compactMap { $0 }) : selectedStackIDs
        return stacks.filter { ids.contains($0.id) }.flatMap(\.members)
    }

    var keepCount: Int { assets.filter { $0.decision == .keep }.count }
    var rejectCount: Int { assets.filter { $0.decision == .reject }.count }
    var rejectFileCount: Int {
        assets.filter { $0.decision == .reject }.reduce(0) { $0 + filesToTrash($1).count }
    }

    func selectGroup(_ id: UUID?) {
        if cropMode { endCrop(apply: true) }
        selectedStackID = id
        selectedStackIDs = Set([id].compactMap { $0 })
        selectedAssetID = nil
    }

    func selectAsset(_ id: UUID) {
        if cropMode { endCrop(apply: true) }
        selectedAssetID = id
    }

    /// Called when the sidebar selection changes.
    func sidebarSelectionChanged() {
        let visible = Set(visibleStacks.map(\.id))
        selectedStackIDs = selectedStackIDs.filter(visible.contains)
        if let cur = selectedStackID, selectedStackIDs.contains(cur) { return }
        if selectedStackIDs.isEmpty, let cur = selectedStackID, visible.contains(cur) { return }
        if cropMode { endCrop(apply: true) }
        selectedStackID = (visibleStacks.first { selectedStackIDs.contains($0.id) } ?? visibleStacks.first)?.id
        if selectedStackIDs.isEmpty, let id = selectedStackID { selectedStackIDs = [id] }
        selectedAssetID = nil
    }

    // MARK: Loading

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Open"
        p.message = "Choose the folder you copied from your SD card"
        if p.runModal() == .OK, let url = p.url { load(url) }
    }

    func load(_ url: URL) {
        guard !isScanning else { return }
        flushSave()
        folder = url
        undoStack = []
        redoStack = []
        assets = []
        stacks = []
        selectGroup(nil)
        statusMessage = nil
        isScanning = true
        progress = 0
        total = 0
        let db = LibraryDB(folder: url)
        self.db = db

        Task {
            let (found, state, cache) = await Task.detached(priority: .userInitiated) {
                (FolderScanner.scan(url), db.loadState(), db.loadAnalysis())
            }.value
            self.cache = cache
            self.assets = found.map { PhotoAsset(item: $0) }
            for a in self.assets {
                if let s = state[db.key(folder: a.folder, baseName: a.baseName)] { a.userState = s }
            }
            let analyzed = await self.analyzeAll(force: false)
            await self.restackAsync()
            self.isScanning = false
            Task { await self.indexFaces() }
            let multi = self.stacks.filter { $0.members.count > 1 }.count
            self.statusMessage = "\(self.assets.count) shots, \(multi) stacks"
                + (analyzed < self.assets.count ? " · \(self.assets.count - analyzed) from cache" : "")
        }
    }

    /// Analyzes shots that have no valid cached result. `force` re-analyzes everything. Keeps marks.
    func reanalyze(force: Bool) {
        guard !isScanning, !assets.isEmpty else { return }
        isScanning = true
        progress = 0
        statusMessage = nil
        Task {
            let n = await self.analyzeAll(force: force)
            await self.restackAsync()
            self.isScanning = false
            Task { await self.indexFaces() }
            self.statusMessage = n == 0 ? "Everything already analyzed" : "Analyzed \(n) shot(s)"
        }
    }

    /// Returns how many shots were actually analyzed (not served from cache).
    @discardableResult
    private func analyzeAll(force: Bool) async -> Int {
        guard let db else { return 0 }
        let raw = accurateRaw
        // Work out cache hits off the main actor (stat-ing files on an SD card is slow).
        let probes = assets.map { (id: $0.id, key: db.key(folder: $0.folder, baseName: $0.baseName),
                                   urls: $0.allURLs, hasRaw: $0.rawURL != nil) }
        let cache = self.cache
        let plan = await Blocking.run { () -> [(UUID, String, [String: FileSignature], CachedAnalysis?)] in
            probes.map { p in
                let sig = LibraryDB.signature(p.urls)
                var hit: CachedAnalysis?
                if !force, let c = cache[p.key], c.signature == sig, !(raw && p.hasRaw && c.source != .raw) { hit = c }
                return (p.id, p.key, sig, hit)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var jobs: [AnalysisJob] = []
        var sigs: [UUID: (String, [String: FileSignature])] = [:]
        var upgrades: [(UUID, String, URL, Bool, [CGRect])] = []
        for (id, key, sig, hit) in plan {
            guard let a = byID[id] else { continue }
            if let hit {
                a.apply(hit.result)
                a.facePrints = (hit.facePrints ?? []).map(FaceIndex.unarchive)
                if !hit.faces.isEmpty && hit.faceSharpness == nil {
                    upgrades.append((id, key, a.displayURL, a.isRawOnly, hit.faces.map(\.rect)))
                }
            } else {
                jobs.append(AnalysisJob(id: id, displayURL: a.displayURL, rawURL: a.rawURL,
                                        isRawOnly: a.isRawOnly, accurateRaw: raw))
                sigs[id] = (key, sig)
            }
        }
        // Analyses cached before face sharpness existed: add it from the preview (fast, no RAW decode).
        if !upgrades.isEmpty {
            let done = await withTaskGroup(of: (UUID, String, Double?).self) { g -> [(UUID, String, Double?)] in
                for (id, key, url, isRaw, rects) in upgrades {
                    g.addTask { await Blocking.run { (id, key, Analyzer.faceSharpness(displayURL: url, isRaw: isRaw, faces: rects)) } }
                }
                var out: [(UUID, String, Double?)] = []
                for await r in g { out.append(r) }
                return out
            }
            for (id, key, v) in done {
                byID[id]?.faceSharpness = v ?? -1
                self.cache[key]?.faceSharpness = v ?? -1   // -1 = tried, no usable face
            }
            saveCache()
        }
        total = jobs.count
        progress = 0
        guard !jobs.isEmpty else { return 0 }
        restack()

        // RAW renders share the GPU; more parallelism than this just queues on it.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // The RAW decoder runs one decode at a time system-wide; 2 keeps it busy without piling up memory.
        let limit = raw ? 2 : max(2, cores - 1)

        await withTaskGroup(of: (UUID, AnalysisResult).self) { group in
            var it = jobs.makeIterator()
            for _ in 0..<limit {
                if let x = it.next() { group.addTask { (x.id, await Analyzer.analyze(x)) } }
            }
            while let (id, res) = await group.next() {
                byID[id]?.apply(res)
                if let (key, sig) = sigs[id] { self.cache[key] = CachedAnalysis(res, signature: sig) }
                progress += 1
                if progress % 30 == 0 { restack() }
                if progress % 200 == 0 { saveCache() }
                if let x = it.next() { group.addTask { (x.id, await Analyzer.analyze(x)) } }
            }
        }
        saveCache()
        return jobs.count
    }

    /// Builds face prints (for naming suggestions) for shots with faces, in the background. Cached.
    func indexFaces() async {
        guard let db, !isIndexingFaces else { return }
        let todo = assets.filter { !$0.faces.isEmpty && $0.facePrints.count != $0.faces.count }
        guard !todo.isEmpty else { return }
        isIndexingFaces = true
        defer { isIndexingFaces = false }
        for chunk in stride(from: 0, to: todo.count, by: 8).map({ Array(todo[$0..<min($0 + 8, todo.count)]) }) {
            let jobs = chunk.map { (id: $0.id, url: $0.displayURL, raw: $0.isRawOnly, faces: $0.faces,
                                    key: db.key(folder: $0.folder, baseName: $0.baseName)) }
            let results = await withTaskGroup(of: (UUID, String, [Data?]).self) { g in
                for j in jobs { g.addTask { (j.id, j.key, await Blocking.run { FaceIndex.prints(url: j.url, isRaw: j.raw, faces: j.faces) }) } }
                var out: [(UUID, String, [Data?])] = []
                for await r in g { out.append(r) }
                return out
            }
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            for (id, key, prints) in results {
                byID[id]?.facePrints = prints.map(FaceIndex.unarchive)
                cache[key]?.facePrints = prints.map { $0 ?? Data() }
            }
        }
        saveCache()
    }

    private func saveCache() {
        guard let db else { return }
        let entries = cache
        Task.detached(priority: .utility) { db.saveAnalysis(entries) }
    }

    // MARK: Saving user state (debounced)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.flushSave()
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let db, !assets.isEmpty || !undoStack.isEmpty else { return }
        var shots = db.loadState()   // keep entries for shots that are trashed/missing right now
        for a in assets { shots[db.key(folder: a.folder, baseName: a.baseName)] = a.userState }
        shots = shots.filter { !$0.value.isDefault }
        db.saveState(shots)
    }

    // MARK: Stacking

    private var stackGeneration = 0

    /// Fire-and-forget re-stack (slider drags, rating changes).
    func restack() {
        Task { await restackAsync() }
    }

    /// Groups + scores on a background queue from a snapshot; results superseded by a newer restack
    /// (e.g. while a slider is being dragged) are dropped.
    func restackAsync() async {
        stackGeneration += 1
        let gen = stackGeneration
        let pool = assets.filter(\.analyzed)
        let inputs = pool.map(StackInput.init)
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        let gap = maxGap, dist = Float(looseness)

        let out = await Blocking.run { Stacker.build(inputs, maxGap: gap, maxDistance: dist) }
        guard gen == stackGeneration else { return }

        for (id, sc) in out.scores {
            guard let a = byID[id] else { continue }
            a.sharpnessScore = sc.sharpnessScore
            a.score = sc.score
            a.stars = sc.stars
            a.isBest = sc.isBest
            a.ratingDetail = sc.detail
        }
        let live = Set(assets.map(\.id))   // drop shots trashed while this restack ran
        stacks = out.groups.compactMap { ids in
            let members = ids.filter(live.contains).compactMap { byID[$0] }
            return members.isEmpty ? nil : PhotoStack(members: members)
        }
        // Stack IDs follow their first member; keep the selection pointing at the same shots.
        let ids = Set(stacks.map(\.id))
        selectedStackIDs = selectedStackIDs.filter(ids.contains)
        if selectedStack == nil {
            let target = selectedAssetID.flatMap { aid in stacks.first { $0.members.contains { $0.id == aid } } }
            selectedStackID = (target ?? visibleStacks.first)?.id
            if selectedStackIDs.isEmpty, let id = selectedStackID { selectedStackIDs = [id] }
        }
    }

    // MARK: Navigation

    func movePhoto(_ delta: Int) {
        guard let s = selectedStack, let cur = selectedAsset,
              let i = s.members.firstIndex(where: { $0.id == cur.id }) else { return }
        let j = i + delta
        if s.members.indices.contains(j) {
            if cropMode { endCrop(apply: true) }
            selectedAssetID = s.members[j].id
        } else if !isFullScreen {
            moveStack(delta > 0 ? 1 : -1, selectLast: delta < 0)
        }
    }

    func moveStack(_ delta: Int, selectLast: Bool = false) {
        let vs = visibleStacks
        guard !vs.isEmpty else { return }
        let i = vs.firstIndex { $0.id == selectedStackID } ?? 0
        let j = min(max(i + delta, 0), vs.count - 1)
        guard j != i || selectedStackID == nil else { return }
        selectGroup(vs[j].id)
        selectedAssetID = selectLast ? vs[j].members.last?.id : vs[j].cover.id
    }

    // MARK: Culling & rating (every change goes through `change` so it can be undone)

    func mark(_ d: Decision) {
        guard let a = selectedAsset else { return }
        setDecision(a, d)
        if d != .undecided { movePhoto(1) }
    }

    func setDecision(_ a: PhotoAsset, _ d: Decision) {
        change([a], name: d == .keep ? "Keep" : d == .reject ? "Reject" : "Clear Mark") { $0.decision = d }
    }

    func toggleDecision(_ a: PhotoAsset, _ d: Decision) {
        setDecision(a, a.decision == d ? .undecided : d)
    }

    /// 1...5 sets your rating; nil (or the same value again) returns to the automatic rating.
    func setRating(_ a: PhotoAsset, _ r: Int?) {
        let v = (r == a.userRating) ? nil : r
        change([a], name: v == nil ? "Clear Rating" : "Rate \(v!)★") { $0.userRating = v }
        restack()   // your rating decides the best shot in its stack
    }

    func rateSelected(_ r: Int?) {
        guard let a = selectedAsset else { return }
        let v = r.map { min(5, max(1, $0)) }
        change([a], name: v == nil ? "Clear Rating" : "Rate \(v!)★") { $0.userRating = v }
        restack()
    }

    /// Unmarked shots in the stack: best → keep, others → reject. Shots already marked are left alone.
    private func keepBestShots(_ s: PhotoStack) -> [(PhotoAsset, Decision)] {
        guard s.members.count > 1 else { return [] }
        let bestID = s.cover.id
        return s.members.filter { $0.decision == .undecided }.map { ($0, $0.id == bestID ? .keep : .reject) }
    }

    private func applyDecisions(_ list: [(PhotoAsset, Decision)], name: String) {
        let map = Dictionary(uniqueKeysWithValues: list.map { (ObjectIdentifier($0.0), $0.1) })
        change(list.map(\.0), name: name) { a in if let d = map[ObjectIdentifier(a)] { a.decision = d } }
    }

    func keepBest(in s: PhotoStack) {
        applyDecisions(keepBestShots(s), name: "Keep Best in Stack")
    }

    func keepBestInSelectedStack() {
        if let s = selectedStack { keepBest(in: s) }
    }

    /// What "Keep best in all stacks" would do — shown in the confirmation before applying.
    var autoPickPreview: (stacks: Int, keeps: Int, rejects: Int) {
        let per = stacks.map(keepBestShots).filter { !$0.isEmpty }
        let all = per.flatMap { $0 }
        return (per.count, all.filter { $0.1 == .keep }.count, all.filter { $0.1 == .reject }.count)
    }

    func autoPickAll() {
        applyDecisions(stacks.flatMap(keepBestShots), name: "Keep Best in All Stacks")
    }

    func clearAllMarks() {
        change(assets.filter { $0.decision != .undecided }, name: "Clear All Marks") { $0.decision = .undecided }
    }

    func togglePreviewRaw() {
        if selectedAsset?.isPair == true { previewRaw.toggle() }
    }

    // MARK: Location

    func setLocation(_ targets: [PhotoAsset], _ point: GeoPoint?) {
        change(targets, name: point == nil ? "Remove Location" : "Set Location") { $0.location = point }
        statusMessage = point == nil ? "Removed location from \(targets.count) shot(s)" : "Set location on \(targets.count) shot(s)"
    }

    // MARK: Edits

    /// Sliders edit `asset.adjustments` live; this records the finished gesture as one undo step.
    func commitAdjustments(_ a: PhotoAsset, from old: Adjustments, name: String) {
        guard old != a.adjustments else { return }
        var before = a.userState
        before.adjustments = old
        record(name: name, [UserChange(asset: a, old: before, new: a.userState)])
    }

    /// Auto on: Apple's auto-enhance replaces the tone and colour sliders (what they held is kept).
    /// Auto off: those sliders go back to what they held before.
    func toggleAuto(_ a: PhotoAsset, usesRaw: Bool) async {
        if a.adjustments.isAutoOn, let auto = a.adjustments.auto {
            change([a], name: "Turn Off Auto") { $0.adjustments.tone = auto.previous; $0.adjustments.auto = nil }
            return
        }
        let before = a.adjustments
        guard let out = await Develop.autoAdjust(raw: a.rawURL, jpeg: a.jpegURL, useRaw: usesRaw, current: before),
              a.adjustments == before else { return }
        change([a], name: "Auto Enhance") {
            $0.adjustments.auto = AutoEdit(applied: out.tone, previous: before.tone)
            $0.adjustments.tone = out.tone
        }
        if out.tone == ToneSet() { statusMessage = "Auto found nothing to improve on this photo" }
    }

    func resetAdjustments(_ a: PhotoAsset) {
        change([a], name: "Reset Edits") { $0.adjustments = Adjustments() }
    }

    func pasteAdjustments(_ adj: Adjustments, to targets: [PhotoAsset]) {
        change(targets, name: "Paste Edits") { $0.adjustments = adj }
    }

    @ObservationIgnored var copiedAdjustments: Adjustments?

    // MARK: Crop tool

    var cropAspect = CropAspect.free
    @ObservationIgnored private var cropTarget: (asset: PhotoAsset, start: Adjustments)?

    func beginCrop() {
        guard let a = selectedAsset, !cropMode else { return }
        cropTarget = (a, a.adjustments)
        zoom = ZoomState()
        inspectorTab = .adjust
        cropMode = true
    }

    /// Done applies (one undo step); Cancel restores the crop and angle from before.
    func endCrop(apply: Bool) {
        guard cropMode, let t = cropTarget else { cropMode = false; return }
        if apply {
            commitAdjustments(t.asset, from: t.start, name: "Crop")
        } else {
            t.asset.adjustments.crop = t.start.crop
            t.asset.adjustments.angle = t.start.angle
        }
        cropTarget = nil
        cropMode = false
    }

    // MARK: Undo / redo

    private struct UserChange { let asset: PhotoAsset; let old: UserState; let new: UserState }
    private struct TrashedFile { let asset: PhotoAsset; let isRaw: Bool; let original: URL; let trashed: URL }
    private enum Change {
        case user(name: String, [UserChange])
        case trash([TrashedFile])
        var name: String {
            switch self {
            case .user(let n, _): return n
            case .trash: return "Move to Trash"
            }
        }
    }
    private var undoStack: [Change] = []
    private var redoStack: [Change] = []

    var undoTitle: String? { undoStack.last?.name }
    var redoTitle: String? { redoStack.last?.name }

    func change(_ targets: [PhotoAsset], name: String, _ mutate: (PhotoAsset) -> Void) {
        var diff: [UserChange] = []
        for a in targets {
            let old = a.userState
            mutate(a)
            if a.userState != old { diff.append(UserChange(asset: a, old: old, new: a.userState)) }
        }
        record(name: name, diff)
    }

    private func record(name: String, _ diff: [UserChange]) {
        guard !diff.isEmpty else { return }
        undoStack.append(.user(name: name, diff))
        redoStack.removeAll()
        scheduleSave()
        syncFiles(diff.map(\.asset))
    }

    func undo() {
        guard let c = undoStack.popLast() else { return }
        switch c {
        case .user(_, let diff):
            for d in diff { d.asset.userState = keepingBaseline(d.old, of: d.asset) }
            redoStack.append(c)
            restack()
            syncFiles(diff.map(\.asset))
        case .trash(let files):
            redoStack.append(.trash(restoreFromTrash(files)))
        }
        scheduleSave()
    }

    func redo() {
        guard let c = redoStack.popLast() else { return }
        switch c {
        case .user(_, let diff):
            for d in diff { d.asset.userState = keepingBaseline(d.new, of: d.asset) }
            undoStack.append(c)
            restack()
            syncFiles(diff.map(\.asset))
        case .trash(let files):
            let moved = moveToTrash(files.map { ($0.asset, $0.isRaw, $0.original) })
            undoStack.append(.trash(moved.files))
            finishTrash(moved: moved.files.count, failed: moved.failed)
        }
        scheduleSave()
    }

    // MARK: Writing metadata into the original files

    /// Undo/redo restore user state but must never forget a file's recorded baseline.
    private func keepingBaseline(_ s: UserState, of a: PhotoAsset) -> UserState {
        var s = s
        s.fileBaseline = a.fileBaseline.merging(s.fileBaseline) { cur, _ in cur }
        return s
    }

    @ObservationIgnored private var syncQueue: [ObjectIdentifier: PhotoAsset] = [:]
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// Each file gets the current state (location, rating, label), falling back to what it held before
    /// Apixa first touched it — so undo puts the camera's original values back.
    func syncFiles(_ changed: [PhotoAsset]) {
        guard writeLocationToFiles || writeRatingToFiles || writeLabelToFiles, let folder else { return }
        for a in changed { syncQueue[ObjectIdentifier(a)] = a }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let batch = Array(syncQueue.values)
            syncQueue.removeAll()
            let backup = LibraryDB(folder: folder).dir.appendingPathComponent("xmp-backups/auto", isDirectory: true)
            let (loc, rat, lab) = (writeLocationToFiles, writeRatingToFiles, writeLabelToFiles)
            pendingFileWrites += batch.count
            var written = 0, failed = 0
            for a in batch {
                let files = a.allURLs
                let baseline = a.fileBaseline
                let state = (location: a.location, rating: a.userRating,
                             label: a.decision == .keep ? "Green" : a.decision == .reject ? "Red" : nil as String?)
                let result = await Blocking.run { () -> ([String: MetadataWriter.Previous], Int, Int) in
                    var newBase: [String: MetadataWriter.Previous] = [:]
                    var ok = 0, bad = 0
                    for u in files {
                        let name = u.lastPathComponent
                        let current = MetadataWriter.read(u)
                        let base = baseline[name] ?? current
                        if baseline[name] == nil { newBase[name] = current }
                        var patch = MetadataWriter.Patch()
                        if loc {
                            let want = state.location ?? base.gps
                            if want != current.gps { patch.gps = want.map { .set($0) } ?? .remove }
                        }
                        if rat {
                            let want = state.rating ?? base.rating
                            if want != current.rating { patch.rating = .some(want) }
                        }
                        if lab {
                            let want = state.label ?? base.label
                            if want != current.label { patch.label = .some(want) }
                        }
                        guard !patch.isEmpty else { continue }
                        do { try MetadataWriter.write(patch, to: u, sidecarBackupDir: backup); ok += 1 } catch { bad += 1 }
                    }
                    return (newBase, ok, bad)
                }
                if !result.0.isEmpty { a.fileBaseline.merge(result.0) { cur, _ in cur } }
                written += result.1
                failed += result.2
                refreshSignature(a)
            }
            pendingFileWrites -= batch.count
            scheduleSave()
            if written > 0 || failed > 0 {
                statusMessage = "Updated metadata in \(written) file(s)" + (failed > 0 ? " — \(failed) failed" : "")
            }
        }
    }

    /// A metadata write changes the file's modification date; keep its cached analysis valid.
    func refreshCacheSignature(_ a: PhotoAsset) { refreshSignature(a) }

    private func refreshSignature(_ a: PhotoAsset) {
        guard let db else { return }
        let key = db.key(folder: a.folder, baseName: a.baseName)
        cache[key]?.signature = LibraryDB.signature(a.allURLs)
        saveCache()
    }

    // MARK: Trash

    func filesToTrash(_ a: PhotoAsset) -> [URL] {
        switch trashMode {
        case .both: return a.allURLs
        case .jpegOnly: return [a.jpegURL].compactMap { $0 }
        case .rawOnly: return [a.rawURL].compactMap { $0 }
        }
    }

    func trashRejects() {
        var targets: [(PhotoAsset, Bool, URL)] = []
        for a in assets where a.decision == .reject {
            for u in filesToTrash(a) { targets.append((a, u == a.rawURL, u)) }
        }
        let moved = moveToTrash(targets)
        if !moved.files.isEmpty {
            undoStack.append(.trash(moved.files))
            redoStack.removeAll()
        }
        finishTrash(moved: moved.files.count, failed: moved.failed)
    }

    private func moveToTrash(_ targets: [(PhotoAsset, Bool, URL)]) -> (files: [TrashedFile], failed: Int) {
        let fm = FileManager.default
        var files: [TrashedFile] = []
        var failed = 0
        for (a, isRaw, u) in targets {
            var result: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &result)
                if let t = result as URL? { files.append(TrashedFile(asset: a, isRaw: isRaw, original: u, trashed: t)) }
                if isRaw { a.rawURL = nil } else { a.jpegURL = nil }
            } catch {
                failed += 1
            }
        }
        return (files, failed)
    }

    private func finishTrash(moved: Int, failed: Int) {
        assets.removeAll { $0.jpegURL == nil && $0.rawURL == nil }
        restack()
        statusMessage = "Moved \(moved) file(s) to Trash" + (failed > 0 ? " — \(failed) failed" : "") + (moved > 0 ? " · ⌘Z to put back" : "")
    }

    /// Moves trashed files back to where they were and re-adds their shots.
    private func restoreFromTrash(_ files: [TrashedFile]) -> [TrashedFile] {
        let fm = FileManager.default
        var restored: [TrashedFile] = []
        var failed = 0
        for f in files {
            do {
                try fm.moveItem(at: f.trashed, to: f.original)
                if f.isRaw { f.asset.rawURL = f.original } else { f.asset.jpegURL = f.original }
                if !assets.contains(where: { $0 === f.asset }) { assets.append(f.asset) }
                restored.append(f)
            } catch {
                failed += 1
            }
        }
        restack()
        statusMessage = "Put back \(restored.count) file(s)" + (failed > 0 ? " — \(failed) could not be restored" : "")
        return restored
    }
}
