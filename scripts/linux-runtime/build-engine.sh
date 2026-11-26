#!/usr/bin/env bash
# Linux host. Usage: OHOS_NDK=/path/to/native ./build-engine.sh x86_64|aarch64
set -euo pipefail
arch=${1:?Specify x86_64 or aarch64}
case "$arch" in x86_64) abi=x86_64 ;; aarch64) abi=arm64-v8a ;; *) exit 2 ;; esac
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${TCI_BUILD_DIR:-$HOME/tinybot-tci-build}
mkdir -p "$work/sources" "$work/$arch"
work=$(cd "$work" && pwd)
# Both ABIs share source archives and Meson fallback subprojects.
exec 9>"$work/source-build.lock"
flock 9
ndk=${OHOS_NDK:?Set OHOS_NDK to the HarmonyOS native SDK}
b="$work/$arch"
p="$b/prefix"
s="$work/sources"
mkdir -p "$p" "$b/bin"
fetch() {
  local url=$1 file=$2 digest=$3
  if [[ ! -f "$file" ]]; then
    curl --fail --location --retry 2 "$url" -o "$file.part"
    mv "$file.part" "$file"
  fi
  echo "$digest  $file" | sha256sum --check --status
}
source_archive() {
  fetch "$1" "$s/$2" "$4"
  if [[ ! -d "$s/$3" ]]; then tar -xf "$s/$2" -C "$s"; fi
}
source_archive https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz ffi.tar.gz libffi-3.4.6 b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
source_archive https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2 pcre.tar.bz2 pcre2-10.44 d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96
source_archive https://download.gnome.org/sources/glib/2.82/glib-2.82.0.tar.xz glib.tar.xz glib-2.82.0 f4c82ada51366bddace49d7ba54b33b4e4d6067afa3008e4847f41cb9b5c38d3
source_archive https://www.kernel.org/pub/software/utils/dtc/dtc-1.7.2.tar.xz dtc.tar.xz dtc-1.7.2 92d8ca769805ae1f176204230438fe52808f4e1c7944053c9eec0e649b237539
fetch https://codeload.github.com/harmoninux/qemu/tar.gz/50ce7096eb6b338bee88a0960c543f93f1b16959 "$work/qemu.tar.gz" 3935ccfaced223cab0f579234571a8d63176668c98e85b52c436a68cb9d1d60c
if [[ ! -d "$work/qemu" ]]; then
  tar xf "$work/qemu.tar.gz" -C "$work"
  mv "$work/qemu-50ce7096eb6b338bee88a0960c543f93f1b16959" "$work/qemu"
fi
res=$(find "$ndk/llvm/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
for tool in clang clang++; do
  cat > "$b/bin/$tool" <<EOF
#!/bin/sh
exec /usr/bin/$tool --target=$arch-linux-ohos --sysroot="$ndk/sysroot" -resource-dir="$res" -L"$ndk/llvm/lib/$arch-linux-ohos" -D_UAPI_LINUX_SOCKET_H -D__kernel_sa_family_t=__UINT16_TYPE__ -fuse-ld=lld "\$@" -Wno-unused-command-line-argument
EOF
  chmod +x "$b/bin/$tool"
done
export CC="$b/bin/clang" CXX="$b/bin/clang++" AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
export PKG_CONFIG_LIBDIR="$p/lib/pkgconfig" PKG_CONFIG_PATH="" CFLAGS="-O2 -fPIC" LDFLAGS="-L$p/lib"
cat > "$b/cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
[properties]
needs_exe_wrapper = true
EOF
jobs=${JOBS:-8}
for dep in libffi-3.4.6 pcre2-10.44; do
  mkdir -p "$b/$dep"; cd "$b/$dep"
  if [[ ! -e installed ]]; then
    "$s/$dep/configure" --build="$(gcc -dumpmachine)" --host="$arch-linux-musl" --prefix="$p" --disable-shared --enable-static --disable-docs
    make -j"$jobs" && make install && touch installed
  fi
done
cd "$s/dtc-1.7.2/libfdt"
for src in *.c; do "$CC" $CFLAGS -I. -c "$src" -o "$b/${src%.c}.o"; done
"$AR" rcs "$p/lib/libfdt.a" "$b"/fdt*.o
cp libfdt.h libfdt_env.h fdt.h "$p/include/"
if [[ ! -f "$p/lib/libglib-2.0.a" ]]; then
  meson setup "$b/glib" "$s/glib-2.82.0" --cross-file "$b/cross.ini" --prefix "$p" --libdir lib --default-library static --buildtype release -Dtests=false -Dinstalled_tests=false -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled -Dnls=disabled -Dsysprof=disabled
  ninja -C "$b/glib" -j"$jobs" install
fi
q="$work/qemu"
# The fork's ACPI table builder enumerates CXL windows even in a no-CXL build.
# Complete its disabled-device stubs: such a machine has zero CXL windows.
if ! grep -q 'cxl_fmws_get_all_sorted' "$q/hw/cxl/cxl-host-stubs.c"; then
  printf '\nGSList *cxl_fmws_get_all_sorted(void) { return NULL; }\n' >> "$q/hw/cxl/cxl-host-stubs.c"
fi
printf 'CONFIG_ARM_VIRT=y\nCONFIG_VIRTIO_BLK=y\nCONFIG_VIRTIO_PCI=y\n' > "$q/configs/devices/aarch64-softmmu/tinybot.mak"
mkdir -p "$b/qemu"; cd "$b/qemu"
extra="-fPIC -I$p/include -D_UAPI_LINUX_VIRTIO_VSOCK_H -D_UAPI_LINUX_VIRTIO_TYPES_H -D_UAPI_LINUX_VIRTIO_RING_H -D_UAPI_LINUX_VIRTIO_PMEM_H -D_UAPI_LINUX_VIRTIO_IOMMU_H -D_UAPI_LINUX_VIRTIO_FS_H -D_UAPI_LINUX_VIRTIO_CONSOLE_H -D_UAPI_LINUX_VIRTIO_CONFIG_H -D_LINUX_SYSINFO_H -D__user= -D__force="
"$q/configure" --cc="$CC" --cxx="$CXX" --host-cc=cc --cpu="$arch" --cross-prefix="" --target-list=aarch64-softmmu --without-default-features --without-default-devices --with-devices-aarch64=tinybot --enable-tcg --enable-tcg-interpreter --enable-fdt=system --disable-docs --disable-werror --disable-rust --with-coroutine=sigaltstack --extra-cflags="$extra" --extra-ldflags="-L$p/lib"
ninja -j"$jobs" libqemu-system-aarch64.so
grep -Eq '^#define CONFIG_TCG_INTERPRETER( 1)?$' config-host.h
out="$repo/entry/libs/$abi"
mkdir -p "$out"
llvm-strip -o "$out/libqemu-system-aarch64-tci.so" libqemu-system-aarch64.so
readelf -d "$out/libqemu-system-aarch64-tci.so" | grep NEEDED
