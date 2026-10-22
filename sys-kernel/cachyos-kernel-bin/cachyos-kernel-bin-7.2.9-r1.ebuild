# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

KERNEL_IUSE_GENERIC_UKI=1

inherit flag-o-matic kernel-install toolchain-funcs

# Hardened-only coverage: the mirror has no 7.2.10/7.2.11 hardened build, so
# this ebuild keeps the latest mirrored hardened binaries (7.2.9 pkgrel 2).
# The 7.2.9 source package is pkgrel 2 and the binary pkgrel follows the
# Gentoo revision (7.2.9-r1 -> pkgrel 2).
CACHYOS_SOURCE_PR="2"
CACHYOS_BIN_PR="$(( ${PR#r} + 1 ))"

MY_P="cachyos-${PV}-${CACHYOS_SOURCE_PR}"
BINPKG_VER="${PV}-${CACHYOS_BIN_PR}"

# Mirror base URLs
MIRROR_V3="https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3"

DESCRIPTION="Pre-built CachyOS Linux kernel (hardened, LTO, BBR3 and more)"
HOMEPAGE="
	https://github.com/CachyOS/linux-cachyos
	https://github.com/Szowisz/CachyOS-kernels
"

# Source tarball (shared by all variants, needed for modules_prepare)
SRC_URI="
	https://github.com/CachyOS/linux/releases/download/${MY_P}/${MY_P}.tar.gz
"

