#!/bin/bash
# Full Madeira build on macOS (Apple silicon), following docs/BUILDING.md, filling the
# gaps found when running it from a clean checkout. Used by .github/workflows/build-ipa.yml;
# also runs locally:  caffeinate -i ci/build-all.sh
# Resumable: each finished step leaves a stamp in .build-stamps/; re-run to continue.
# Logs: build-logs/<step>.log
set -euo pipefail
R="$(cd "$(dirname "$0")/.." && pwd)"; cd "$R"
JOBS="$(sysctl -n hw.ncpu)"
export CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" MAKEFLAGS="-j$JOBS"
TCN=llvm-mingw-20260421-ucrt-macos-universal
TC="$R/toolchains/$TCN/bin"
# FEX prefers system packages over its bundled External/ copies; Homebrew's are macOS builds,
# and the app links the bundled archives (FEX/build-ios/External/*), so never look outside.
FEX_NO_SYSTEM_PKGS="-DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON -DCMAKE_DISABLE_FIND_PACKAGE_xxhash=ON \
 -DCMAKE_DISABLE_FIND_PACKAGE_Zydis=ON -DCMAKE_DISABLE_FIND_PACKAGE_Zycore=ON \
 -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
 -DCMAKE_DISABLE_FIND_PACKAGE_Catch2=ON"
LLVM_COMMIT=8dfdcc7b7
mkdir -p .build-stamps build-logs toolchains
# Rust: rustup from rustup.rs (~/.cargo/bin) or Homebrew (keg-only)
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"
STATUS="$R/build-logs/STATUS"

step() {  # step <name> <command...>
  local n="$1"; shift
  if [ -f ".build-stamps/$n" ]; then echo "[skip] $n"; return; fi
  echo "[run ] $n  ($(date '+%H:%M:%S'))  log: build-logs/$n.log"
  echo "RUNNING $n $(date '+%F %T')" > "$STATUS"; touch .build-stamps/.step-start
  # Not inside `if`: bash ignores set -e in a tested command, which hid failures in steps.
  set +e; ( set -e; cd "$R"; "$@" ) > "build-logs/$n.log" 2>&1; local rc=$?; set -e
  if [ $rc -eq 0 ]; then
    touch ".build-stamps/$n"; echo "[ ok ] $n"
  else
    echo "FAILED $n $(date '+%F %T')" > "$STATUS"
    echo "[FAIL] $n -- first errors in build-logs/$n.log:"
    grep -nE 'error:|Error [0-9]|FAILED|fatal' "build-logs/$n.log" | head -25 || true
    echo "--- last lines:"; tail -40 "build-logs/$n.log"
    # Per-file compiler errors the repo's scripts write next to their objects:
    find build -path '*/obj/*.err' -size +0 -newer ".build-stamps/.step-start" 2>/dev/null | while read -r e; do
      echo "--- $e"; head -40 "$e"; done
    exit 1
  fi
}

# ---------------------------------------------------------------- prerequisites
prereqs() {
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-path
  command -v brew || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
  brew install cmake ninja meson bison llvm ccache pkg-config
  export PATH="$(brew --prefix bison)/bin:$PATH"; bison --version | head -1
  xcrun -f metal || xcodebuild -downloadComponent MetalToolchain
  command -v rustup || brew install rustup
  rustup toolchain list | grep -q stable || rustup default stable
  rustup target add aarch64-apple-ios
  cargo --version
  python3 --version
  df -h "$R"
}

# ---------------------------------------------------------------- toolchains
llvm_mingw() {
  cd toolchains
  [ -f "$TCN.tar.xz" ] || curl -fL -o "$TCN.tar.xz" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$TCN.tar.xz"
  echo "bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7  $TCN.tar.xz" | shasum -a 256 -c
  rm -rf "$TCN"; tar xf "$TCN.tar.xz"; "$TC/arm64ec-w64-mingw32-clang" --version | head -1
}

llvm_src() {
  cd toolchains
  [ -f llvm-$LLVM_COMMIT.tar.gz ] || curl -fL -o llvm-$LLVM_COMMIT.tar.gz \
    "https://github.com/llvm/llvm-project/archive/$LLVM_COMMIT.tar.gz"
  rm -rf llvm-project; mkdir llvm-project
  tar xzf llvm-$LLVM_COMMIT.tar.gz -C llvm-project --strip-components=1
  # dxmt-ios/README.md: Apple ld needs -dead_strip for iOS too, not --gc-sections.
  python3 - llvm-project/llvm/cmake/modules/AddLLVM.cmake <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
i = s.find('-dead_strip'); j = s.rfind('MATCHES "Darwin"', 0, i)
assert i > 0 and j > 0, "dead_strip block not found"
s = s[:j] + 'MATCHES "Darwin|iOS"' + s[j+len('MATCHES "Darwin"'):]
open(p, 'w').write(s); print("patched AddLLVM.cmake")
PY
}

