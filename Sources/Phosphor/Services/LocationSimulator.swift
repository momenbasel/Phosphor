import Foundation
import CoreLocation

/// Simulates GPS location on connected device via pymobiledevice3.
/// Supports single-point spoofing and GPX route playback.
@MainActor
final class LocationSimulator: ObservableObject {

    @Published var isApplying = false
    @Published var isPlayingRoute = false
    @Published var routeProgress: (current: Int, total: Int)?
    @Published var error: String?

    private var playbackTask: Task<Void, Never>?

    func setLocation(udid: String, latitude: Double, longitude: Double) async -> Bool {
        isApplying = true
        error = nil
        let result = await PyMobileDevice.simulateLocationSet(udid: udid, latitude: latitude, longitude: longitude)
        if !result.success {
            let stderr = result.stderr.lowercased()
            if stderr.contains("tunneld") || stderr.contains("start-tunnel") || stderr.contains("unable to connect") {
                error = "iOS 17+ requires tunnel service.\nRun: sudo pymobiledevice3 remote tunneld"
            } else if stderr.contains("developer mode") || stderr.contains("developermode") {
                error = "Enable Developer Mode on device:\nSettings > Privacy & Security > Developer Mode"
            } else {
                error = "Failed to set location.\n\(result.stderr.prefix(200))"
            }
        }
        isApplying = false
        return result.success
    }

    func clearLocation(udid: String) async -> Bool {
        isApplying = true
        error = nil
        let ok = await PyMobileDevice.simulateLocationClear(udid: udid)
        if !ok { error = "Failed to clear simulated location." }
        isApplying = false
        return ok
    }

    // MARK: - GPX Parsing

    /// Parse a GPX file into waypoints. Uses Foundation XMLParser, no external deps.
    func parseGPX(url: URL) -> [CLLocationCoordinate2D] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let parser = GPXParser(data: data)
        return parser.parse()
    }

    // MARK: - Route Playback

    func playRoute(udid: String, waypoints: [CLLocationCoordinate2D], speed: Double = 1.0) {
        guard !waypoints.isEmpty else { return }
        stopPlayback()
        isPlayingRoute = true
        routeProgress = (0, waypoints.count)

        playbackTask = Task {
            let delay = max(0.5, 2.0 / speed) // seconds between points

            for (index, point) in waypoints.enumerated() {
                if Task.isCancelled { break }
                routeProgress = (index + 1, waypoints.count)

                let result = await PyMobileDevice.simulateLocationSet(
                    udid: udid, latitude: point.latitude, longitude: point.longitude
                )
                if !result.success {
                    error = "Route playback failed at waypoint \(index + 1)."
                    break
                }

                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }

            isPlayingRoute = false
            routeProgress = nil
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlayingRoute = false
        routeProgress = nil
    }

    // MARK: - Presets

    static let presets: [(name: String, lat: Double, lon: Double)] = [
        ("New York", 40.7128, -74.0060),
        ("London", 51.5074, -0.1278),
        ("Tokyo", 35.6762, 139.6503),
        ("Paris", 48.8566, 2.3522),
        ("Sydney", -33.8688, 151.2093),
        ("Dubai", 25.2048, 55.2708),
        ("Cairo", 30.0444, 31.2357),
        ("Berlin", 52.5200, 13.4050),
        ("San Francisco", 37.7749, -122.4194),
        ("Singapore", 1.3521, 103.8198),
    ]

    deinit {
        playbackTask?.cancel()
    }
}

// MARK: - GPX XML Parser

private class GPXParser: NSObject, XMLParserDelegate {
    private let xmlParser: XMLParser
    private var waypoints: [CLLocationCoordinate2D] = []

    init(data: Data) {
        self.xmlParser = XMLParser(data: data)
        super.init()
        xmlParser.delegate = self
    }

    func parse() -> [CLLocationCoordinate2D] {
        xmlParser.parse()
        return waypoints
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        // GPX track points: <trkpt lat="..." lon="...">
        // Also support waypoints: <wpt lat="..." lon="...">
        // And route points: <rtept lat="..." lon="...">
        if elementName == "trkpt" || elementName == "wpt" || elementName == "rtept" {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                waypoints.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
    }
}
