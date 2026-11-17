import Foundation
import ImageIO
import SwiftUI

/// Lightroom / Capture One–style XMP sidecars (`DSC0001.xmp` next to `DSC0001.ARW`).
///
/// - Image files are never touched; only the `.xmp` text file is created or updated.
/// - An existing `NAME.xmp` is merged (other tools' data is kept) and backed up to Apixa's library first.
/// - darktable's own `NAME.ARW.xmp` files are a different name and are never touched.
enum Sidecar {
    struct Options: Sendable {
        var includeAutoRatings = false
        var includeLabels = true
        var includeLocation = true
        var includePeople = true
    }

    struct Entry: Sendable {
        let file: URL
        let patch: MetadataWriter.Patch
    }

    static func url(for raw: URL) -> URL { raw.deletingPathExtension().appendingPathExtension("xmp") }
}

extension LibraryStore {
    var sidecarBackupDir: URL? {
        guard let folder else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return LibraryDB(folder: folder).dir.appendingPathComponent("xmp-backups/\(stamp)", isDirectory: true)
    }

    func sidecarEntries(_ targets: [PhotoAsset], _ o: Sidecar.Options) -> [Sidecar.Entry] {
        targets.flatMap { a -> [Sidecar.Entry] in
            var p = MetadataWriter.Patch()
            if let r = a.userRating ?? (o.includeAutoRatings && a.analyzed ? a.stars : nil) { p.rating = .some(r) }
            if o.includeLabels, a.decision != .undecided { p.label = .some(a.decision == .keep ? "Green" : "Red") }
            if o.includeLocation, let g = a.location { p.gps = .set(g) }
            let people = Array(Set(a.faceNames.values)).sorted()
            if o.includePeople, !people.isEmpty { p.people = people }
            if p.isEmpty { return [] }
            return a.allURLs.map { Sidecar.Entry(file: $0, patch: p) }
        }
    }

    func writeSidecars(_ entries: [Sidecar.Entry]) {
        guard let backup = sidecarBackupDir else { return }
        statusMessage = "Writing metadata to \(entries.count) file(s)…"
        let affected = assets.filter { a in entries.contains { a.allURLs.contains($0.file) } }
        Task {
            let result = await Blocking.run { () -> (Int, Int) in
                var ok = 0, failed = 0
                for e in entries {
                    do { try MetadataWriter.write(e.patch, to: e.file, sidecarBackupDir: backup); ok += 1 } catch { failed += 1 }
                }
                return (ok, failed)
            }
            for a in affected { refreshCacheSignature(a) }
            statusMessage = "Metadata written to \(result.0) file(s)" + (result.1 > 0 ? ", \(result.1) failed" : "")
        }
    }
}

struct SidecarSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var scope: SaveScope = .groups
    @ViewState private var opts = Sidecar.Options()

    var body: some View {
        let targets: [PhotoAsset] = scope == .allKept ? store.assets : store.shots(in: scope)
        let entries = store.sidecarEntries(targets, opts)
        let rawCount = entries.filter { MetadataWriter.usesSidecar($0.file) }.count
        VStack(alignment: .leading, spacing: 0) {
            Text("Write Metadata to Files").font(.title2.bold()).padding([.horizontal, .top], 20)
            Text("Puts ratings, labels, location and people into your files so Lightroom, Capture One, Bridge and Photos see them. JPEG/HEIC: metadata is replaced in place and the image data is copied unchanged. RAW: written to a DSC0001.xmp sidecar, since RAW files can't be safely edited.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 4)
            Form {
                Picker("Shots", selection: $scope) {
                    Text("This photo").tag(SaveScope.photo)
                    Text("Selected groups (\(store.selectedGroupAssets.count))").tag(SaveScope.groups)
                    Text("All shots (\(store.assets.count))").tag(SaveScope.allKept)
                }
                Toggle("Star ratings you set", isOn: .constant(true)).disabled(true)
                Toggle("Also automatic ratings", isOn: $opts.includeAutoRatings)
                Toggle("Keep → Green label, Reject → Red label", isOn: $opts.includeLabels)
                Toggle("Locations you set", isOn: $opts.includeLocation)
                Toggle("People names (as keywords)", isOn: $opts.includePeople)
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(entries.count - rawCount) image file(s) updated in place, \(rawCount) RAW sidecar(s)")
                    .font(.callout.bold())
                Text("Existing sidecars are merged, keeping other apps' data (e.g. darktable), and a copy is saved in Apixa's library first. Edits are not included; use Save Copy for those.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Write to \(entries.count) File\(entries.count == 1 ? "" : "s")") {
                    store.writeSidecars(entries)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 540)
    }
}
