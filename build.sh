#!/bin/zsh
# Builds a universal "FreeHand a PDF.app" (Apple silicon and Intel) in ./build.
# Needs only the Xcode command line tools: libraries are downloaded and compiled here.
set -euo pipefail
cd "${0:A:h}"

MIN_MACOS="${MIN_MACOS:-12.0}"
ARCHS=(arm64 x86_64)
BUILD="$PWD/build"
OBJ="$BUILD/obj"
APP="$BUILD/FreeHand a PDF.app"
CACHE="${XDG_CACHE_HOME:-$HOME/Library/Caches}/Freehand-a-PDF"

for tool in curl patch shasum swiftc clang clang++ lipo codesign; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool (try: xcode-select --install)" >&2; exit 1; }
done

rm -rf "$BUILD"
mkdir -p "$OBJ" "$CACHE"

# fetch <url> <sha256> <folder>: downloads once, checks the file and unpacks it into build/
fetch() {
  local file="$CACHE/${1:t}"
  [[ -f "$file" ]] || curl -fsSL --retry 3 "$1" -o "$file"
  echo "$2  $file" | shasum -a 256 -c - >/dev/null || { rm -f "$file"; echo "Bad checksum: $1" >&2; exit 1; }
  tar -xf "$file" -C "$BUILD"
  print "$BUILD/$3"
}

echo "==> Downloading libraries"
FH=$(fetch https://dev-www.libreoffice.org/src/libfreehand/libfreehand-0.1.4.tar.xz \
  350b10d24a76d7e8c8ae98b74c2d432a2c8ddec08935d09856d20b695a35e600 libfreehand-0.1.4)
RV=$(fetch https://downloads.sourceforge.net/project/libwpd/librevenge/librevenge-0.0.6/librevenge-0.0.6.tar.xz \
  19eacf5ce55d7fe6a990a45142589cdf7da0c7b68701797f133482cb44f189fa librevenge-0.0.6)
CMS=$(fetch https://downloads.sourceforge.net/project/lcms/lcms/2.19.1/lcms2-2.19.1.tar.gz \
  bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8 lcms2-2.19.1)
patch -d "$FH" -p1 --quiet < patches/libfreehand-0.1.4.patch
patch -d "$RV" -p1 --quiet < patches/librevenge-0.0.6.patch

ARCH_FLAGS=(-arch arm64 -arch x86_64 -mmacosx-version-min="$MIN_MACOS" -O2 -w)
CXX_FLAGS=(-std=c++17 "${ARCH_FLAGS[@]}" -I"$FH/inc" -I"$RV/inc" -I"$CMS/include")

echo "==> Compiling libraries"
for src in "$CMS"/src/*.c; do
  clang "${ARCH_FLAGS[@]}" -I"$CMS/include" -I"$CMS/src" -c "$src" -o "$OBJ/lcms-${src:t}.o" &
done
wait
for name in RVNGBinaryData RVNGMemoryStream RVNGProperty RVNGPropertyList RVNGPropertyListVector RVNGString \
            RVNGStringVector RVNGSVGDrawingGenerator RVNGStreamImplementation RVNGOLEStream RVNGZipStream; do
  clang++ "${CXX_FLAGS[@]}" -I"$RV/src/lib" -c "$RV/src/lib/$name.cpp" -o "$OBJ/rv-$name.o" &
done
wait
for src in "$FH"/src/lib/*.cpp; do
  clang++ "${CXX_FLAGS[@]}" -DLIBFREEHAND_BUILD=1 -I"$FH/src/lib" -c "$src" -o "$OBJ/fh-${src:t}.o" &
done
wait

echo "==> Compiling the app"
clang++ "${CXX_FLAGS[@]}" -fobjc-arc -ISources -c Sources/FHEngine.mm -o "$OBJ/FHEngine.o"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Resources/Source"
THIN=()
for arch in $ARCHS; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" -import-objc-header Sources/FHEngine.h Sources/main.swift \
    "$OBJ"/*.o -lz -lc++ -framework AppKit -framework CoreText -framework ImageIO \
    -o "$BUILD/app-$arch" 2>&1 | grep -v 'SwiftUICore' || true
  THIN+=("$BUILD/app-$arch")
done
lipo -create "${THIN[@]}" -output "$APP/Contents/MacOS/FreeHand a PDF"

cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/Licenses/"
cp "$FH/COPYING" "$APP/Contents/Resources/Licenses/libfreehand-COPYING.txt"
cp "$RV/COPYING.MPL" "$APP/Contents/Resources/Licenses/librevenge-COPYING.MPL.txt"
cp "$RV/COPYING.LGPL" "$APP/Contents/Resources/Licenses/librevenge-COPYING.LGPL.txt"
cp "$CMS/LICENSE" "$APP/Contents/Resources/Licenses/lcms2-LICENSE.txt" 2>/dev/null || cp "$CMS/COPYING" "$APP/Contents/Resources/Licenses/lcms2-LICENSE.txt"
cp Sources/* patches/* "$APP/Contents/Resources/Source/"
xattr -cr "$APP"
codesign --force --deep -s - "$APP" 2>/dev/null

echo "==> Done: $APP"
