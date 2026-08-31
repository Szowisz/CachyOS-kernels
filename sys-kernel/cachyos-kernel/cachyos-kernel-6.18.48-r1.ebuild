# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

# LLVM support for Clang/LTO builds
LLVM_COMPAT=( {17..22} )

inherit kernel-build toolchain-funcs llvm-r1 optfeature

# Pin patch and config inputs so Manifest checks cover exact upstream bytes.
CACHYOS_PATCHES_COMMIT="a40b85abdcb9f4ba653e2e1ea89d3d1f0cf563ba"
CACHYOS_CONFIGS_COMMIT="b165d04e2c7ccfa5f5448957ccb9d61754f20e6e"
CACHYOS_PR="2"

# CachyOS pre-patched tarball
MY_P="cachyos-$(ver_cut 1-3)-${CACHYOS_PR}"

# Gentoo genpatches for the 6.18 series.
GENPATCHES_VER=55

# ZFS commit for kernel-builtin-zfs support
ZFS_COMMIT="71a9f9578616a90c3c14bb59629fb4d31bfd68d1"
CACHYOS_SERIES="$(ver_cut 1-2)"
CACHYOS_PATCH_URI="https://github.com/CachyOS/kernel-patches/raw/${CACHYOS_PATCHES_COMMIT}/${CACHYOS_SERIES}"
CACHYOS_CONFIG_URI="https://github.com/CachyOS/linux-cachyos/raw/${CACHYOS_CONFIGS_COMMIT}"
CACHYOS_PATCH_PREFIX="cachyos-kernel-patches-${CACHYOS_PATCHES_COMMIT}-${CACHYOS_SERIES}"
CACHYOS_CONFIG_PREFIX="linux-cachyos-lts-${CACHYOS_CONFIGS_COMMIT}"

DESCRIPTION="Linux kernel built with CachyOS patches (BORE, LTO, AutoFDO, BBR3 and more)"
HOMEPAGE="
	https://github.com/CachyOS/linux-cachyos
	https://github.com/Szowisz/CachyOS-kernels
"
SRC_URI="
	https://github.com/CachyOS/linux/releases/download/${MY_P}/${MY_P}.tar.gz
	https://dev.gentoo.org/~mpagano/dist/genpatches/genpatches-$(ver_cut 1-2)-${GENPATCHES_VER}.base.tar.xz
	https://dev.gentoo.org/~mpagano/dist/genpatches/genpatches-$(ver_cut 1-2)-${GENPATCHES_VER}.extras.tar.xz
	${CACHYOS_CONFIG_URI}/linux-cachyos-lts/config
		-> ${CACHYOS_CONFIG_PREFIX}-config
	rt? (
		${CACHYOS_PATCH_URI}/misc/0001-rt-i915.patch
			-> ${CACHYOS_PATCH_PREFIX}-rt-i915.patch
	)
	${CACHYOS_PATCH_URI}/misc/dkms-clang.patch
		-> ${CACHYOS_PATCH_PREFIX}-dkms-clang.patch
	kernel-builtin-zfs? (
		https://github.com/cachyos/zfs/archive/${ZFS_COMMIT}.tar.gz
			-> zfs-${ZFS_COMMIT}.tar.gz
	)
"
S="${WORKDIR}/${MY_P}"

LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="
	rt +eevdf
	kcfi
	+clang autofdo propeller
	llvm-lto-thin llvm-lto-full llvm-lto-thin-dist +llvm-lto-none
	kernel-builtin-zfs
	hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_750 +hz_ticks_1000
	+per-gov tickrate_periodic tickrate_idle +tickrate_full +preempt_full preempt_lazy
	+o3 os debug +bbr3
	+hugepage_always hugepage_madvise
	mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4
	+mnative mzen4
"
# 6.18.48-2 exact-version apply-test exclusions (prepare failed):
# - bore / rt-bore / hardened: 0001-bore-cachy.patch fails at kernel/sched/fair.c hunk 23
#   (check_preempt_wakeup_fair / PREEMPT_SHORT_BORE vs 6.18.48 scheduler changes)
# - bmq / bmq-lfbmq: 0001-prjc-cachy{,-lfbmq}.patch fail at kernel/sched/syscalls.c hunk 4
#   even with genpatch 1810 excluded
# - deckify: 0001-handheld.patch fails at drivers/input/joystick/xpad.c hunks 1-2
# Other 6.18 kernel-patches families not exposed here:
# - MuQSS has no 6.18 patch
# - AUFS merge is not in any official PKGBUILD source array
# - clang-polly, nap-governor, reflex-governor, and standalone poc-selector
#   are unused by linux-cachyos-lts and unvalidated on cachyos-6.18.48-2
# - NVIDIA OOT and r8125 stay as separate packages
# - vanilla non-Cachy BORE/PRJC and sched-dev copies are unused duplicates
REQUIRED_USE="
	^^ ( rt eevdf )
	propeller? ( clang !llvm-lto-full !llvm-lto-none )
	autofdo? ( || ( llvm-lto-thin llvm-lto-full llvm-lto-thin-dist ) )
	^^ ( llvm-lto-thin llvm-lto-full llvm-lto-thin-dist llvm-lto-none )
	llvm-lto-thin? ( clang )
	llvm-lto-full? ( clang )
	llvm-lto-thin-dist? ( clang )
	kcfi? ( clang )
	^^ ( hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_750 hz_ticks_1000 )
	^^ ( tickrate_periodic tickrate_idle tickrate_full )
	^^ ( preempt_full preempt_lazy )
	?? ( o3 os debug )
	^^ ( hugepage_always hugepage_madvise )
	?? ( mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4 mnative mzen4 )
