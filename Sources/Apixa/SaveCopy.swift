import SwiftUI
import AppKit

enum SaveScope: String, CaseIterable, Identifiable {
    case photo = "This photo"
    case groups = "Selected groups"
    case keptInGroups = "Kept shots in selected groups"
    case allKept = "All kept shots"
    var id: String { rawValue }
}

enum SaveSize: Int, CaseIterable, Identifiable {
    case full = 0, px4096 = 4096, px2048 = 2048, px1024 = 1024
    var id: Int { rawValue }
    var label: String { self == .full ? "Full size" : "\(rawValue) px" }
}

extension LibraryStore {
    func shots(in scope: SaveScope) -> [PhotoAsset] {
        switch scope {
        case .photo: return selectedAsset.map { [$0] } ?? []
        case .groups: return selectedGroupAssets
        case .keptInGroups: return selectedGroupAssets.filter { $0.decision == .keep }
        case .allKept: return assets.filter { $0.decision == .keep }
        }
    }

    /// Writes new files only. `destination` nil = next to each original.
    func saveCopies(_ targets: [PhotoAsset], options: Develop.SaveOptions, preferRaw: Bool, destination: URL?) {
        let jobs = targets.map { a in
            (raw: a.rawURL, jpeg: a.jpegURL, useRaw: a.isRawOnly || (a.isPair && preferRaw),
             adj: a.adjustments, loc: a.location, rating: a.userRating, base: a.baseName, folder: destination ?? a.folder)
        }
        statusMessage = "Saving \(jobs.count) cop\(jobs.count == 1 ? "y" : "ies")…"
        Task {
            var done = 0, failed = 0
            var last: URL?
            for j in jobs {
                let dest = Self.uniqueURL(folder: j.folder, base: j.base + "-apixa", ext: options.format.ext)
                do {
                    try await Develop.saveCopy(raw: j.raw, jpeg: j.jpeg, useRaw: j.useRaw, adjustments: j.adj,
                                               location: j.loc, rating: j.rating, options: options, to: dest)
                    done += 1
                    last = dest
                } catch {
                    failed += 1
                }
                statusMessage = "Saving copies… \(done + failed)/\(jobs.count)"
            }
            statusMessage = "Saved \(done) cop\(done == 1 ? "y" : "ies")" + (failed > 0 ? " — \(failed) failed" : "")
            if let last { NSWorkspace.shared.activateFileViewerSelecting([last]) }
        }
    }

    /// `name.ext`, or `name-2.ext`, `name-3.ext`… — never an existing file.
    nonisolated static func uniqueURL(folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

struct SaveCopySheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @ViewState private var scope: SaveScope = .photo
    @ViewState private var format: Develop.Format = .jpeg
    @ViewState private var quality = 0.92
    @ViewState private var size: SaveSize = .full
    @ViewState private var includeLocation = true
    @ViewState private var preferRaw = true
    @ViewState private var nextToOriginals = true

    var body: some View {
        let targets = store.shots(in: scope)
        VStack(alignment: .leading, spacing: 0) {
            Text("Save a Copy").font(.title2.bold()).padding([.horizontal, .top], 20)
            Text("Writes a new file with your edits, location and rating. Your original is left as it is.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 4)
            Form {
                Picker("Shots", selection: $scope) {
                    ForEach(SaveScope.allCases) { s in Text("\(s.rawValue) (\(store.shots(in: s).count))").tag(s) }
                }
                Picker("Format", selection: $format) {
                    ForEach(Develop.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if format != .tiff {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.5...1)
                            Text("\(Int(quality * 100))").monospacedDigit().frame(width: 30)
                        }
                    }
                }
                Picker("Size", selection: $size) {
                    ForEach(SaveSize.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Use RAW when a RAW file is available", isOn: $preferRaw)
                Toggle("Include location", isOn: $includeLocation)
                Picker("Save to", selection: $nextToOriginals) {
                    Text("Next to the originals (name-apixa.\(format.ext))").tag(true)
                    Text("A folder I choose…").tag(false)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save \(targets.count) Cop\(targets.count == 1 ? "y" : "ies")") { save(targets) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear {
            preferRaw = store.previewRaw || store.selectedAsset?.isRawOnly == true
            if store.selectedStackIDs.count > 1 { scope = .groups }
        }
    }

    private func save(_ targets: [PhotoAsset]) {
        var dest: URL?
        if !nextToOriginals {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.prompt = "Save Here"
            p.message = "Choose where to save \(targets.count) cop\(targets.count == 1 ? "y" : "ies")"
            p.directoryURL = store.folder
            guard p.runModal() == .OK, let u = p.url else { return }
            dest = u
        }
        let opts = Develop.SaveOptions(format: format, quality: quality,
                                       maxPixel: size == .full ? nil : size.rawValue, includeLocation: includeLocation)
        store.saveCopies(targets, options: opts, preferRaw: preferRaw, destination: dest)
        dismiss()
    }
}
