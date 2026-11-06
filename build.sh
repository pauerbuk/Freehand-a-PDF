#!/bin/zsh
# Builds "FreeHand a PDF.app" in ./build.
# Needs the Xcode command line tools and Homebrew. Homebrew is only used to download
# prebuilt librevenge and lcms2 packages: nothing gets installed on your system.
set -euo pipefail
cd "${0:A:h}"

FH_VERSION=0.1.4
FH_URL="https://dev-www.libreoffice.org/src/libfreehand/libfreehand-$FH_VERSION.tar.xz"
FH_SHA256=350b10d24a76d7e8c8ae98b74c2d432a2c8ddec08935d09856d20b695a35e600
BUILD="$PWD/build"
DEPS="$BUILD/deps"
OBJ="$BUILD/obj"
APP="$BUILD/FreeHand a PDF.app"

for tool in brew curl patch shasum swiftc clang++ install_name_tool codesign; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

rm -rf "$BUILD"
mkdir -p "$DEPS/include" "$DEPS/lib" "$DEPS/licenses" "$OBJ"

echo "==> libfreehand $FH_VERSION"
curl -fsSL "$FH_URL" -o "$BUILD/libfreehand.tar.xz"
echo "$FH_SHA256  $BUILD/libfreehand.tar.xz" | shasum -a 256 -c - >/dev/null
tar -xJf "$BUILD/libfreehand.tar.xz" -C "$BUILD"
FH="$BUILD/libfreehand-$FH_VERSION"
patch -d "$FH" -p1 --quiet < patches/libfreehand-$FH_VERSION.patch
cp -R "$FH/inc/libfreehand" "$DEPS/include/libfreehand"
cp "$FH/COPYING" "$DEPS/licenses/libfreehand-COPYING.txt"

for formula in librevenge little-cms2; do
  echo "==> $formula"
  brew fetch --quiet --force-bottle "$formula" >/dev/null
  mkdir -p "$DEPS/$formula"
  tar -xzf "$(brew --cache --force-bottle "$formula")" -C "$DEPS/$formula"
done
REVENGE=("$DEPS"/librevenge/librevenge/*(/[1]))
LCMS=("$DEPS"/little-cms2/little-cms2/*(/[1]))
cp -R "$REVENGE"/include/librevenge-0.0/librevenge "$REVENGE"/include/librevenge-0.0/librevenge-stream "$DEPS/include/"
cp "$LCMS"/include/lcms2.h "$DEPS/include/"
cp "$LCMS"/lib/liblcms2.a "$DEPS/lib/"
cp "$REVENGE"/lib/librevenge-0.0.0.dylib "$REVENGE"/lib/librevenge-stream-0.0.0.dylib "$DEPS/lib/"
cp "$REVENGE"/COPYING.MPL "$DEPS/licenses/librevenge-COPYING.MPL.txt"
cp "$REVENGE"/COPYING.LGPL "$DEPS/licenses/librevenge-COPYING.LGPL.txt"
cp "$LCMS"/LICENSE "$DEPS/licenses/lcms2-LICENSE.txt"

# The Homebrew packages refer to their install location: make them relocatable inside the app.
chmod -R u+w "$DEPS/lib"
for lib in "$DEPS"/lib/*.dylib; do
  install_name_tool -id "@rpath/${lib:t}" "$lib" 2>/dev/null
  for dep in $(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep '@@HOMEBREW' || true); do
    install_name_tool -change "$dep" "@rpath/${dep:t}" "$lib" 2>/dev/null
  done
  codesign --force -s - "$lib" 2>/dev/null
done

echo "==> Compiling"
for src in "$FH"/src/lib/*.cpp; do
  clang++ -std=c++17 -O2 -w -DLIBFREEHAND_BUILD=1 -I"$DEPS/include" -I"$FH/src/lib" -c "$src" -o "$OBJ/${src:t}.o"
done
clang++ -std=c++17 -O2 -fobjc-arc -I"$DEPS/include" -ISources -c Sources/FHEngine.mm -o "$OBJ/FHEngine.o"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses" "$APP/Contents/Resources/Source"
swiftc -O -import-objc-header Sources/FHEngine.h Sources/main.swift "$OBJ"/*.o "$DEPS/lib/liblcms2.a" \
  "$DEPS/lib/librevenge-0.0.0.dylib" "$DEPS/lib/librevenge-stream-0.0.0.dylib" -lz -lc++ \
  -framework AppKit -framework CoreText -framework ImageIO \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/FreeHand a PDF"

cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$(sw_vers -productVersion | cut -d. -f1).0" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$DEPS"/licenses/* LICENSE "$APP/Contents/Resources/Licenses/"
cp Sources/* patches/* "$APP/Contents/Resources/Source/"
cp "$DEPS"/lib/*.dylib "$APP/Contents/Frameworks/"
codesign --force --deep -s - "$APP" 2>/dev/null

echo "==> Done: $APP"
