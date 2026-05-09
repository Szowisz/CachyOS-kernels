# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

# LLVM support for Clang/LTO builds
LLVM_COMPAT=( {17..22} )

inherit kernel-build toolchain-funcs llvm-r1 optfeature

# CachyOS release number mapping: Gentoo -rN -> CachyOS -N+1
# -r0 (no revision) -> -1, -r1 -> -2, etc.
CACHYOS_PR="$((${PR#r} + 1))"

# CachyOS pre-patched tarball
MY_P="cachyos-$(ver_cut 1-3)-${CACHYOS_PR}"

# Genpatches version - must match K_GENPATCHES_VER in cachyos-sources
# Sync from: sys-kernel/cachyos-sources/cachyos-sources-${PV}.ebuild (K_GENPATCHES_VER)
# Cross-reference: /var/db/repos/gentoo/sys-kernel/gentoo-kernel/gentoo-kernel-${PV}.ebuild (PATCHSET)
GENPATCHES_VER=28

# ZFS commit for kernel-builtin-zfs support
ZFS_COMMIT="1c702dda346a59e05cfd3029569bbb1d5d91c54b"

DESCRIPTION="Linux kernel built with CachyOS patches (BORE, LTO, AutoFDO, BBR3 and more)"
HOMEPAGE="
	https://github.com/CachyOS/linux-cachyos
	https://github.com/Szowisz/CachyOS-kernels
"
SRC_URI="
	https://github.com/CachyOS/linux/releases/download/${MY_P}/${MY_P}.tar.gz
	https://dev.gentoo.org/~mpagano/dist/genpatches/genpatches-$(ver_cut 1-2)-${GENPATCHES_VER}.base.tar.xz
	https://dev.gentoo.org/~mpagano/dist/genpatches/genpatches-$(ver_cut 1-2)-${GENPATCHES_VER}.extras.tar.xz
	kernel-builtin-zfs? (
		https://github.com/cachyos/zfs/archive/${ZFS_COMMIT}.tar.gz
			-> zfs-${ZFS_COMMIT}.tar.gz
	)
"
S="${WORKDIR}/${MY_P}"

LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="
	+bore bmq rt rt-bore eevdf
	deckify hardened kcfi
	+clang +autofdo +propeller
	llvm-lto-thin llvm-lto-full +llvm-lto-thin-dist llvm-lto-none
	kernel-builtin-zfs
	hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_750 +hz_ticks_1000
	+per-gov tickrate_periodic tickrate_idle +tickrate_full +preempt_full preempt_lazy preempt_voluntary preempt_none
	+o3 os debug +bbr3
	+hugepage_always hugepage_madvise
	mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4
	+mnative mzen4
"
REQUIRED_USE="
	^^ ( bore bmq rt rt-bore eevdf hardened )
	propeller? ( !llvm-lto-full )
	autofdo? ( || ( llvm-lto-thin llvm-lto-full llvm-lto-thin-dist ) )
	^^ ( llvm-lto-thin llvm-lto-full llvm-lto-thin-dist llvm-lto-none )
	llvm-lto-thin? ( clang )
	llvm-lto-full? ( clang )
	llvm-lto-thin-dist? ( clang )
	kcfi? ( clang )
	^^ ( hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_750 hz_ticks_1000 )
	^^ ( tickrate_periodic tickrate_idle tickrate_full )
	^^ ( preempt_full preempt_lazy preempt_voluntary preempt_none )
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
	debug? ( dev-util/pahole )
