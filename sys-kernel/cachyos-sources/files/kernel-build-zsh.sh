#!/usr/bin/env bash

set -e

. /etc/profile
#modprobe dm-crypt

#export CCACHE_DIR="/var/cache/ccache/kernel"
#export KERNEL_CC="ccache clang" UTILS_CC="ccache clang" UTILS_CXX="ccache clang++"
#export KERNEL_CC="ccache gcc" UTILS_CC="ccache gcc" UTILS_CXX="ccache g++"
#export KERNEL_CC="clang" UTILS_CC="clang" UTILS_CXX="clang++"

KERNEL_ROOT="/usr/src/linux"
#MAKEOPTS="LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld"

cd $KERNEL_ROOT
#if [ -d ./zfs ]; then
#    cd ./zfs
#    ./autogen.sh
#    CONFIGURE_FLAGS=()
#    CONFIGURE_FLAGS+=("KERNEL_LLVM=1")
#    ./configure "${CONFIGURE_FLAGS[@]}" --prefix=/usr --sysconfdir=/etc --sbindir=/usr/bin \
#        --libdir=/usr/lib --datadir=/usr/share --includedir=/usr/include \
#        --with-udevdir=/lib/udev --libexecdir=/usr/lib/zfs --with-config=kernel \
#        --with-linux=$KERNEL_ROOT --enable-linux-builtin 
#    ./copy-builtin $KERNEL_ROOT
#    cd ..
#    ./scripts/config -e CONFIG_ZFS
#fi
#make clean
make ${MAKEOPTS} olddefconfig

# make function with args
build() {
    #make -j$(( $(nproc) + 1 )) ${MAKEOPTS} KCFLAGS="-O3 -march=native -pipe"
    make -j$(( $(nproc) + 1 )) ${MAKEOPTS} KCFLAGS="-pipe" $@
}

build all
make -C tools/bpf/bpftool vmlinux.h feature-clang-bpf-co-re=1
#make modules_prepare

# check zfs dir exists
if [ -d ./zfs ]; then
    cd ./zfs
    CONFIGURE_FLAGS=()
    #CONFIGURE_FLAGS+=("KERNEL_LLVM=1")
    ./autogen.sh
    ./configure "${CONFIGURE_FLAGS[@]}" --prefix=/usr --sysconfdir=/etc --sbindir=/usr/bin \
        --libdir=/usr/lib --datadir=/usr/share --includedir=/usr/include \
        --with-udevdir=/lib/udev --libexecdir=/usr/lib/zfs --with-config=kernel \
        --with-linux=$KERNEL_ROOT
    build
    make install; ldconfig; depmod
    cd ..
fi

make modules_install
make install
emerge @module-rebuild