llvm_host() {
  cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off
  ninja -C toolchains/llvm-host-build llvm-tblgen
}

llvm_ios() {
  cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 -DLLVM_TARGET_ARCH=host \
    -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_BUILD_UTILS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off \
    -DLLVM_TABLEGEN="$R/toolchains/llvm-host-build/bin/llvm-tblgen" \
    -DLLVM_ENABLE_PLUGINS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_BUILD_EXAMPLES=Off \
    -DLLVM_INCLUDE_BENCHMARKS=Off
  # Only the libraries: DXMT's airconv links them; iOS tools/plugins don't link (LLVMHello.def).
  # Static archives only (libLTO/libRemarks dylibs pass -z defs, which Apple ld rejects).
  ninja -C toolchains/llvm-ios-build $(ninja -C toolchains/llvm-ios-build -t targets all \
    | grep -oE '^lib/libLLVM[A-Za-z0-9]+\.a' | sort -u)
  ls toolchains/llvm-ios-build/lib/libLLVM*.a | wc -l
}

# ---------------------------------------------------------------- Wine trees
wine_arm64ec() {
  export PATH="$(brew --prefix bison)/bin:$PATH"
  build/wine-pe/build-ntdll.sh
  export PATH="$TC:$PATH"; make -C wine/build-arm64ec -j"$JOBS" include/all
}
wine_macos() {  # host tree whose config.h / generated headers / tools the unix-side scripts read
  export PATH="$(brew --prefix bison)/bin:$TC:$PATH"
  mkdir -p wine/build-macos; cd wine/build-macos
  [ -f config.status ] || ../configure --enable-archs=aarch64 --without-x --disable-tests --enable-winegstreamer
  make -j"$JOBS" __tooldeps__ include/all
}