"
PDEPEND="
	>=virtual/dist-kernel-${PV}
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
	local files_dir="${FILESDIR}/${PVR}"

	# --- Apply genpatches (base + extras) ---
	# Genpatches extract into ${WORKDIR}/ as numbered .patch files
	# Exclude kernel version upgrade patches (10xx_linux-*.patch) since
	# the CachyOS tarball already includes the latest point release
	local genpatch genpatch_name genpatch_num
	local genpatch_exclude=""

	# Exclude genpatch that conflicts with BMQ scheduler
	# 1810_sched_proxy_yield_the_donor_task.patch changes current->sched_class
	# which breaks BMQ's patch context for do_sched_yield() and yield_to()
	use bmq && genpatch_exclude+=" 1810"

	# Exclude genpatches that conflict with the hardened patchset:
	# 1510: fs link security defaults conflict with hardened's stricter values
	# 4567: Gentoo Kconfig additions shift line offsets, breaking hardened's hunks
	use hardened && genpatch_exclude+=" 1510 4567"

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
	eapply "${FILESDIR}/6.18.10/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch"

	# Apply scheduler-specific patches and copy config
	if use bore; then
		eapply "${files_dir}/sched/0001-bore-cachy.patch"
		cp "${files_dir}/config-bore" .config || die
	fi

	if use bmq; then
		eapply "${files_dir}/sched/0001-prjc-cachy.patch"
		cp "${files_dir}/config-bmq" .config || die
	fi

	if use eevdf; then
		cp "${files_dir}/config-eevdf" .config || die
	fi

	if use rt; then
		eapply "${files_dir}/misc/0001-rt-i915.patch"
		cp "${files_dir}/config-rt-bore" .config || die
	fi

	if use rt-bore; then
		eapply "${files_dir}/misc/0001-rt-i915.patch"
		eapply "${files_dir}/sched/0001-bore-cachy.patch"
		cp "${files_dir}/config-rt-bore" .config || die
	fi

	if use hardened; then
		eapply "${files_dir}/misc/0001-hardened.patch"
		cp "${files_dir}/config-hardened" .config || die
	fi

	if use deckify; then
		cp "${files_dir}/config-deckify" .config || die
		scripts/config -d RCU_LAZY_DEFAULT_OFF -e AMD_PRIVATE_COLOR || die
	fi

	# Apply user patches (from /etc/portage/patches/)
	eapply_user

	# Set kernel version suffix
	echo "-cachyos" > localversion.20-pkgname || die

	# --- Kernel config modifications ---

	### Selecting CachyOS config
	scripts/config -e CACHY || die

	### Selecting the CPU scheduler
	# CachyOS Scheduler (BORE)
	if use bore || use hardened; then
		scripts/config -e SCHED_BORE || die
	fi

	if use bmq; then
		scripts/config -e SCHED_ALT -e SCHED_BMQ || die
	fi

	if use rt; then
		scripts/config -e PREEMPT_RT || die
	fi

	if use rt-bore; then
		scripts/config -e SCHED_BORE -e PREEMPT_RT || die
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
		scripts/config -e LTO_CLANG_THIN || die
	elif use llvm-lto-thin-dist; then
		scripts/config -e LTO_CLANG_THIN_DIST || die
	elif use llvm-lto-full; then
		scripts/config -e LTO_CLANG_FULL || die
	elif use llvm-lto-none; then
		scripts/config -e LTO_NONE || die
	fi

	if ! use llvm-lto-thin && ! use llvm-lto-full && ! use llvm-lto-thin-dist; then
		scripts/config --set-str DRM_PANIC_SCREEN qr_code -e DRM_PANIC_SCREEN_QR_CODE \
			--set-str DRM_PANIC_SCREEN_QR_CODE_URL "https://panic.archlinux.org/panic_report#" \
			--set-val CONFIG_DRM_PANIC_SCREEN_QR_VERSION 40 || die
	fi

	## LLVM patch
	if use kcfi || use llvm-lto-thin || use llvm-lto-full || use llvm-lto-thin-dist; then
		eapply "${files_dir}/misc/dkms-clang.patch"
	fi

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
		scripts/config -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL_NODEF -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING || die
	fi

	### Select preempt type
	if ! use rt && ! use rt-bore; then
		if use preempt_full; then
			scripts/config -e PREEMPT_DYNAMIC -e PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE || die
		elif use preempt_lazy; then
			scripts/config -e PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -e PREEMPT_LAZY -d PREEMPT_NONE || die
		elif use preempt_voluntary; then
			scripts/config -d PREEMPT_DYNAMIC -d PREEMPT -e PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE || die
		elif use preempt_none; then
			scripts/config -d PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -e PREEMPT_NONE || die
		fi
	fi

	### Enable O3
	if use o3; then
		scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3 || die
	fi

	if use os; then
		scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE -e CONFIG_CC_OPTIMIZE_FOR_SIZE || die
	fi

	if use debug; then
		scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE \
			-d CC_OPTIMIZE_FOR_PERFORMANCE_O3 \
			-e CONFIG_CC_OPTIMIZE_FOR_SIZE \
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
		scripts/config -m TCP_CONG_CUBIC \
			-d DEFAULT_CUBIC \
			-e TCP_CONG_BBR \
			-e DEFAULT_BBR \
			--set-str DEFAULT_TCP_CONG bbr \
			-m NET_SCH_FQ_CODEL \
			-e NET_SCH_FQ \
			-d CONFIG_DEFAULT_FQ_CODEL \
			-e CONFIG_DEFAULT_FQ || die
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

	### Enable USER_NS_UNPRIVILEGED
	scripts/config -e USER_NS || die

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
	ewarn "If you need support, please contact the CachyOS project or the overlay maintainer."
	ewarn "Do *not* open bugs in Gentoo's bugzilla unless you have issues with"
	ewarn "the ebuilds. Thank you."
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
		ewarn "AutoFDO support build way: https://cachyos.org/blog/2411-kernel-autofdo"
		ewarn "Check https://github.com/xz-dev/kernel-autofdo-container as example"
	fi
}

# e80ce8172953b8c199daf6a2850974bb12731ae9