"

RDEPEND="
	!sys-kernel/cachyos-sources:${SLOT}
	autofdo? ( dev-util/perf[libpfm] )
"
BDEPEND="
	clang? (
		$(llvm_gen_dep '
			llvm-core/llvm:${LLVM_SLOT}
			llvm-core/clang:${LLVM_SLOT}
			llvm-core/lld:${LLVM_SLOT}
		')
	)
	dev-util/pahole
"
PDEPEND="
	>=virtual/dist-kernel-${PV}_p${PR#r}
"

QA_FLAGS_IGNORED="
	usr/src/linux-.*/scripts/gcc-plugins/.*.so
	usr/src/linux-.*/vmlinux
	usr/src/linux-.*/arch/powerpc/kernel/vdso.*/vdso.*.so.dbg
"

_set_hztick_rate() {
	local _HZ_ticks=$1
	if [[ $_HZ_ticks == 300 ]]; then
		scripts/config -e HZ_300 --set-val HZ 300 || die
	else
		scripts/config -d HZ_300 -e "HZ_${_HZ_ticks}" --set-val HZ "${_HZ_ticks}" || die
	fi
}

pkg_setup() {
	if use clang && ! tc-is-clang; then
		llvm-r1_pkg_setup

		export LLVM=1
		export LLVM_IAS=1
		export CC=clang
		export LD=ld.lld
		export AR=llvm-ar
		export NM=llvm-nm
		export OBJCOPY=llvm-objcopy
		export OBJDUMP=llvm-objdump
		export READELF=llvm-readelf
		export STRIP=llvm-strip
	else
		tc-export CC CXX
	fi

	kernel-build_pkg_setup
}

src_unpack() {
	default

	# Unpack genpatches
	# (kernel-build does not use kernel-2's UNIPATCH mechanism)

	# Unpack ZFS if requested
	if use kernel-builtin-zfs; then
		unpack "zfs-${ZFS_COMMIT}.tar.gz"
		mv "zfs-${ZFS_COMMIT}" "${S}/zfs" || die
		cp "${FILESDIR}/kernel-build.sh" "${S}/" || die
	fi
}

src_prepare() {
	local patches_prefix="${DISTDIR}/${CACHYOS_PATCH_PREFIX}"
	local configs_prefix="${DISTDIR}/${CACHYOS_CONFIG_PREFIX}"

	# --- Apply genpatches (base + extras) ---
	# Genpatches extract into ${WORKDIR}/ as numbered .patch files
	# Exclude kernel version upgrade patches (10xx_linux-*.patch) since
	# the CachyOS tarball already includes the latest point release
	local genpatch genpatch_name genpatch_num
	local genpatch_exclude=""

	# The CachyOS pre-patched tarball already contains genpatch 2700.
	genpatch_exclude="2700"

	for genpatch in "${WORKDIR}"/*.patch; do
		[[ -f "${genpatch}" ]] || continue
		genpatch_name=$(basename "${genpatch}")
		genpatch_num=${genpatch_name%%_*}
		local skip=false

		# Skip kernel upgrade patches (10xx series)
		[[ ${genpatch_num} == 10* ]] && skip=true

		# Skip excluded genpatches
		local exclude
		for exclude in ${genpatch_exclude}; do
			[[ ${genpatch_name} == ${exclude}* ]] && skip=true
		done

		if ! ${skip}; then
			eapply "${genpatch}"
		fi
	done

	# --- Apply CachyOS-specific patches ---

	# Fix AutoFDO/Propeller support for LTO_CLANG_THIN_DIST
	eapply "${FILESDIR}/6.19.0/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch"

	if use rt; then
		eapply "${patches_prefix}-rt-i915.patch"
	fi

	cp "${configs_prefix}-config" .config || die

	if use clang; then
		eapply "${patches_prefix}-dkms-clang.patch"
	fi

	# Apply user patches (from /etc/portage/patches/)
	eapply_user

	# --- Kernel config modifications ---

	scripts/config -e CACHY || die

	if use rt; then
		scripts/config -e PREEMPT_RT || die
	fi

	### Enable KCFI
	if use kcfi; then
		scripts/config -e ARCH_SUPPORTS_CFI_CLANG -e CFI -e CFI_CLANG -e CFI_AUTO_DEFAULT || die
	else
		# https://github.com/openzfs/zfs/issues/15911
		scripts/config -d CFI -d CFI_CLANG -e CFI_PERMISSIVE || die
	fi

	### Select LLVM level
	if use llvm-lto-thin; then
		scripts/config -d LTO_NONE -d LTO_CLANG_FULL -d LTO_CLANG_THIN_DIST \
			-e LTO_CLANG_THIN || die
	elif use llvm-lto-thin-dist; then
		scripts/config -d LTO_NONE -d LTO_CLANG_FULL -d LTO_CLANG_THIN \
			-e LTO_CLANG_THIN_DIST || die
	elif use llvm-lto-full; then
		scripts/config -d LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_THIN_DIST \
			-e LTO_CLANG_FULL || die
	elif use llvm-lto-none; then
		scripts/config -d LTO_CLANG_FULL -d LTO_CLANG_THIN -d LTO_CLANG_THIN_DIST \
			-e LTO_NONE || die
	fi

	if use llvm-lto-none; then
		scripts/config --set-str DRM_PANIC_SCREEN qr_code -e DRM_PANIC_SCREEN_QR_CODE \
			--set-str DRM_PANIC_SCREEN_QR_CODE_URL "https://panic.archlinux.org/panic_report#" \
			--set-val DRM_PANIC_SCREEN_QR_VERSION 40 || die
	fi

	## LLVM patch is applied with the other source patches above.

	### Select tick rate
	if use hz_ticks_100; then
		_set_hztick_rate 100
	elif use hz_ticks_250; then
		_set_hztick_rate 250
	elif use hz_ticks_300; then
		_set_hztick_rate 300
	elif use hz_ticks_500; then
		_set_hztick_rate 500
	elif use hz_ticks_600; then
		_set_hztick_rate 600
	elif use hz_ticks_750; then
		_set_hztick_rate 750
	elif use hz_ticks_1000; then
		_set_hztick_rate 1000
	else
		die "Invalid HZ_TICKS use flag. Please select a valid option."
	fi

	### Select performance governor
	if use per-gov; then
		scripts/config -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL -e CPU_FREQ_DEFAULT_GOV_PERFORMANCE || die
	fi

	### Select tick type
	if use tickrate_periodic; then
		scripts/config -d NO_HZ_IDLE -d NO_HZ_FULL -d NO_HZ -d NO_HZ_COMMON -e HZ_PERIODIC || die
	fi

	if use tickrate_idle; then
		scripts/config -d HZ_PERIODIC -d NO_HZ_FULL -e NO_HZ_IDLE -e NO_HZ -e NO_HZ_COMMON || die
	fi

	if use tickrate_full; then
		scripts/config \
			-d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE \
			-e NO_HZ_FULL_NODEF -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON \
			-e CONTEXT_TRACKING || die
	fi

	### Select preempt type
	if ! use rt; then
		scripts/config -e PREEMPT_DYNAMIC || die
		if use preempt_full; then
			scripts/config -e PREEMPT -d PREEMPT_LAZY || die
		elif use preempt_lazy; then
			scripts/config -d PREEMPT -e PREEMPT_LAZY || die
		fi
	fi

	### Select compiler optimization
	if use o3; then
		scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3 || die
	elif use os; then
		scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_SIZE || die
	elif use debug; then
		scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE \
			-d CC_OPTIMIZE_FOR_PERFORMANCE_O3 \
			-e CC_OPTIMIZE_FOR_SIZE \
			-d SLUB_DEBUG \
			-d PM_DEBUG \
			-d PM_ADVANCED_DEBUG \
			-d PM_SLEEP_DEBUG \
			-d ACPI_DEBUG \
			-d LATENCYTOP \
			-d SCHED_DEBUG \
			-d DEBUG_PREEMPT || die
	fi

	### Enable BBR3
	if use bbr3; then
		# Upstream linux-cachyos `_tcp_bbr3` still enables vanilla BBR.
		# Enable real BBR3 as default, keep vanilla BBR as a module so both
		# are not built into vmlinux (duplicate tcp_bbr_check_kfunc_ids
		# BTF set, Szowisz/CachyOS-kernels#53).
		scripts/config -m TCP_CONG_CUBIC \
			-d DEFAULT_CUBIC \
			-m TCP_CONG_BBR \
			-d DEFAULT_BBR \
			-e TCP_CONG_BBR3 \
			-e DEFAULT_BBR3 \
			--set-str DEFAULT_TCP_CONG bbr3 \
			-m NET_SCH_FQ_CODEL \
			-e NET_SCH_FQ \
			-d DEFAULT_FQ_CODEL \
			-e DEFAULT_FQ || die
	fi

	### Select THP
	if use hugepage_always; then
		scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS || die
	fi

	if use hugepage_madvise; then
		scripts/config -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE || die
	fi

	### Select CPU optimization
	march_list=(mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4 mnative mzen4)
	march_found=false
	for MMARCH in "${march_list[@]}"; do
		if use "${MMARCH}"; then
			MARCH_TRIMMED=${MMARCH:1}
			MARCH=$(echo "$MARCH_TRIMMED" | tr '[:lower:]' '[:upper:]')
			case "$MARCH" in
			GENERIC_V[1-4])
				scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU \
					--set-val X86_64_VERSION "${MARCH//GENERIC_V/}" || die
				;;
			ZEN4)
				scripts/config -d GENERIC_CPU -e MZEN4 -d X86_NATIVE_CPU || die
				;;
			NATIVE)
				scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU || die
				;;
			esac
			march_found=true
			break
		fi
	done
	if [ "$march_found" = false ]; then
		scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU || die
	fi

	### Enable Clang AutoFDO
	if use autofdo; then
		scripts/config -e AUTOFDO_CLANG || die
	fi
	### Propeller Optimization
	if use propeller; then
		scripts/config -e PROPELLER_CLANG || die
	fi

	### Change hostname
	scripts/config --set-str DEFAULT_HOSTNAME "gentoo" || die

	# Gentoo/OpenRC: restore upstream default console loglevel (CachyOS defaults to 4 for silent systemd boot) #41
	scripts/config --set-val CONSOLE_LOGLEVEL_DEFAULT 7 || die

	### Set LOCALVERSION for dist-kernel identification
	local myversion="-cachyos-dist"
	echo "CONFIG_LOCALVERSION=\"${myversion}\"" > "${T}"/version.config || die

	# Ensure modprobe path is correct
	echo 'CONFIG_MODPROBE_PATH="/sbin/modprobe"' > "${T}"/modprobe.config || die

	# --- Finalize config via kernel-build merge ---
	local merge_configs=(
		"${T}"/version.config
		"${T}"/modprobe.config
	)

	kernel-build_merge_configs "${merge_configs[@]}"
}

pkg_postinst() {
	kernel-build_pkg_postinst

	ewarn ""
	ewarn "${PN} is *not* supported by the Gentoo Kernel Project in any way."
	ewarn "Report ebuild and kernel problems to https://github.com/Szowisz/CachyOS-kernels."
	ewarn "Report kernel problems to the CachyOS project, if you sure it's due to upstream."
	ewarn "Do *not* open bugs in Gentoo's bugzilla. Thank you."
	ewarn ""

	if use mnative; then
		ewarn "USE=mnative builds the kernel with -march=native, which optimizes for your"
		ewarn "specific CPU. Binary packages built this way are NOT portable to other machines."
		ewarn "Use USE=mgeneric_v3 or similar for portable builds."
	fi

	optfeature "userspace KSM helper" sys-process/uksmd
	optfeature "NVIDIA opensource module" "x11-drivers/nvidia-drivers[kernel-open]"
	optfeature "NVIDIA module" x11-drivers/nvidia-drivers
	optfeature "Realtek RTL8125 2.5GbE driver" net-misc/r8125
	optfeature "ZFS support" sys-fs/zfs
	optfeature "sched_ext schedulers" sys-kernel/scx-loader

	if use kernel-builtin-zfs; then
		ewarn "WARNING: You are using kernel-builtin-zfs USE flag."
		ewarn "It is STRONGLY RECOMMENDED to use sys-fs/zfs instead of building ZFS into the kernel."
		ewarn "sys-fs/zfs provides better compatibility and easier updates."
	fi
	if use autofdo || use propeller; then
		ewarn "AutoFDO/Propeller are enabled in Kconfig, but they only apply profile-guided"
		ewarn "optimization when you pass a profile at build time:"
		ewarn "  AutoFDO:   CLANG_AUTOFDO_PROFILE=/path/to/profile.afdo"
		ewarn "  Propeller: CLANG_PROPELLER_PROFILE_PREFIX=/path/to/propeller"
		ewarn "Without a profile, CONFIG_PROPELLER_CLANG still adds"
		ewarn "-fbasic-block-address-map / --lto-basic-block-address-map (codegen change, no gain)."
		ewarn "Guide: https://cachyos.org/blog/2411-kernel-autofdo"
		ewarn "Example: https://github.com/xz-dev/kernel-autofdo-container"
	fi
}
