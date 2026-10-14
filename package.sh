#!/bin/zsh
# Builds ready-to-install packages of Scribblio for Apple silicon and Intel:
#   dist/Scribblio.dmg   a disk image: open it and drag Scribblio into Applications
#   dist/Scribblio.pkg   an installer: double-click, Continue, Install, done
#
#   zsh package.sh
#
# With a paid Apple Developer ID the packages can be signed and notarized, so they open
# with no warning at all. Set these before running:
#   SCRIBBLIO_SIGN="Developer ID Application: Your Name (TEAMID)"
#   SCRIBBLIO_INSTALLER_SIGN="Developer ID Installer: Your Name (TEAMID)"
#   SCRIBBLIO_NOTARY_PROFILE="profile-name"   # from: xcrun notarytool store-credentials
set -e
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP=build/Scribblio.app
STAGE=build/package
mkdir -p dist
rm -rf $STAGE dist/Scribblio.dmg dist/Scribblio.pkg

# hardened runtime is required for notarization, so a real signature turns it on
if [[ -n "$SCRIBBLIO_SIGN" ]]; then
  SCRIBBLIO_SIGN="$SCRIBBLIO_SIGN" zsh build.sh universal
  codesign --force --options runtime --timestamp --sign "$SCRIBBLIO_SIGN" $APP
else
  zsh build.sh universal
fi

# Disk image: the app next to a shortcut to Applications, with the app icon on the volume.
mkdir -p $STAGE/dmg
cp -R $APP $STAGE/dmg/
ln -s /Applications $STAGE/dmg/Applications
cp Resources/AppIcon.icns $STAGE/dmg/.VolumeIcon.icns
SetFile -a C $STAGE/dmg 2>/dev/null || true
hdiutil create -quiet -volname "Scribblio" -srcfolder $STAGE/dmg -fs HFS+ -format UDZO -ov dist/Scribblio.dmg
[[ -n "$SCRIBBLIO_SIGN" ]] && codesign --force --timestamp --sign "$SCRIBBLIO_SIGN" dist/Scribblio.dmg

# Installer: always into /Applications, even if an older copy lives somewhere else.
mkdir -p $STAGE/root/Applications $STAGE/scripts
cp -R $APP $STAGE/root/Applications/
# The installer runs as root, so the app it puts down belongs to root and Finder asks for a password
# to trash it. Hand it to the person who installed it, like an app dragged in from the disk image.
cat > $STAGE/scripts/postinstall <<'POSTINSTALL'
#!/bin/sh
app="${3%/}/Applications/Scribblio.app"
user=$(stat -f%Su /dev/console)
if [ -n "$user" ] && [ "$user" != "root" ] && [ -d "$app" ]; then
  chown -R "$user":staff "$app"
fi
exit 0
POSTINSTALL
chmod +x $STAGE/scripts/postinstall
pkgbuild --analyze --root $STAGE/root $STAGE/components.plist >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" $STAGE/components.plist
pkgbuild --quiet --root $STAGE/root --component-plist $STAGE/components.plist --scripts $STAGE/scripts \
  --identifier com.fadywaheed.scribblio.pkg --version "$VERSION" --install-location / $STAGE/Scribblio-component.pkg
cat > $STAGE/distribution.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Scribblio</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
    <domains enable_localSystem="true"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="Scribblio"><pkg-ref id="com.fadywaheed.scribblio.pkg"/></choice>
    <pkg-ref id="com.fadywaheed.scribblio.pkg" version="$VERSION" onConclusion="none">Scribblio-component.pkg</pkg-ref>
</installer-gui-script>
EOF
if [[ -n "$SCRIBBLIO_INSTALLER_SIGN" ]]; then
  productbuild --quiet --distribution $STAGE/distribution.xml --package-path $STAGE --sign "$SCRIBBLIO_INSTALLER_SIGN" dist/Scribblio.pkg
else
  productbuild --quiet --distribution $STAGE/distribution.xml --package-path $STAGE dist/Scribblio.pkg
fi

# Notarization: Apple checks the packages so Gatekeeper opens them without a warning.
if [[ -n "$SCRIBBLIO_NOTARY_PROFILE" ]]; then
  for f in dist/Scribblio.dmg dist/Scribblio.pkg; do
    xcrun notarytool submit $f --keychain-profile "$SCRIBBLIO_NOTARY_PROFILE" --wait
    xcrun stapler staple $f
  done
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$STAGE/dmg/Scribblio.app" 2>/dev/null || true
rm -rf $STAGE
ls -lh dist/Scribblio.dmg dist/Scribblio.pkg
