cask "phosphor" do
  version "1.0.0"
  sha256 "edfdfb481eeb15846026cc66104329ac039db5736371de32801a02dbf29ea42c"

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
