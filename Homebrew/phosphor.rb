cask "phosphor" do
  version "1.4.0"
  sha256 "dc9e832b31c45ea34e4fbbe54ff8815653fed515d382c0fd44598dfa80dbdb16"

  url "https://github.com/momenbasel/Phosphor/releases/download/v#{version}/Phosphor.dmg"
  name "Phosphor"
  desc "Free and open-source iOS device manager for macOS"
  homepage "https://github.com/momenbasel/Phosphor"

  depends_on macos: :sonoma
  depends_on formula: "libimobiledevice"

  app "Phosphor.app"

  zap trash: [
    "~/Library/Caches/com.phosphor.app",
    "~/Library/Preferences/com.phosphor.app.plist",
  ]
end
