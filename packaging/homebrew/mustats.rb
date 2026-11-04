# The cask for the Danesed/homebrew-tap repository. Scripts/cask.sh fills in the
# version and checksum of a release and writes the result into a tap checkout.
cask "mustats" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Danesed/muStats/releases/download/v#{version}/muStats.dmg"
  name "μStats"
  desc "Lightweight system monitor for the menu bar"
  homepage "https://github.com/Danesed/muStats"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "muStats.app"
  binary "#{appdir}/muStats.app/Contents/MacOS/muStats", target: "mustats"

  uninstall quit: "com.danesed.muStats"

  zap trash: [
    "~/Library/Application Support/muStats",
    "~/Library/Caches/com.danesed.muStats",
    "~/Library/Containers/com.danesed.muStats.widgets",
    "~/Library/HTTPStorages/com.danesed.muStats",
    "~/Library/HTTPStorages/com.danesed.muStats.binarycookies",
    "~/Library/Preferences/com.danesed.muStats.plist",
  ]
end