# Binary packages per variant (x86_64_v3 only for this version)
# 7.2.9 hardened only: hardened + hardened-lto at pkgrel 2
SRC_URI+="
	hardened? (
		lto? (
			${MIRROR_V3}/linux-cachyos-hardened-lto-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-hardened-lto-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
		!lto? (
			${MIRROR_V3}/linux-cachyos-hardened-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-hardened-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
	)
"

S="${WORKDIR}"

LICENSE="GPL-2"
KEYWORDS="~amd64"
IUSE="+hardened lto debug"
REQUIRED_USE="
	^^ ( hardened )
"

RDEPEND="
	!sys-kernel/cachyos-kernel:${SLOT}
"
BDEPEND="
	app-alternatives/bc
	app-alternatives/lex
	dev-util/pahole
	virtual/libelf
	app-alternatives/yacc
	lto? (
		llvm-core/llvm
		llvm-core/clang
		llvm-core/lld
	)
"
PDEPEND="
	>=virtual/dist-kernel-${PV}
"

QA_PREBUILT='*'

# Compute the CachyOS variant suffix (matches localversion.20-pkgname in PKGBUILD)
_cachyos_variant_suffix() {
	use lto && echo "cachyos-hardened-lto" || echo "cachyos-hardened"
}

_cachyos_pkgrel() {
	echo "${CACHYOS_BIN_PR}"
}

_cachyos_source_pkg() {
	echo "${MY_P}"
}

_cachyos_binpkg_ver() {
	echo "${BINPKG_VER}"
}

# Compute distfile name for the binary kernel package
_cachyos_bin_distfile() {
	local stem="linux-cachyos-hardened"
	use lto && stem+="-lto"
	echo "${stem}-$(_cachyos_binpkg_ver)-x86_64_v3.pkg.tar.zst"
}

# Compute distfile name for the binary headers package
_cachyos_headers_distfile() {
	local stem="linux-cachyos-hardened"
	use lto && stem+="-lto"
	echo "${stem}-headers-$(_cachyos_binpkg_ver)-x86_64_v3.pkg.tar.zst"
}

# Set KV_FULL and KV_LOCALVERSION based on USE flags
_cachyos_setup_kv() {
	local suffix=$(_cachyos_variant_suffix)
	KV_LOCALVERSION="-$(_cachyos_pkgrel)-${suffix}"
	KV_FULL="${PV}${KV_LOCALVERSION}"
}
pkg_setup() {
	_cachyos_setup_kv
}

src_unpack() {
	# Unpack the CachyOS kernel source tarball (for modules_prepare)
	unpack "$(_cachyos_source_pkg).tar.gz"

	# Unpack the binary kernel package (pacman .pkg.tar.zst format)
	mkdir -p "${WORKDIR}/binpkg" || die
	tar -C "${WORKDIR}/binpkg" -xf "${DISTDIR}/$(_cachyos_bin_distfile)" || die

	# Unpack the binary headers package
	mkdir -p "${WORKDIR}/headerspkg" || die
	tar -C "${WORKDIR}/headerspkg" -xf "${DISTDIR}/$(_cachyos_headers_distfile)" || die
}

src_prepare() {
	_cachyos_setup_kv

	cd "${WORKDIR}/$(_cachyos_source_pkg)" || die

	# Set localversion files to match the CachyOS binary exactly
	# These determine the kernel release string (uname -r)
	echo "-$(_cachyos_pkgrel)" > localversion.10-pkgrel || die
	echo "-$(_cachyos_variant_suffix)" > localversion.20-pkgname || die

	default
}

src_configure() {
	_cachyos_setup_kv

	# Determine the headers build directory from the binary package
	local headers_build="${WORKDIR}/headerspkg/usr/lib/modules/${KV_FULL}/build"
	# Headers must match the binary exactly; never fall back to another release.
	[[ -d ${headers_build} ]] ||
		die "Cannot find exact-match headers build directory: ${headers_build}"

	# Mirrored lto variants are built with Clang; all others with GCC.
	local cc_config=CONFIG_CC_IS_GCC
	use lto && cc_config=CONFIG_CC_IS_CLANG
	grep -qx "${cc_config}=y" "${headers_build}/.config" ||
		die "Mirrored headers lack ${cc_config}=y; update the USE=lto toolchain mapping"

	# Set up toolchain for modules_prepare
	local HOSTLD="$(tc-getBUILD_LD)"
	if type -P "${HOSTLD}.bfd" &>/dev/null; then
		HOSTLD+=.bfd
	fi
	local LD="$(tc-getLD)"
	if type -P "${LD}.bfd" &>/dev/null; then
		LD+=.bfd
	fi

	# LLVM=1 links host tools with lld, which cannot read GCC LTO objects.
	use lto && filter-lto
	tc-export_build_env
	local makeargs=(
		V=1
		WERROR=0
		HOSTCC="$(tc-getBUILD_CC)"
		HOSTCXX="$(tc-getBUILD_CXX)"
		HOSTLD="${HOSTLD}"
		HOSTAR="$(tc-getBUILD_AR)"
		HOSTCFLAGS="${BUILD_CFLAGS}"
		HOSTLDFLAGS="${BUILD_LDFLAGS}"
		ARCH="$(tc-arch-kernel)"
		O="${WORKDIR}/modprep"
	)

	# For LTO kernels, use Clang toolchain
	if use lto; then
		makeargs+=(
			LLVM=1
			LLVM_IAS=1
			CC=clang
			LD=ld.lld
			AR=llvm-ar
			NM=llvm-nm
			OBJCOPY=llvm-objcopy
			OBJDUMP=llvm-objdump
			READELF=llvm-readelf
			STRIP=llvm-strip
		)
	else
		makeargs+=(
			CROSS_COMPILE=${CHOST}-
			AS="$(tc-getAS)"
			CC="$(tc-getCC)"
			LD="${LD}"
			AR="$(tc-getAR)"
			NM="$(tc-getNM)"
			STRIP="$(tc-getSTRIP)"
			OBJCOPY="$(tc-getOBJCOPY)"
			OBJDUMP="$(tc-getOBJDUMP)"
			READELF="$(tc-getREADELF)"
		)
	fi

	# Copy .config from the binary headers package
	mkdir "${WORKDIR}/modprep" || die
	cp "${headers_build}/.config" "${WORKDIR}/modprep/" || die

	# Run modules_prepare on the source tree to compile build tools
	# for the local system (needed for out-of-tree module building)
	emake -C "${WORKDIR}/$(_cachyos_source_pkg)" "${makeargs[@]}" modules_prepare
}

src_test() {
	_cachyos_setup_kv

	local binpkg_modules="${WORKDIR}/binpkg/usr/lib/modules/${KV_FULL}"
	local headers_build="${WORKDIR}/headerspkg/usr/lib/modules/${KV_FULL}/build"

	kernel-install_test "${KV_FULL}" \
		"${binpkg_modules}/vmlinuz" \
		"${binpkg_modules}" \
		"${headers_build}/.config"
}

src_install() {
	_cachyos_setup_kv

	local rel_kernel_dir="/usr/src/linux-${KV_FULL}"
	local binpkg_modules="${WORKDIR}/binpkg/usr/lib/modules/${KV_FULL}"
	local headers_build="${WORKDIR}/headerspkg/usr/lib/modules/${KV_FULL}/build"

	# --- Install kernel modules from binary package ---
	dodir "/lib/modules/${KV_FULL}"
	# Copy module tree (kernel/, modules.order, modules.builtin, etc.)
	local f
	for f in "${binpkg_modules}"/*; do
		local fname="${f##*/}"
		# Skip build/source symlinks from pacman package
		[[ "${fname}" == "build" || "${fname}" == "source" ]] && continue
		# Skip vmlinuz (installed separately to source tree)
		[[ "${fname}" == "vmlinuz" ]] && continue
		# Skip pkgbase (pacman-specific)
		[[ "${fname}" == "pkgbase" ]] && continue
		cp -a "${f}" "${ED}/lib/modules/${KV_FULL}/" || die
	done

	# Create build/source symlinks (kernel-install_pkg_preinst will fix them)
	dosym "../../../src/linux-${KV_FULL}" "/lib/modules/${KV_FULL}/build"
	dosym "../../../src/linux-${KV_FULL}" "/lib/modules/${KV_FULL}/source"

	# --- Install kernel source tree ---
	dodir "${rel_kernel_dir}"

	# Install exact-match headers before overlaying locally prepared build tools.
	cp -p -R "${headers_build}/." "${ED}${rel_kernel_dir}/" || die

	# Install kernel image at the standard dist-kernel location
	insinto "${rel_kernel_dir}/arch/x86/boot"
	newins "${binpkg_modules}/vmlinuz" bzImage

	# Install System.map and .config from headers package
	insinto "${rel_kernel_dir}"
	doins "${headers_build}/System.map"
	doins "${headers_build}/.config"

	# Install vmlinux from headers (for debugging)
	if [[ -f "${headers_build}/vmlinux" ]]; then
		doins "${headers_build}/vmlinux"
	fi

	# --- Install modprep (prepared build tools for out-of-tree modules) ---
	# Strip build artifacts from modprep, then overlay onto source tree
	find "${WORKDIR}/modprep" -type f '(' \
			-name Makefile -o \
			-name '*.[ao]' -o \
			-name '.*' \
		')' -delete || die
	# Keep upstream Kconfig output; local syncconfig rewrites it for this host.
	rm -rf "${WORKDIR}/modprep/include/config" \
		"${WORKDIR}"/modprep/include/generated/{autoconf.h,compile.h,rustc_cfg} || die
	rm -f "${WORKDIR}/modprep/source" 2>/dev/null
	cp -p -R "${WORKDIR}/modprep/." "${ED}${rel_kernel_dir}/" || die

	# --- Set dist-kernel identification ---
	echo "${CATEGORY}/${PF}:${SLOT}" > "${ED}${rel_kernel_dir}/dist-kernel" || die

	# Update timestamps on all modules
	find "${ED}/lib" -name '*.ko' -o -name '*.ko.zst' -exec touch {} + 2>/dev/null || true

	# Modules were already stripped by CachyOS
	dostrip -x /lib/modules
	# Upstream modules are already compressed; an empty compressor run reads stdin.
	if [[ -n $(find "${ED}/lib/modules/${KV_FULL}" -name '*.ko' -print -quit) ]]; then
		kernel-install_compress_modules
	fi

	if use debug; then
		dostrip -x "${rel_kernel_dir}/vmlinux"
	fi
}

pkg_preinst() {
	_cachyos_setup_kv
	kernel-install_pkg_preinst
}

pkg_postinst() {
	_cachyos_setup_kv
	depmod "${KV_FULL}"
	kernel-install_pkg_postinst

	ewarn ""
	ewarn "${PN} is a pre-built CachyOS kernel from CachyOS mirrors."
	ewarn "${PN} is *not* supported by the Gentoo Kernel Project in any way."
	ewarn "Report ebuild and kernel problems to https://github.com/Szowisz/CachyOS-kernels."
	ewarn "Report kernel problems to the CachyOS project, if you sure it's due to upstream."
	ewarn "Do *not* open bugs in Gentoo's bugzilla. Thank you."
	ewarn ""
	ewarn "This kernel is built for x86-64-v3 (requires AVX2)."
	ewarn "If your CPU does not support x86-64-v3, use sys-kernel/cachyos-kernel instead."
	ewarn ""
}

pkg_postrm() {
	_cachyos_setup_kv
	kernel-install_pkg_postrm
}
