cask "phosphor" do
  version "1.3.0"
  sha256 "bb7d4b80eda1f8afce550e7948e61879130298ffe68ce7f213f6d9e49227771c"

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
