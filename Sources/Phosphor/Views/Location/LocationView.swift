import SwiftUI
import MapKit

/// GPS location spoofing with interactive map, presets, and GPX route playback.
struct LocationView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @StateObject private var simulator = LocationSimulator()

    @State private var latitude = "40.7128"
    @State private var longitude = "-74.0060"
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var pinCoordinate = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    @State private var gpxWaypoints: [CLLocationCoordinate2D] = []
    @State private var gpxFileName: String?
    @State private var playbackSpeed: Double = 1.0
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if deviceVM.selectedDevice == nil {
                EmptyStateView(
                    icon: "location.fill",
                    title: "No Device Connected",
                    subtitle: "Connect a device to simulate GPS locations."
                )
            } else {
                HSplitView {
                    mapSection
                        .frame(minWidth: 400)
                    controlPanel
                        .frame(width: 280)
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Location")
                .font(.title2.weight(.semibold))

            if simulator.isPlayingRoute {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                    Text("Route Playing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.1))
                .clipShape(Capsule())
            }

            Spacer()

            if let msg = statusMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .padding(20)
    }

    // MARK: - Map

    private var mapSection: some View {
        Map(position: $cameraPosition) {
            Annotation("", coordinate: pinCoordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                    .shadow(radius: 3)
            }

            // Show GPX route if loaded
            if !gpxWaypoints.isEmpty {
                MapPolyline(coordinates: gpxWaypoints)
                    .stroke(.blue, lineWidth: 3)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .onTapGesture { location in
            // Map tap handling - convert screen point to coordinate
            // Note: SwiftUI Map doesn't expose tap-to-coordinate directly in macOS 14,
            // so we rely on the coordinate text fields for precise input.
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 8) {
                Text(String(format: "%.4f, %.4f", pinCoordinate.latitude, pinCoordinate.longitude))
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(8)
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coordinateSection
                actionButtons
                presetsSection
                gpxSection
            }
            .padding(16)
        }
        .background(.bar)
    }

    private var coordinateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coordinates")
                .font(.headline)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latitude").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("40.7128", text: $latitude)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: latitude) { updatePin() }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Longitude").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("-74.0060", text: $longitude)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: longitude) { updatePin() }
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                guard let udid = deviceVM.selectedDevice?.id,
                      let lat = Double(latitude), let lon = Double(longitude) else { return }
                Task {
                    let ok = await simulator.setLocation(udid: udid, latitude: lat, longitude: lon)
                    if ok {
                        statusMessage = "Location set"
                        try? await Task.sleep(for: .seconds(2))
                        statusMessage = nil
                    }
                }
            } label: {
                Label("Set Location", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(simulator.isApplying || !isValidCoordinate)

            Button {
                guard let udid = deviceVM.selectedDevice?.id else { return }
                Task {
                    let ok = await simulator.clearLocation(udid: udid)
                    if ok {
                        statusMessage = "Location reset"
                        try? await Task.sleep(for: .seconds(2))
                        statusMessage = nil
                    }
                }
            } label: {
                Label("Reset to Real", systemImage: "location.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let error = simulator.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presetsSection: some View {
        DisclosureGroup("Presets") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(LocationSimulator.presets, id: \.name) { preset in
                    Button {
                        latitude = String(preset.lat)
                        longitude = String(preset.lon)
                        updatePin()
                        moveCameraTo(lat: preset.lat, lon: preset.lon)
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .font(.headline)
    }

    private var gpxSection: some View {
        DisclosureGroup("GPX Route") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.xml]
                    panel.allowsOtherFileTypes = true
                    panel.title = "Select GPX File"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    gpxWaypoints = simulator.parseGPX(url: url)
                    gpxFileName = url.lastPathComponent
                    if let first = gpxWaypoints.first {
                        moveCameraTo(lat: first.latitude, lon: first.longitude)
                    }
                } label: {
                    Label("Import GPX", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let name = gpxFileName {
                    HStack {
                        Image(systemName: "map")
                            .foregroundStyle(.blue)
                        Text("\(name) (\(gpxWaypoints.count) points)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Speed")
                            .font(.system(size: 11))
                        Picker("", selection: $playbackSpeed) {
                            Text("1x").tag(1.0)
                            Text("2x").tag(2.0)
                            Text("5x").tag(5.0)
                            Text("10x").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if simulator.isPlayingRoute {
                        if let progress = simulator.routeProgress {
                            ProgressView(value: Double(progress.current), total: Double(progress.total))
                            Text("\(progress.current)/\(progress.total)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            simulator.stopPlayback()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button {
                            guard let udid = deviceVM.selectedDevice?.id else { return }
                            simulator.playRoute(udid: udid, waypoints: gpxWaypoints, speed: playbackSpeed)
                        } label: {
                            Label("Play Route", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(gpxWaypoints.isEmpty)
                    }
                }
            }
        }
        .font(.headline)
    }

    // MARK: - Helpers

    private var isValidCoordinate: Bool {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return false }
        return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }

    private func updatePin() {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
        pinCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func moveCameraTo(lat: Double, lon: Double) {
        withAnimation(.easeInOut(duration: 0.5)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            )
        }
        pinCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
