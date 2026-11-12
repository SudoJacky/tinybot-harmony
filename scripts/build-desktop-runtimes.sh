#!/usr/bin/env bash
set -euo pipefail

# Build from clean, verified upstream Git checkouts on a Linux build host.
# OHOS_NATIVE_HOME points to the native component of the Linux OpenHarmony SDK.
node_tag=v24.22.3
dash_tag=v0.5.13.5
if [[ $# != 2 || $(uname -s) != Linux ]]; then
  printf '%s\n' "Usage on Linux: OHOS_NATIVE_HOME=/path/to/native bash $0 <node $node_tag checkout> <dash $dash_tag checkout>" >&2
  exit 2
fi

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
node_source=$(cd -- "$1" && pwd)
dash_source=$(cd -- "$2" && pwd)
native=$(cd -- "${OHOS_NATIVE_HOME:?Set OHOS_NATIVE_HOME to the Linux SDK native directory}" && pwd)
llvm="$native/llvm/bin"
jobs=${DESKTOP_RUNTIME_JOBS:-4}

check_checkout() {
  local checkout=$1 tag=$2
  if [[ $(git -C "$checkout" rev-parse HEAD) != "$(git -C "$checkout" rev-parse "refs/tags/$tag^{commit}")" ]] ||
    [[ -n $(git -C "$checkout" status --porcelain --untracked-files=no) ]]; then
    printf '%s\n' "Expected a clean $tag checkout in $checkout" >&2
    exit 2
  fi
}

check_checkout "$node_source" "$node_tag"
check_checkout "$dash_source" "$dash_tag"
target=aarch64-unknown-linux-ohos
cc="$llvm/$target-clang"
cxx="$llvm/$target-clang++"
for tool in "$cc" "$cxx" "$llvm/llvm-ar" "$llvm/llvm-ranlib" "$llvm/llvm-readelf"; do
  if [[ ! -x "$tool" ]]; then
    printf '%s\n' "Missing Linux SDK tool $tool" >&2
    exit 2
  fi
done

(
  cd -- "$node_source"
  export CC_host=${CC_FOR_BUILD:-cc} CXX_host=${CXX_FOR_BUILD:-c++}
  export CC="$cc" CXX="$cxx" AR="$llvm/llvm-ar" RANLIB="$llvm/llvm-ranlib"
  export CC_target="$CC" CXX_target="$CXX" AR_target="$AR"
  ./configure --dest-os=openharmony --dest-cpu=arm64 --cross-compiling \
    --without-node-snapshot --without-npm --v8-lite-mode
  make -j "$jobs" LDFLAGS.target=-static-libstdc++
)

(
  cd -- "$dash_source"
  autoreconf -fi
  CC="$cc" AR="$llvm/llvm-ar" RANLIB="$llvm/llvm-ranlib" \
    ./configure --build="$(./config.guess)" --host=aarch64-linux-ohos --without-libedit
  make -j "$jobs"
)

node_bin="$node_source/out/Release/node"
dash_bin="$dash_source/src/dash"
for binary in "$node_bin" "$dash_bin"; do
  header=$(LC_ALL=C "$llvm/llvm-readelf" -h -l "$binary")
  if [[ "$header" != *AArch64* || "$header" != *'program interpreter: /lib/ld-musl-aarch64.so.1'* ]]; then
    printf '%s\n' "Expected an ARM64 OpenHarmony executable in $binary" >&2
    exit 1
  fi
done

libs="$root/entry/libs/arm64-v8a"
licenses="$root/entry/src/main/resources/rawfile/desktop-runtime-licenses"
mkdir -p -- "$libs" "$licenses"
install -m 0644 "$node_source/LICENSE" "$licenses/node.txt"
install -m 0644 "$dash_source/COPYING" "$licenses/dash.txt"
install -m 0755 "$node_bin" "$libs/tinybot-node"
install -m 0755 "$dash_bin" "$libs/tinybot-sh"
printf '%s\n' "Staged Node.js $node_tag and Dash $dash_tag for the next DevEco HAP build."
