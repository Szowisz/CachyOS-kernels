# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

KERNEL_IUSE_GENERIC_UKI=1

inherit kernel-install toolchain-funcs

# CachyOS release number mapping: Gentoo -rN -> CachyOS pkgrel
# -r0 (no revision) -> 1, -r1 -> 2, etc.
CACHYOS_PR="$((${PR#r} + 1))"

# CachyOS pre-patched source tarball (needed for modules_prepare)
MY_P="cachyos-$(ver_cut 1-3)-${CACHYOS_PR}"

# Binary package version string: {pkgver}-{pkgrel}
BINPKG_VER="${PV}-${CACHYOS_PR}"

# Mirror base URLs
MIRROR_V3="https://mirror.cachyos.org/repo/x86_64_v3/cachyos-v3"

DESCRIPTION="Pre-built CachyOS Linux LTS kernel"
HOMEPAGE="
	https://github.com/CachyOS/linux-cachyos
	https://github.com/Szowisz/CachyOS-kernels
"

# Source tarball (shared by all variants, needed for modules_prepare)
SRC_URI="
	https://github.com/CachyOS/linux/releases/download/${MY_P}/${MY_P}.tar.gz
"

# Binary packages per variant (x86_64_v3 only for this version)
# 6.18.28 LTS only: linux-cachyos-lts (no scheduler variants, no lto)
SRC_URI+="
	lts? (
		${MIRROR_V3}/linux-cachyos-lts-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		${MIRROR_V3}/linux-cachyos-lts-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
	)
"

S="${WORKDIR}"

LICENSE="GPL-2"
KEYWORDS="~amd64"
IUSE="lts debug"
REQUIRED_USE="
	lts
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
"
PDEPEND="
	>=virtual/dist-kernel-${PV}
"

QA_PREBUILT='*'

_cachyos_variant_suffix() {
	echo "cachyos-lts"
}

_cachyos_bin_distfile() {
	echo "linux-cachyos-lts-${BINPKG_VER}-x86_64_v3.pkg.tar.zst"
}

_cachyos_headers_distfile() {
	echo "linux-cachyos-lts-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst"
}

_cachyos_setup_kv() {
	local suffix=$(_cachyos_variant_suffix)
	KV_LOCALVERSION="-${CACHYOS_PR}-${suffix}"
	KV_FULL="${PV}${KV_LOCALVERSION}"
}

pkg_setup() {
	_cachyos_setup_kv
}

src_unpack() {
	unpack "${MY_P}.tar.gz"

	mkdir -p "${WORKDIR}/binpkg" || die
	tar -C "${WORKDIR}/binpkg" -xf "${DISTDIR}/$(_cachyos_bin_distfile)" || die

	mkdir -p "${WORKDIR}/headerspkg" || die
	tar -C "${WORKDIR}/headerspkg" -xf "${DISTDIR}/$(_cachyos_headers_distfile)" || die
}

src_prepare() {
	_cachyos_setup_kv

	cd "${WORKDIR}/${MY_P}" || die

	echo "-${CACHYOS_PR}" > localversion.10-pkgrel || die
	echo "-$(_cachyos_variant_suffix)" > localversion.20-pkgname || die

	default
}

src_configure() {
	_cachyos_setup_kv

	local headers_build="${WORKDIR}/headerspkg/usr/lib/modules/${KV_FULL}/build"

	if [[ ! -d "${headers_build}" ]]; then
		local moddir
		moddir=( "${WORKDIR}/headerspkg/usr/lib/modules"/*/ )
		if [[ ${#moddir[@]} -eq 1 && -d "${moddir[0]}/build" ]]; then
			headers_build="${moddir[0]}/build"
			local detected_kv="${moddir[0]%/}"
			detected_kv="${detected_kv##*/}"
			ewarn "Auto-detected kernel version: ${detected_kv}"
			ewarn "Expected: ${KV_FULL}"
			KV_FULL="${detected_kv}"
			KV_LOCALVERSION="${KV_FULL#${PV}}"
		else
			die "Cannot find headers build directory. Expected: ${headers_build}"
		fi
	fi

	local HOSTLD="$(tc-getBUILD_LD)"
	if type -P "${HOSTLD}.bfd" &>/dev/null; then
		HOSTLD+=.bfd
	fi
	local LD="$(tc-getLD)"
	if type -P "${LD}.bfd" &>/dev/null; then
		LD+=.bfd
	fi

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

	# LTS kernel is not LTO, use GCC toolchain
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

	mkdir "${WORKDIR}/modprep" || die
	cp "${headers_build}/.config" "${WORKDIR}/modprep/" || die

	emake -C "${WORKDIR}/${MY_P}" "${makeargs[@]}" modules_prepare
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

	dodir "/lib/modules/${KV_FULL}"
	local f
	for f in "${binpkg_modules}"/*; do
		local fname="${f##*/}"
		[[ "${fname}" == "build" || "${fname}" == "source" ]] && continue
		[[ "${fname}" == "vmlinuz" ]] && continue
		[[ "${fname}" == "pkgbase" ]] && continue
		cp -a "${f}" "${ED}/lib/modules/${KV_FULL}/" || die
	done

	dosym "../../../src/linux-${KV_FULL}" "/lib/modules/${KV_FULL}/build"
	dosym "../../../src/linux-${KV_FULL}" "/lib/modules/${KV_FULL}/source"

	dodir "${rel_kernel_dir}"

	insinto "${rel_kernel_dir}/arch/x86/boot"
	newins "${binpkg_modules}/vmlinuz" bzImage

	insinto "${rel_kernel_dir}"
	doins "${headers_build}/System.map"
	doins "${headers_build}/.config"

	if [[ -f "${headers_build}/vmlinux" ]]; then
		doins "${headers_build}/vmlinux"
	fi

	find "${WORKDIR}/modprep" -type f '(' \
			-name Makefile -o \
			-name '*.[ao]' -o \
			'(' -name '.*' -a -not -name '.config' ')' \
		')' -delete || die
	rm -f "${WORKDIR}/modprep/source" 2>/dev/null
	cp -p -R "${WORKDIR}/modprep/." "${ED}${rel_kernel_dir}/" || die

	echo "${CATEGORY}/${PF}:${SLOT}" > "${ED}${rel_kernel_dir}/dist-kernel" || die

	find "${ED}/lib" -name '*.ko' -o -name '*.ko.zst' -exec touch {} + 2>/dev/null || true

	dostrip -x /lib/modules
	kernel-install_compress_modules

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
	ewarn "It is *not* supported by the Gentoo Kernel Project or CachyOS."
	ewarn "If you need support, contact the overlay maintainer."
	ewarn "Do *not* open bugs in Gentoo's bugzilla."
	ewarn ""
	ewarn "This kernel is built for x86-64-v3 (requires AVX2)."
	ewarn "If your CPU does not support x86-64-v3, use sys-kernel/cachyos-kernel instead."
	ewarn ""
}

pkg_postrm() {
	_cachyos_setup_kv
	kernel-install_pkg_postrm
}
