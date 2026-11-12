#!/bin/bash
# Signs, notarizes and packages μStats as a .dmg users can download and open.
#
# Scripts/build.sh signs ad-hoc, which proves only that the bundle is intact. macOS
# refuses an ad-hoc bundle that arrived over the internet outright ("μStats is
# damaged"), so distribution needs a real Developer ID signature, Apple's notarization
# ticket, and that ticket stapled onto the file so it validates with no network.
#
#   Scripts/release.sh          → .dmg in dist/
#   Scripts/release.sh --adhoc  → the same without a Developer ID: signed ad hoc, not
#                                 notarized. Gatekeeper blocks it on first open until
#                                 the user allows it (the Homebrew cask does that for
#                                 them). Sparkle still verifies updates with its own key.
#
# Requires a Developer ID Application certificate in the keychain and a notarytool
# credential profile. Both are one-time setup; see the preflight errors below.
set -euo pipefail

ADHOC=0
if [ "${1:-}" = "--adhoc" ]; then ADHOC=1; fi

cd "$(dirname "$0")/.."
ROOT="$PWD"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-muStats}"
DIST="dist"

# Sparkle ships generate_keys and sign_update alongside the framework SwiftPM fetched,
# so a checkout that can build can also sign an update. SPARKLE_BIN overrides it for a
# copy unpacked from the tarball.
SPARKLE_BIN="${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}"

# The same key `generate_keys -x` wrote, read from the file rather than from the login
# keychain. sign_update reads the keychain by default and macOS answers that with a
# dialog no script can click, which stalls the release halfway through notarization.
SPARKLE_KEY="${SPARKLE_KEY:-$HOME/private_keys/mustats_sparkle_ed25519.key}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"

# Deliberately unversioned. The README links
# releases/latest/download/muStats.dmg, which resolves only against an asset of
# exactly that name, so putting the version in the filename breaks the one URL that
# never has to be updated. The version lives in the git tag and in the bundle.
DMG="$DIST/muStats.dmg"

# The notes go into the appcast at the very end, after minutes of notarization, so a
# version CHANGELOG.md has no entry for is refused here instead.
uv run Scripts/appcast.py --version "$VERSION" --check

if [ "$ADHOC" = 0 ]; then
  if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "error: no '$IDENTITY' certificate in the keychain." >&2
    echo "  Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application" >&2
    exit 1
  fi

  if ! NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1)"; then
    # A profile that exists can still be refused. Apple answers 403 when a developer
    # agreement is waiting to be accepted, and that is not fixed by storing credentials,
    # so anything other than a missing profile is shown as Apple worded it.
    if ! grep -q "No Keychain password item found" <<<"$NOTARY_CHECK"; then
      echo "error: notarytool cannot reach Apple with the '$PROFILE' profile:" >&2
      sed 's/^/  /' <<<"$NOTARY_CHECK" >&2
      exit 1
    fi
    # The App Store Connect key is a file on disk, so the command below can name the real
    # one rather than a placeholder to be worked out under pressure. The issuer cannot be
    # recovered from anything local: it is the UUID on App Store Connect > Users and
    # Access > Integrations > App Store Connect API.
    KEY_FILE="$(ls "$HOME"/private_keys/AuthKey_*.p8 2>/dev/null | head -n 1)"
    if [ -n "$KEY_FILE" ]; then
      KEY_ID="$(basename "$KEY_FILE" .p8)"
      KEY_ID="${KEY_ID#AuthKey_}"
    else
      KEY_FILE="~/private_keys/AuthKey_XXXXXXXXXX.p8"
      KEY_ID="XXXXXXXXXX"
    fi
    echo "error: no notarytool credential profile named '$PROFILE'." >&2
    echo "  Store it once, then run this script again:" >&2
    echo "    xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "      --key $KEY_FILE \\" >&2
    echo "      --key-id $KEY_ID \\" >&2
    echo "      --issuer <uuid from App Store Connect > Integrations > App Store Connect API>" >&2
    exit 1
  fi
fi

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "error: no sign_update in '$SPARKLE_BIN'." >&2
  echo "  Run swift build once to fetch Sparkle, or set SPARKLE_BIN to the bin/" >&2
  echo "  directory of an unpacked Sparkle-<version>.tar.xz." >&2
  exit 1
fi

if [ ! -f "$SPARKLE_KEY" ]; then
  echo "error: no Sparkle private key at '$SPARKLE_KEY'." >&2
  echo "  It is the file $SPARKLE_BIN/generate_keys -x wrote. Without it no copy" >&2
  echo "  of μStats in the field will accept this build as an update." >&2
  exit 1
