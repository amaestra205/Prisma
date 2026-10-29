#!/bin/bash
# Compila "Prisma.app" (universal: Apple Silicon + Intel) en build/.
# Uso: scripts/build-app.sh [versión]      Requiere Xcode 26 o sus Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"
OUT="build"
APP="$OUT/Prisma.app"
MIN_MACOS="26.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

for ARCH in arm64 x86_64; do
  echo "== Compilando $ARCH"
  xcrun swiftc -swift-version 5 -parse-as-library -O \
    -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDK" \
    -module-name Prisma Sources/*.swift -o "$OUT/obj/Prisma-$ARCH"
done
lipo -create "$OUT/obj/Prisma-arm64" "$OUT/obj/Prisma-x86_64" -output "$APP/Contents/MacOS/Prisma"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
fi

# Firma ad-hoc (sin cuenta de desarrollador de Apple).
codesign --force --deep --sign - "$APP"
echo "== OK: $APP"
