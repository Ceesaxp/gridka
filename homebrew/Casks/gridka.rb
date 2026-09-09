cask "gridka" do
  version "1.3.1"
  sha256 "4922ff164d1284a8e47b44c7fdbf981fd908e9fd9bbcb3afa99b5a7e858b8232"

  url "https://github.com/Ceesaxp/gridka/releases/download/v#{version}/Gridka-#{version}.dmg"
  name "Gridka"
  desc "Native macOS CSV viewer for very large files"
  homepage "https://github.com/Ceesaxp/gridka"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Gridka.app"

  zap trash: [
    "~/Library/Caches/com.gridka.app",
    "~/Library/Application Support/com.gridka.app",
    "~/Library/Preferences/org.ceesaxp.gridka.app.plist",
    "~/Library/Saved Application State/org.ceesaxp.gridka.app.savedState",
  ]
end