fi

# Both architectures in one app, so a single download runs on Apple silicon and on
# the Intel Macs that macOS 14 and 15 still support.
APP="$(Scripts/build.sh release --arch arm64 --arch x86_64 | tail -n 1)"

# Extended attributes picked up from the filesystem (quarantine flags, Finder info)
# make codesign fail with a bare "resource fork, Finder information, or similar
# detritus not allowed" that names no file.
xattr -cr "$APP"

mkdir -p "$DIST"
rm -f "$DMG"

if [ "$ADHOC" = 0 ]; then
  # Sparkle's framework holds two XPC services, the Autoupdate tool and Updater.app, and
  # notarization checks every one of them, so each is signed before the thing containing
  # it. Innermost first: signing a container records the hashes of what it holds.
  #
  # --deep is deliberately not used on any of it, which is Sparkle's own instruction. The
  # Downloader service carries an entitlement that belongs to it alone, and a deep
  # signature would overwrite it with this app's.
  FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$FRAMEWORK"

  # The widget extension, with its sandbox entitlement, before the app that seals it.
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Widgets/Widgets.entitlements \
    --sign "$IDENTITY" "$APP/Contents/PlugIns/MuStatsWidgets.appex"

  # --options runtime is the hardened runtime, which notarization refuses to accept
  # without. --timestamp pins the signature to a trusted clock so it stays valid after
  # the certificate itself expires.
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"

  codesign --verify --strict --deep "$APP"

  # Notarize the app itself before packaging so the ticket can be stapled into the
  # bundle. Stapling only the .dmg leaves the copy the user drags to /Applications
  # without a ticket, and its first launch then needs a working network to verify.
  ZIP="$DIST/muStats-app.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# A .dmg opens as a window holding the app next to a shortcut to /Applications, so
# installing is one drag. `hdiutil create -srcfolder` makes that image but records no
# window settings, so Finder opens it as a plain list of two names and nothing tells
# the user to drag. dmgbuild writes the layout in Scripts/dmg.py into the image's
# .DS_Store itself, rather than by scripting Finder, so this needs no Automation grant
# and no window on screen. Icon positions there line up with the arrow drawn by
# Scripts/dmg-background.py.
#
# On macOS 27 hdiutil warns that the flags dmgbuild passes it are deprecated, once per
# call. The image is unaffected, so those lines are dropped and anything else dmgbuild
# writes to stderr still shows.
uv run --with dmgbuild dmgbuild \
  -s "$ROOT/Scripts/dmg.py" \
  -D app="$APP" \
  -D root="$ROOT" \
  "μStats" "$DMG" 2> >(grep -v "^hdiutil: WARNING: .* is deprecated" >&2) >/dev/null

if [ "$ADHOC" = 0 ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"

  # What Gatekeeper will decide on the user's machine. Anything but "accepted" here is
  # what they would see instead of the app opening.
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  # build.sh signed everything ad hoc; this only proves the seal is intact.
  codesign --verify --strict --deep "$APP"
fi

# A second copy under the version, because the unversioned name is about to be
# overwritten by the next run and a dmg is minutes of notarization to reproduce.
cp "$DMG" "$DIST/muStats-$VERSION.dmg"

# Sparkle installs a dmg only if its EdDSA signature matches the SUPublicEDKey in the
# copy already running, so this is what makes the file installable rather than merely
# downloadable.
SIGNATURE="$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY" "$DMG")"

# appcast.xml at the repo root by default. APPCAST points it somewhere else, which is how
# a dry run stays out of the tracked file.
uv run Scripts/appcast.py \
  --version "$VERSION" --build "$BUILD" --dmg "$DMG" --signature "$SIGNATURE" \
  --notes-out "$DIST/notes-$VERSION.md" ${APPCAST:+--appcast "$APPCAST"}

SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"

echo
echo "$DMG (version $VERSION, build $BUILD)"
echo "  sha256 $SHA"
echo "  $SIGNATURE"
echo
echo "Next, in this order (docs/RELEASING.md has the reasons):"
echo "  1. git add appcast.xml && git commit -m \"release: $VERSION\" && git push"
echo "  2. git tag v$VERSION && git push origin v$VERSION"
echo "  3. gh release create v$VERSION $DMG appcast.xml --title \"μStats $VERSION\" --notes-file $DIST/notes-$VERSION.md"
echo "     Both assets in one call: the appcast goes live with the file it points at."
echo "  4. Scripts/cask.sh ../homebrew-tap, then commit and push the tap."
