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

DESCRIPTION="Pre-built CachyOS Linux kernel (BORE, LTO, BBR3 and more)"
HOMEPAGE="
	https://github.com/CachyOS/linux-cachyos
	https://github.com/Szowisz/CachyOS-kernels
"

# Source tarball (shared by all variants, needed for modules_prepare)
SRC_URI="
	https://github.com/CachyOS/linux/releases/download/${MY_P}/${MY_P}.tar.gz
"

# Binary packages per variant (x86_64_v3 only for this version)
# Naming: linux-cachyos[-variant][-lto]-{ver}-{pkgrel}-{arch}.pkg.tar.zst
# Preserve the existing USE semantics even though upstream's bore+lto build
# now uses the unsuffixed linux-cachyos package name.
SRC_URI+="
	bore? (
		lto? ( !gcc? (
			${MIRROR_V3}/linux-cachyos-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		) )
		!lto? ( !gcc? (
			${MIRROR_V3}/linux-cachyos-bore-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-bore-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		) )
		gcc? (
			${MIRROR_V3}/linux-cachyos-gcc-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-gcc-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
	)
	eevdf? (
		lto? (
			${MIRROR_V3}/linux-cachyos-eevdf-lto-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-eevdf-lto-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
		!lto? (
			${MIRROR_V3}/linux-cachyos-eevdf-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-eevdf-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
	)
	rt-bore? (
		lto? (
			${MIRROR_V3}/linux-cachyos-rt-bore-lto-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-rt-bore-lto-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
		!lto? (
			${MIRROR_V3}/linux-cachyos-rt-bore-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-rt-bore-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
	)
	server? (
		lto? (
			${MIRROR_V3}/linux-cachyos-server-lto-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-server-lto-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
		!lto? (
			${MIRROR_V3}/linux-cachyos-server-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-server-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
	)
	deckify? (
		lto? (
			${MIRROR_V3}/linux-cachyos-deckify-lto-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-deckify-lto-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
		!lto? (
			${MIRROR_V3}/linux-cachyos-deckify-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
			${MIRROR_V3}/linux-cachyos-deckify-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst
		)
	)
"

S="${WORKDIR}"

LICENSE="GPL-2"
KEYWORDS="~amd64"
IUSE="bore +eevdf rt-bore server deckify +lto gcc debug"
REQUIRED_USE="
	^^ ( bore eevdf rt-bore server deckify )
	?? ( lto gcc )
	gcc? ( bore )
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
# This determines the kernel release string: {PV}-{PR}-{suffix}
_cachyos_variant_suffix() {
	if use bore; then
		if use lto; then echo "cachyos"
		elif use gcc; then echo "cachyos-gcc"
		else echo "cachyos-bore"
		fi
	elif use eevdf; then
		use lto && echo "cachyos-eevdf-lto" || echo "cachyos-eevdf"
	elif use rt-bore; then
		use lto && echo "cachyos-rt-bore-lto" || echo "cachyos-rt-bore"
	elif use server; then
		use lto && echo "cachyos-server-lto" || echo "cachyos-server"
	elif use deckify; then
		use lto && echo "cachyos-deckify-lto" || echo "cachyos-deckify"
	fi
}

# Compute distfile name for the binary kernel package
_cachyos_bin_distfile() {
	local variant=""
	if use bore; then
		if use lto; then variant=""
		elif use gcc; then variant="-gcc"
		else variant="-bore"
		fi
	elif use eevdf; then
		use lto && variant="-eevdf-lto" || variant="-eevdf"
	elif use rt-bore; then
		use lto && variant="-rt-bore-lto" || variant="-rt-bore"
	elif use server; then
		use lto && variant="-server-lto" || variant="-server"
	elif use deckify; then
		use lto && variant="-deckify-lto" || variant="-deckify"
	fi
	echo "linux-cachyos${variant}-${BINPKG_VER}-x86_64_v3.pkg.tar.zst"
}

# Compute distfile name for the binary headers package
_cachyos_headers_distfile() {
	local variant=""
	if use bore; then
		if use lto; then variant=""
		elif use gcc; then variant="-gcc"
		else variant="-bore"
		fi
	elif use eevdf; then
		use lto && variant="-eevdf-lto" || variant="-eevdf"
	elif use rt-bore; then
		use lto && variant="-rt-bore-lto" || variant="-rt-bore"
	elif use server; then
		use lto && variant="-server-lto" || variant="-server"
	elif use deckify; then
		use lto && variant="-deckify-lto" || variant="-deckify"
	fi
	echo "linux-cachyos${variant}-headers-${BINPKG_VER}-x86_64_v3.pkg.tar.zst"
}

# Set KV_FULL and KV_LOCALVERSION based on USE flags
_cachyos_setup_kv() {
	local suffix=$(_cachyos_variant_suffix)
	KV_LOCALVERSION="-${CACHYOS_PR}-${suffix}"
	KV_FULL="${PV}${KV_LOCALVERSION}"
}

pkg_setup() {
	_cachyos_setup_kv
}

src_unpack() {
	# Unpack the CachyOS kernel source tarball (for modules_prepare)
	unpack "${MY_P}.tar.gz"

	# Unpack the binary kernel package (pacman .pkg.tar.zst format)
	mkdir -p "${WORKDIR}/binpkg" || die
	tar -C "${WORKDIR}/binpkg" -xf "${DISTDIR}/$(_cachyos_bin_distfile)" || die

	# Unpack the binary headers package
	mkdir -p "${WORKDIR}/headerspkg" || die
	tar -C "${WORKDIR}/headerspkg" -xf "${DISTDIR}/$(_cachyos_headers_distfile)" || die
}

src_prepare() {
	_cachyos_setup_kv

	cd "${WORKDIR}/${MY_P}" || die

	# Set localversion files to match the CachyOS binary exactly
	# These determine the kernel release string (uname -r)
	echo "-${CACHYOS_PR}" > localversion.10-pkgrel || die
	echo "-$(_cachyos_variant_suffix)" > localversion.20-pkgname || die

	default
}

src_configure() {
	_cachyos_setup_kv

	# Determine the headers build directory from the binary package
	local headers_build="${WORKDIR}/headerspkg/usr/lib/modules/${KV_FULL}/build"

	if [[ ! -d "${headers_build}" ]]; then
		# Try to auto-detect the module directory name
		local moddir
		moddir=( "${WORKDIR}/headerspkg/usr/lib/modules"/*/ )
		if [[ ${#moddir[@]} -eq 1 && -d "${moddir[0]}/build" ]]; then
			headers_build="${moddir[0]}/build"
			# Update KV_FULL to match what was actually in the package
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

	# Set up toolchain for modules_prepare
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
			'(' -name '.*' -a -not -name '.config' ')' \
		')' -delete || die
	rm -f "${WORKDIR}/modprep/source" 2>/dev/null
	cp -p -R "${WORKDIR}/modprep/." "${ED}${rel_kernel_dir}/" || die

	# --- Set dist-kernel identification ---
	echo "${CATEGORY}/${PF}:${SLOT}" > "${ED}${rel_kernel_dir}/dist-kernel" || die

	# Update timestamps on all modules
	find "${ED}/lib" -name '*.ko' -o -name '*.ko.zst' -exec touch {} + 2>/dev/null || true

	# Modules were already stripped by CachyOS
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
