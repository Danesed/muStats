# Releasing μStats

A release is a signed, notarized `muStats.dmg` on GitHub Releases, an `appcast.xml`
beside it for Sparkle, and a cask in the `Danesed/homebrew-tap` repository.

## One-time setup

1. **Developer ID certificate.** Xcode > Settings > Accounts > Manage Certificates > `+` >
   Developer ID Application.
2. **Notarization profile.** Create an App Store Connect API key (Users and Access >
   Integrations), save the `.p8` in `~/private_keys/`, then:

   ```sh
   xcrun notarytool store-credentials muStats \
     --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer uuid>
   ```

3. **Sparkle key.** Run `swift build` once so SwiftPM fetches Sparkle, then:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/private_keys/mustats_sparkle_ed25519.key
   ```

   Put the public key it prints into `Resources/Info.plist` as `SUPublicEDKey`, and set
   `SUEnableAutomaticChecks` to true if you want weekly checks. Back the private key up:
   lose it and no installed copy will accept another update.
4. **Repositories.** `Danesed/muStats` for the app, and `Danesed/homebrew-tap` for the
   cask (Homebrew finds `danesed/tap` by that exact name). Clone the tap beside this
   checkout as `../homebrew-tap`.

## Each release

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`, a whole number that only
   grows) in `Resources/Info.plist` and in `Resources/Widgets/Info.plist`.
2. Write the notes under `## <version>` in `CHANGELOG.md`.
3. Run `Scripts/release.sh`. It builds, signs every nested binary, notarizes and staples
   the app and the dmg, signs the dmg for Sparkle, and adds the release to
   `appcast.xml`. It refuses to start if the changelog has no notes for the version.
4. Follow the steps it prints:

   ```sh
   git add appcast.xml && git commit -m "release: 0.1.0" && git push
   git tag v0.1.0 && git push origin v0.1.0
   gh release create v0.1.0 dist/muStats.dmg appcast.xml --title "μStats 0.1.0" \
     --notes-file dist/notes-0.1.0.md
   Scripts/cask.sh ../homebrew-tap   # then commit and push the tap
   ```

**Why this order.** Installed copies read `releases/latest/download/appcast.xml`, so the
feed goes live the moment the release is published. Uploading the dmg and the appcast in
the same `gh release create` means the feed never points at a file that is not there.
The cask comes last because its checksum is of that exact uploaded file.

**Why the dmg is always called `muStats.dmg`.** The README links
`releases/latest/download/muStats.dmg`, which only resolves to an asset of exactly that
name. The version lives in the tag.

## The official Homebrew cask

`brew install --cask mustats`, without the tap, needs the app in `Homebrew/homebrew-cask`.
That repository accepts apps that are notable enough, roughly 75 stars or 30 forks or
watchers on GitHub. Until then the tap is the way in. Once accepted, Homebrew's
autobump bot opens the version bump PRs itself.
