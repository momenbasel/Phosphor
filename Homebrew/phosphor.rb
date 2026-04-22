cask "phosphor" do
  version "1.0.4"
  sha256 "de4a45cbc4be65772b24b25aec8eb98d65a5949a89a156d043324a1ba8810270"

  url "https://github.com/momenbasel/Phosphor/releases/download/v#{version}/Phosphor.dmg"
  name "Phosphor"
  desc "Free and open-source iOS device manager for macOS"
  homepage "https://github.com/momenbasel/Phosphor"

  depends_on macos: ">= :sonoma"
  depends_on formula: "libimobiledevice"

  app "Phosphor.app"

  zap trash: [
    "~/Library/Caches/com.phosphor.app",
    "~/Library/Preferences/com.phosphor.app.plist",
  ]
end
