#!/bin/zsh
# Builds Scribblio.app without Xcode; the Command Line Tools are enough (xcode-select --install).
#   ./build.sh            for this Mac (arm64 or x86_64)
#   ./build.sh universal  for Apple Silicon and Intel at once
set -e
cd "$(dirname "$0")"
APP=build/Scribblio.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
FLAGS=(-O -swift-version 5 -framework AppKit -framework QuartzCore -framework CoreText -framework Metal -framework MetalKit -framework Carbon)
if [[ "$1" == "universal" ]]; then
  swiftc $FLAGS -target arm64-apple-macos14.0 Sources/*.swift -o build/Scribblio-arm64
  swiftc $FLAGS -target x86_64-apple-macos14.0 Sources/*.swift -o build/Scribblio-x86_64
  lipo -create build/Scribblio-arm64 build/Scribblio-x86_64 -output $APP/Contents/MacOS/Scribblio
  rm build/Scribblio-arm64 build/Scribblio-x86_64
else
  swiftc $FLAGS -target $(uname -m)-apple-macos14.0 Sources/*.swift -o $APP/Contents/MacOS/Scribblio
fi
cp Info.plist $APP/Contents/Info.plist
cp Resources/AppIcon.icns Resources/paper.png $APP/Contents/Resources/
cp -R Localization/*.lproj $APP/Contents/Resources/
# Signing. SCRIBBLIO_SIGN picks the certificate, ad-hoc by default.
codesign --force --sign "${SCRIBBLIO_SIGN:--}" $APP
# keep this build copy out of Launchpad, Apps and "Open With": only the installed copy should show there
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
echo "built $APP"
