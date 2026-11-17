import SwiftUI
import MapKit

enum ShotScope: String, CaseIterable, Identifiable {
    case photo = "This photo"
    case groups = "Selected groups"
    case day = "Same day"
    case all = "All shots"
    var id: String { rawValue }
}

extension LibraryStore {
    func shots(in scope: ShotScope) -> [PhotoAsset] {
        switch scope {
        case .photo: return selectedAsset.map { [$0] } ?? []
        case .groups: return selectedGroupAssets
        case .day:
            guard let d = selectedAsset?.captureDate else { return [] }
            return assets.filter { Calendar.current.isDate($0.captureDate, inSameDayAs: d) }
        case .all: return assets
        }
    }

    /// Fills in a readable place name for a point (best effort, in the background).
    func resolvePlaceName(for point: GeoPoint, on targets: [PhotoAsset]) {
        Task {
            guard let req = MKReverseGeocodingRequest(location: CLLocation(latitude: point.latitude, longitude: point.longitude)),
                  let item = try? await req.mapItems.first else { return }
            let name = item.address?.shortAddress ?? item.name
            for a in targets where a.location?.latitude == point.latitude && a.location?.longitude == point.longitude {
                a.location?.placeName = name
            }
            flushSave()
        }
    }
}

/// Live place suggestions while typing.
@MainActor
@Observable
final class PlaceCompleter: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { results = []; completer.cancel() } else { completer.queryFragment = t }
    }

    func clear() { results = []; completer.cancel() }

    // MapKit calls the delegate on the main thread.
    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        results = Array(c.results.prefix(8))
    }

    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// Resolves a suggestion to coordinates.
    func resolve(_ c: MKLocalSearchCompletion) async -> MKMapItem? {
        try? await MKLocalSearch(request: MKLocalSearch.Request(completion: c)).start().mapItems.first
    }
}

struct GeotagSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @ViewState private var pin: GeoPoint?
    @ViewState private var position: MapCameraPosition = .automatic
    @ViewState private var query = ""
    @ViewState private var completer = PlaceCompleter()
    @ViewState private var searching = false
    @ViewState private var scope: ShotScope = .groups
    @ViewState private var skipExisting = false

    var body: some View {
        let targets = store.shots(in: scope).filter { !skipExisting || $0.effectiveLocation == nil }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for a place, or click the map", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { completer.update(query) }
                    .onSubmit { if let first = completer.results.first { pick(first) } }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(10)

            ZStack(alignment: .topLeading) {
                MapReader { proxy in
                    Map(position: $position) {
                        ForEach(existingPoints, id: \.self) { p in
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                                Circle().fill(Color.blue.opacity(0.7)).frame(width: 7, height: 7)
                            }
                        }
                        if let pin {
                            Marker(pin.placeName ?? "New location",
                                   coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude))
                        }
                    }
                    .mapControls { MapZoomStepper(); MapCompass() }
                    .onTapGesture { pt in
                        if let c = proxy.convert(pt, from: .local) {
                            pin = GeoPoint(latitude: c.latitude, longitude: c.longitude)
                            completer.clear()
                        }
                    }
                }
                if !completer.results.isEmpty {
                    List(completer.results, id: \.self) { item in
                        Button { pick(item) } label: {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 340, height: min(300, CGFloat(completer.results.count) * 44 + 10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 6)
                    .padding(10)
                }
            }

            Divider()
            HStack(alignment: .center, spacing: 14) {
                Picker("Apply to", selection: $scope) {
                    ForEach(ShotScope.allCases) { s in
                        Text("\(s.rawValue) (\(store.shots(in: s).count))").tag(s)
                    }
                }
                .frame(width: 260)
                Toggle("Only shots without a location", isOn: $skipExisting)
                Spacer()
                Button("Remove Location") {
                    store.setLocation(targets, nil)
                    dismiss()
                }
                .disabled(targets.allSatisfy { $0.location == nil })
                .help("Removes locations you set in Apixa; files go back to the GPS they had before.")
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Location on \(targets.count) Shot\(targets.count == 1 ? "" : "s")") {
                    guard let pin else { return }
                    store.setLocation(targets, pin)
                    if pin.placeName == nil { store.resolvePlaceName(for: pin, on: targets) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pin == nil || targets.isEmpty)
            }
            .padding(12)
            Text(store.writeLocationToFiles
                 ? "Also written into the files: JPEG/HEIC metadata in place (image data untouched), RAW via .xmp sidecar. ⌘Z restores the previous location. Turn off in Settings."
                 : "Stored in Apixa and added to copies you save. Writing into the files is off in Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], 12)
        }
        .frame(minWidth: 820, minHeight: 600)
        .onAppear {
            if store.selectedStackIDs.count <= 1 { scope = (store.selectedStack?.members.count ?? 1) > 1 ? .groups : .photo }
            if let p = store.selectedAsset?.effectiveLocation {
                pin = p
                position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                                                      latitudinalMeters: 5000, longitudinalMeters: 5000))
            }
        }
    }

    /// Distinct locations already on shots in this folder (rounded to ~10 m).
    private var existingPoints: [GeoPoint] {
        var seen = Set<String>()
        var out: [GeoPoint] = []
        for a in store.assets {
            guard let p = a.effectiveLocation else { continue }
            let k = String(format: "%.4f,%.4f", p.latitude, p.longitude)
            if seen.insert(k).inserted { out.append(GeoPoint(latitude: p.latitude, longitude: p.longitude)) }
        }
        return out
    }

    /// Moves the map to a suggestion and drops the pin there.
    private func pick(_ c: MKLocalSearchCompletion) {
        searching = true
        completer.clear()
        Task {
            defer { searching = false }
            guard let item = await completer.resolve(c) else { return }
            let coord = item.location.coordinate
            pin = GeoPoint(latitude: coord.latitude, longitude: coord.longitude,
                           placeName: [c.title, c.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
            withAnimation(.easeInOut(duration: 0.6)) {
                position = .camera(MapCamera(centerCoordinate: coord, distance: 4000))
            }
        }
    }
}
