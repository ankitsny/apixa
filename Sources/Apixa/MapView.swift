import SwiftUI
import MapKit

/// Where your shots were taken, as a heatmap. Clusters adapt to the zoom level; click one to see its shots.
struct MapHeatView: View {
    @Environment(LibraryStore.self) private var store
    @ViewState private var position: MapCameraPosition = .automatic
    @ViewState private var span: Double = 1

    private struct Cluster: Identifiable {
        let id: String
        let center: CLLocationCoordinate2D
        let ids: [UUID]
        let place: String?
    }

    private var located: [(PhotoAsset, GeoPoint)] {
        store.assets.compactMap { a in a.effectiveLocation.map { (a, $0) } }
    }

    /// Grid-bucketed clusters; cell size follows the visible map span.
    private var clusters: [Cluster] {
        let cell = max(0.0005, span / 22)
        var buckets: [String: [(PhotoAsset, GeoPoint)]] = [:]
        for (a, g) in located {
            let k = "\(Int((g.latitude / cell).rounded(.down))),\(Int((g.longitude / cell).rounded(.down)))"
            buckets[k, default: []].append((a, g))
        }
        return buckets.map { k, v in
            let lat = v.map(\.1.latitude).reduce(0, +) / Double(v.count)
            let lon = v.map(\.1.longitude).reduce(0, +) / Double(v.count)
            return Cluster(id: k, center: CLLocationCoordinate2D(latitude: lat, longitude: lon), ids: v.map(\.0.id),
                           place: v.compactMap(\.1.placeName).first)
        }
    }

    var body: some View {
        let cs = clusters
        let maxCount = Double(cs.map(\.ids.count).max() ?? 1)
        let cellMeters = max(40, span / 22 * 111_000)
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(cs) { c in
                    let t = Double(c.ids.count) / maxCount
                    MapCircle(center: c.center, radius: cellMeters * (0.45 + 0.55 * sqrt(t)))
                        .foregroundStyle(heat(t).opacity(0.45))
                    Annotation(c.place ?? "", coordinate: c.center) {
                        Button { store.showShots(c.ids) } label: {
                            Text("\(c.ids.count)")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(heat(t)))
                                .overlay(Capsule().stroke(.white, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Show these \(c.ids.count) shots")
                    }
                }
            }
            .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                span = max(ctx.region.span.latitudeDelta, ctx.region.span.longitudeDelta)
            }

            HStack(spacing: 12) {
                Text("\(located.count) of \(store.assets.count) shots have a location")
                if located.count < store.assets.count {
                    Button("Set Locations…") { store.showGeotag = true }
                        .disabled(store.selectedAsset == nil)
                }
                HStack(spacing: 4) {
                    Text("fewer").font(.caption2)
                    LinearGradient(colors: [heat(0), heat(0.5), heat(1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 70, height: 6).clipShape(Capsule())
                    Text("more").font(.caption2)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(12)

            if located.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No locations yet").font(.headline)
                    Text("Set a location on some shots (⌘L) and they'll show up here.").foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Blue → yellow → red.
    private func heat(_ t: Double) -> Color {
        let t = min(1, max(0, t))
        return t < 0.5 ? Color(red: t * 2, green: 0.55 + t * 0.5, blue: 1 - t * 2)
                       : Color(red: 1, green: 0.8 - (t - 0.5) * 1.4, blue: 0)
    }
}

extension LibraryStore {
    /// From the map: show only these shots in the sidebar, back in Photo mode.
    func showShots(_ ids: [UUID]) {
        locationFilter = Set(ids)
        mainMode = .photo
        sidebarSelectionChanged()
        if let first = visibleStacks.first { selectGroup(first.id) }
    }
}
