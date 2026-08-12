import Foundation

/// Display names for Apple system apps, whose names are not in Manifest.plist
/// (only App Store apps get a CFBundleDisplayName entry there).
enum AppleAppNames {
    static let names: [String: String] = [
        "com.apple.AppStore": "App Store",
        "com.apple.Bridge": "Watch",
        "com.apple.Camera": "Camera",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Health": "Health",
        "com.apple.Home": "Home",
        "com.apple.Maps": "Maps",
        "com.apple.Measure": "Measure",
        "com.apple.MobileSMS": "Messages",
        "com.apple.Music": "Music",
        "com.apple.Notes": "Notes",
        "com.apple.Passbook": "Wallet",
        "com.apple.Photos": "Photos",
        "com.apple.Podcasts": "Podcasts",
        "com.apple.Preferences": "Settings",
        "com.apple.Reminders": "Reminders",
        "com.apple.Safari": "Safari",
        "com.apple.Shortcuts": "Shortcuts",
        "com.apple.Stocks": "Stocks",
        "com.apple.TV": "TV",
        "com.apple.Translate": "Translate",
        "com.apple.VoiceMemos": "Voice Memos",
        "com.apple.Weather": "Weather",
        "com.apple.calculator": "Calculator",
        "com.apple.camera": "Camera",
        "com.apple.clock": "Clock",
        "com.apple.compass": "Compass",
        "com.apple.findmy": "Find My",
        "com.apple.freeform": "Freeform",
        "com.apple.iBooks": "Books",
        "com.apple.mobilecal": "Calendar",
        "com.apple.mobilemail": "Mail",
        "com.apple.mobilenotes": "Notes",
        "com.apple.mobilephone": "Phone",
        "com.apple.mobilesafari": "Safari",
        "com.apple.news": "News",
        "com.apple.tips": "Tips",
        "com.apple.weather": "Weather",
        "com.apple.mobiletimer": "Clock",
        "com.apple.mobileslideshow": "Photos",
        "com.apple.reminders": "Reminders",
        "com.apple.stocks": "Stocks",
        "com.apple.Batteries": "Batteries",
        "com.apple.MobileAddressBook": "Contacts",
        "com.apple.DocumentsApp": "Files",
        "com.apple.Fitness": "Fitness",
        "com.apple.Magnifier": "Magnifier",
        "com.apple.MobileStore": "iTunes Store",
        "com.apple.PhotoBooth": "Photo Booth",
        "com.apple.calculator.watch": "Calculator",
        "com.apple.facetime": "FaceTime",
        "com.apple.gamecenter": "Game Center",
        "com.apple.journal": "Journal",
        "com.apple.measure": "Measure",
        "com.apple.mobilegarageband": "GarageBand",
        "com.apple.mobileme.fmf1": "Find Friends",
        "com.apple.podcasts": "Podcasts",
        "com.apple.shortcuts": "Shortcuts",
        "com.apple.clips": "Clips",
        "com.apple.iMovie": "iMovie",
        "com.apple.Home.HomeUI": "Home",
    ]

    /// Human name for any bundle id: Apple map, else prettify the last
    /// component ("com.spotify.client" -> "client" is useless; use the segment
    /// before it when generic, else the last distinctive segment).
    static func displayName(for bundleID: String, fallback: String?) -> String {
        if let mapped = names[bundleID] { return mapped }
        if let fallback, !fallback.isEmpty { return fallback }
        let parts = bundleID.split(separator: ".").map(String.init)
        // TLD-ish and boilerplate segments carry no meaning wherever they
        // appear ("Resident.Fetch.com" must yield "Fetch", not "com").
        let generic: Set<String> = [
            "client", "app", "apps", "ios", "iphone", "mobile", "shared",
            "com", "net", "org", "io", "co", "us", "il", "ph", "ai", "prod", "release",
        ]
        for part in parts.reversed() where !generic.contains(part.lowercased()) {
            // Prettify camelCase / lowercase single words: capitalize first letter.
            return part.prefix(1).uppercased() + part.dropFirst()
        }
        return parts.last ?? bundleID
    }
}