wineserver() {
  # build/wineserver/build.sh only patches iOS objects into a prebuilt base archive
  # (app/Madeira/libwineserver.a, never committed). Recreate that base: every wine/server
  # source the patch list does not replace, compiled with the script's own flags.
  if [ ! -f app/Madeira/libwineserver.a ] && [ ! -f build/wineserver/obj/libwineserver.a ]; then
    local SDK B=build/wineserver W=wine OBJ=build/wineserver/obj/base fails=""
    SDK=$(xcrun --sdk iphoneos --show-sdk-path); mkdir -p "$OBJ"
    local FLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
      -I"$W/include" -I"$W/include/wine" -I"$W/build-macos/include" -I"$B" -I"$W/server"
      -Ibuild/ntdll-unix/shims -Ibuild/madsync -DHAVE_LINUX_NTSYNC_H=1
      -include "$B/config_ios.h" -include stdarg.h -include "$B/unicode_fix.h"
      -include "$B/wineserver_ios_kill.h"
      -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\" -D__WINESRC__ -DWINE_IOS=1
      -Dmain=wineserver_main -Wno-implicit-function-declaration)
    for f in atom change clipboard completion console d3dkmt debugger device directory file hook \
             mailslot mutex named_pipe procfs ptrace registry serial signal symlink timer token trace; do
      if xcrun -sdk iphoneos clang "${FLAGS[@]}" -c "$W/server/$f.c" -o "$OBJ/$f.o" 2>"$OBJ/$f.err"; then
        echo "  base $f OK"
      else
        echo "  base $f FAILED"; head -20 "$OBJ/$f.err"; fails="$fails $f"
      fi
    done
    [ -z "$fails" ] || { echo "base objects failed:$fails"; exit 1; }
    ar rcs app/Madeira/libwineserver.a "$OBJ"/*.o
  fi
  build/wineserver/build.sh
}

ntdll_unix() {
  # server_ios.c logs rusage_info_v6.ri_page_wait_time_mach (the "pgw=" diagnostic), a field
  # only newer iOS SDKs declare. On an SDK without it, log 0 for that one value.
  H="$(xcrun --sdk iphoneos --show-sdk-path)/usr/include/sys/resource.h"
  if ! grep -q ri_page_wait_time_mach "$H"; then
    echo "SDK lacks ri_page_wait_time_mach: logging pgw=0"
    sed -i '' 's/XP_MS( ru\.ri_page_wait_time_mach - pru\.ri_page_wait_time_mach )/0.0/' build/ntdll-unix/server_ios.c
  fi
  build/ntdll-unix/build.sh
}

freetype() {  # build/freetype-ios/build.sh expects this clone (its header); dwrite + win32u need it
  [ -d research/freetype/.git ] || git clone --depth 1 --branch VER-2-13-3 \
    https://github.com/freetype/freetype.git research/freetype
  bash build/freetype-ios/build.sh   # tracked without the executable bit
}

fex_ios() {  # build/fex-ios/build.sh options + CMAKE_SYSTEM_PROCESSOR (empty for iOS)
  rm -rf FEX/build-ios   # CMakeSystem.cmake from a failed configure pins an empty processor
  cmake -S FEX -B FEX/build-ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF \
    -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF \
    -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON -DTUNE_CPU=none $FEX_NO_SYSTEM_PKGS
  # No FEX_IOS_HOST here: in FEX that means "Windows module on an iOS host" (VirtualQuery etc.);
  # the native iOS FEXCore is the __APPLE__ path.
  build/fex-ios/build.sh
  ls FEX/build-ios/FEXCore/Source/*.a
  cmake --build FEX/build-ios --target fmt cephes_128bit softfloat_3e xxhash JemallocLibs
  ls FEX/build-ios/FEXCore/Source/libJemallocLibs.a FEX/build-ios/External/fmt/libfmt.a FEX/build-ios/External/cephes/libcephes_128bit.a \
     FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a
}

fex_arm64ec() {  # build/fex-arm64ec/build.sh options + MINGW_TRIPLE + the iOS-host link rules (FEX_IOS_HOST_BUILD)
  export PATH="$TC:$PATH"
  rm -rf FEX/build-arm64ec
  cmake -S FEX -B FEX/build-arm64ec -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
    -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON -DENABLE_OFFLINE_RUNTIME=ON \
    -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON -DTUNE_CPU=none $FEX_NO_SYSTEM_PKGS \
    -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF \
    -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST \
    -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST -DENABLE_LTO=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  # ENABLE_LTO=OFF as build/fex-wow64/build.sh does: with LTO the EC objects reach lld as
  # bitcode and libc++'s EC symbols go unresolved.
  build/fex-arm64ec/build.sh
}

dxmt_combined() {  # build/dxmt-ios/README.md: DXMT unix objs + LLVM iOS libs -> the archive Xcode links
  LIBS=$(ls toolchains/llvm-ios-build/lib/libLLVM*.a)
  xcrun -sdk iphoneos libtool -static -o build/dxmt-ios/libdxmt_combined.a build/dxmt-ios/obj/*.o $LIBS
  cp build/dxmt-ios/libdxmt_combined.a app/Madeira/; ls -lh app/Madeira/libdxmt_combined.a
}

dxmt_pe() {
  [ -e dxmt/toolchains ] || ln -s ../toolchains dxmt/toolchains
  [ -d dxmt/build-arm64ec ] || meson setup dxmt/build-arm64ec dxmt -Dbuildtype=release \
    -Dwine_build_path=../../wine/build-arm64ec --cross-file=dxmt/build-arm64ec-win.txt
  ninja -C dxmt/build-arm64ec src/winemetal/winemetal.dll src/d3d11/d3d11.dll
  cp dxmt/build-arm64ec/src/winemetal/winemetal.dll dxmt/build-arm64ec/src/d3d11/d3d11.dll app/Madeira/arm64ec-windows/
}

vcruntime_check() {
  n=$(ls app/Madeira/x86_64-vcruntime/*.dll | wc -l); echo "$n DLLs"; [ "$n" -ge 12 ]
}

app() {
  xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath build-out/DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
}
ipa() {
  APP=$(find build-out/DerivedData/Build/Products/Debug-iphoneos -maxdepth 1 -name 'Madeira.app' | head -1)
  rm -rf build-out/ipa && mkdir -p build-out/ipa/Payload && ditto "$APP" build-out/ipa/Payload/Madeira.app
  (cd build-out/ipa && zip -qry ../Madeira-unsigned.ipa Payload)
  ls -lh build-out/Madeira-unsigned.ipa
}

step 00-prereqs        prereqs
step 01-llvm-mingw     llvm_mingw
step 02-llvm-src       llvm_src
step 03-llvm-host      llvm_host
step 04-llvm-ios       llvm_ios
step 05-gnutls         build/gnutls-ios/build.sh
step 06-ffmpeg         build/ffmpeg/build.sh
step 07-fex-ios        fex_ios
step 08-fex-arm64ec    fex_arm64ec
step 09-wine-arm64ec   wine_arm64ec
step 10-wine-modules   bash -c 'export PATH="$(brew --prefix bison)/bin:$PATH"; build/wine-pe/build-modules.sh'
step 11-wine-macos     wine_macos
step 11b-freetype     freetype
step 12-ntdll-unix     ntdll_unix
step 13-wineserver     wineserver
step 14-win32u-unix    build/win32u-unix/build.sh
step 15-dxmt-ios       build/dxmt-ios/build.sh
step 15b-dxmt-combined dxmt_combined
step 16-dxmt-pe        dxmt_pe
step 17-rppairing      build/rppairing-ios/build.sh
step 18-d3d12          build/madeira-d3d12/build-pe.sh
step 19-licenses       build/stage-licenses.sh
step 20-vcruntime      vcruntime_check
step 21-app            app
step 22-ipa            ipa
echo "DONE $(date '+%F %T')" > "$STATUS"
echo "Built: $R/build-out/Madeira-unsigned.ipa  (sign + install with SideStore/AltStore/Sideloadly)"
