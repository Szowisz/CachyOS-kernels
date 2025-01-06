#!/usr/bin/env bash

set -e

. /etc/profile
#modprobe dm-crypt

#export CCACHE_DIR="/var/cache/ccache/kernel"
#export KERNEL_CC="ccache clang" UTILS_CC="ccache clang" UTILS_CXX="ccache clang++"
#export KERNEL_CC="ccache gcc" UTILS_CC="ccache gcc" UTILS_CXX="ccache g++"
export KERNEL_CC="clang" UTILS_CC="clang" UTILS_CXX="clang++"

KERNEL_ROOT="/usr/src/linux"
MAKEOPTS="LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld"
# check if tools/perf/kernel-compilation.afdo exists
if [ -f $KERNEL_ROOT/tools/perf/kernel-compilation.afdo ]; then
    echo "AutoFDO profile has been found..."
    MAKEOPTS+=" CLANG_AUTOFDO_PROFILE=$KERNEL_ROOT/tools/perf/kernel-compilation.afdo"
fi

# make function with args
kernel_make() {
    #make -j$(( $(nproc) + 1 )) ${MAKEOPTS} KCFLAGS="-O3 -march=native -pipe"
    make -j$(( $(nproc) + 1 )) ${MAKEOPTS} KCFLAGS="-pipe" $@
}


cd $KERNEL_ROOT
kernel_make clean
#kernel_make olddefconfig
# https://github.com/openzfs/zfs/issues/15911
./scripts/config -d CONFIG_CFI_CLANG -e CONFIG_CFI_PERMISSIVE

kernel_make all
kernel_make -C tools/bpf/bpftool vmlinux.h feature-clang-bpf-co-re=1
#make modules_prepare

# check zfs dir exists
if [ -d ./zfs ]; then
    cd ./zfs
    CONFIGURE_FLAGS=()
    CONFIGURE_FLAGS+=("KERNEL_LLVM=1")
    ./autogen.sh
    ./configure "${CONFIGURE_FLAGS[@]}" --prefix=/usr --sysconfdir=/etc --sbindir=/usr/bin \
        --libdir=/usr/lib --datadir=/usr/share --includedir=/usr/include \
        --with-udevdir=/lib/udev --libexecdir=/usr/lib/zfs --with-config=kernel \
        --with-linux=$KERNEL_ROOT
    kernel_make
    kernel_make install;
    #ldconfig; depmod
    cd ..
fi

kernel_make modules_install
kernel_make install
emerge @module-rebuild
