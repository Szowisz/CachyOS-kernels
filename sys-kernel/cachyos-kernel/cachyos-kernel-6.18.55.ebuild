# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

# LLVM support for Clang/LTO builds
LLVM_COMPAT=( {17..23} )
LLVM_OPTIONAL=1

inherit kernel-build toolchain-funcs llvm-r2 optfeature

# Pin patch, config, and downstream rebase inputs so Manifest checks cover
# exact immutable GitHub bytes.
CACHYOS_PATCHES_COMMIT="a8efcb97a509c3d36f839451dacb896ab48581c5"
CACHYOS_CONFIGS_COMMIT="ee39638ff003ef2def73671ec1677d48218e7c03"
CACHYOS_PR="$(( ${PR#r} + 1 ))"

# CachyOS pre-patched tarball
MY_P="cachyos-$(ver_cut 1-3)-${CACHYOS_PR}"

# Gentoo genpatches for the 6.18 series.
GENPATCHES_VER=63

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
	bore? (
		${CACHYOS_PATCH_URI}/sched/0001-bore-cachy.patch
			-> ${CACHYOS_PATCH_PREFIX}-bore.patch
	)
	bore-dev? (
		${CACHYOS_PATCH_URI}/sched-dev/0001-bore-cachy.patch
			-> ${CACHYOS_PATCH_PREFIX}-bore-dev.patch
	)
	bmq? (
		${CACHYOS_PATCH_URI}/sched/0001-prjc-cachy.patch
			-> ${CACHYOS_PATCH_PREFIX}-prjc.patch
	)
	pds? (
		${CACHYOS_PATCH_URI}/sched/0001-prjc-cachy.patch
			-> ${CACHYOS_PATCH_PREFIX}-prjc.patch
	)
	bmq-lfbmq? (
		${CACHYOS_PATCH_URI}/sched/0001-prjc-cachy-lfbmq.patch
			-> ${CACHYOS_PATCH_PREFIX}-prjc-lfbmq.patch
	)
	cachyos-hardened? (
		${CACHYOS_PATCH_URI}/sched/0001-bore-cachy.patch
			-> ${CACHYOS_PATCH_PREFIX}-bore.patch
		${CACHYOS_PATCH_URI}/misc/0001-hardened.patch
			-> ${CACHYOS_PATCH_PREFIX}-hardened.patch
	)
	rt? (
		${CACHYOS_PATCH_URI}/misc/0001-rt-i915.patch
			-> ${CACHYOS_PATCH_PREFIX}-rt-i915.patch
	)
	rt-bore? (
		${CACHYOS_PATCH_URI}/sched/0001-bore-cachy.patch
			-> ${CACHYOS_PATCH_PREFIX}-bore.patch
		${CACHYOS_PATCH_URI}/misc/0001-rt-i915.patch
			-> ${CACHYOS_PATCH_PREFIX}-rt-i915.patch
	)
	handheld? (
		${CACHYOS_PATCH_URI}/misc/0001-handheld.patch
			-> ${CACHYOS_PATCH_PREFIX}-handheld.patch
	)
	acpi-call? (
		${CACHYOS_PATCH_URI}/misc/0001-acpi-call.patch
			-> ${CACHYOS_PATCH_PREFIX}-acpi-call.patch
	)
	aufs? (
		${CACHYOS_PATCH_URI}/misc/0001-aufs-6.18-merge-v20251208.patch
			-> ${CACHYOS_PATCH_PREFIX}-aufs.patch
	)
	poc-selector? (
		${CACHYOS_PATCH_URI}/misc/poc-selector.patch
			-> ${CACHYOS_PATCH_PREFIX}-poc-selector.patch
	)
	governor-nap? (
		${CACHYOS_PATCH_URI}/misc/nap-governor.patch
			-> ${CACHYOS_PATCH_PREFIX}-nap-governor.patch
	)
	governor-reflex? (
		${CACHYOS_PATCH_URI}/misc/reflex-governor.patch
			-> ${CACHYOS_PATCH_PREFIX}-reflex-governor.patch
	)
	clang-polly? (
		${CACHYOS_PATCH_URI}/misc/0001-clang-polly.patch
			-> ${CACHYOS_PATCH_PREFIX}-clang-polly.patch
	)
	${CACHYOS_PATCH_URI}/misc/dkms-clang.patch
		-> ${CACHYOS_PATCH_PREFIX}-dkms-clang.patch
	sched-ext-peek? (
		https://github.com/CachyOS/linux/commit/b99db259aa4e75b3051e0b4ea464c08700829d3b.patch
			-> cachyos-sched-ext-b99db259aa4e75b3051e0b4ea464c08700829d3b.patch
		https://github.com/CachyOS/linux/commit/83659f4458c702385efc657ff678cdcec74d7342.patch
			-> cachyos-sched-ext-83659f4458c702385efc657ff678cdcec74d7342.patch
		https://github.com/CachyOS/linux/commit/2f15c2b511c5322cefafbcd49ab496eeaed9c045.patch
			-> cachyos-sched-ext-2f15c2b511c5322cefafbcd49ab496eeaed9c045.patch
		https://github.com/CachyOS/linux/commit/f853a289756a2d3c6addd17dbe40c24b95082ad0.patch
			-> cachyos-sched-ext-f853a289756a2d3c6addd17dbe40c24b95082ad0.patch
	)
	kernel-builtin-zfs? (
		https://github.com/cachyos/zfs/archive/${ZFS_COMMIT}.tar.gz
			-> zfs-${ZFS_COMMIT}.tar.gz
	)
"
S="${WORKDIR}/${MY_P}"

LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="
	bore bore-dev bmq pds bmq-lfbmq cachyos-hardened rt rt-bore +eevdf
	sched-ext-peek
	kcfi server clang-polly handheld acpi-call aufs poc-selector governor-nap governor-reflex
	+clang autofdo propeller
	llvm-lto-thin llvm-lto-full llvm-lto-thin-dist +llvm-lto-none
	+adios adios-default +v4l2loopback +vhba +apple-t2 amd-private-color
	+asus-armoury +asus-ally +asus-wmi-legacy +unprivileged-userns
	+anon-min-protection +clean-low-protection +clean-min-protection
	kernel-builtin-zfs
	hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_750 +hz_ticks_1000
	+per-gov tickrate_periodic tickrate_idle +tickrate_full +preempt_full preempt_lazy
	+o3 os debug +bbr3
	+hugepage_always hugepage_madvise
	mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4
	+mnative mzen4
"

# The release tarball contains neither BORE nor PRJC; config symbols alone
# do not install a scheduler. Rebase the pinned scheduler patches onto the
# stable kernel's PID lifetime and fair-scheduler backports.
# LTS keeps EEVDF as its default; optional patches never affect that path.
REQUIRED_USE="
	^^ ( bore bore-dev bmq pds bmq-lfbmq cachyos-hardened rt rt-bore eevdf )
	sched-ext-peek? ( !bmq !pds !bmq-lfbmq )
	poc-selector? ( !bmq !pds !bmq-lfbmq )
	governor-reflex? ( !bmq !pds !bmq-lfbmq )
	adios-default? ( adios )
	cachyos-hardened? ( !autofdo !propeller llvm-lto-none )
	propeller? ( clang !llvm-lto-full !llvm-lto-none )
	clang-polly? ( clang !llvm_slot_17 !llvm_slot_18 !llvm_slot_19 )
	clang? ( ${LLVM_REQUIRED_USE} )
	autofdo? ( || ( llvm-lto-thin llvm-lto-full llvm-lto-thin-dist ) )
	kernel-builtin-zfs? ( !kcfi )
	^^ ( llvm-lto-thin llvm-lto-full llvm-lto-thin-dist llvm-lto-none )
	llvm-lto-thin? ( clang )
	llvm-lto-full? ( clang )
	llvm-lto-thin-dist? ( clang )
	kcfi? ( clang )
	^^ ( hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_750 hz_ticks_1000 )
	^^ ( tickrate_periodic tickrate_idle tickrate_full )
	^^ ( preempt_full preempt_lazy )
	?? ( o3 os debug )
	?? ( hugepage_always hugepage_madvise )
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
	clang-polly? (
		llvm_slot_20? ( llvm-core/polly:20 )
		llvm_slot_21? ( llvm-core/polly:21 )
		llvm_slot_22? ( llvm-core/polly:22 )
		llvm_slot_23? ( llvm-core/polly:23 )
	)
	dev-util/pahole
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
	if use clang; then
		llvm-r2_pkg_setup
		local llvm_bindir
		llvm_bindir="$(get_llvm_prefix -b)/bin"

		export LLVM=1
		export LLVM_IAS=1
		export CC="${llvm_bindir}/clang"
		export CXX="${llvm_bindir}/clang++"
		export LD="${llvm_bindir}/ld.lld"
		export AR="${llvm_bindir}/llvm-ar"
		export NM="${llvm_bindir}/llvm-nm"
		export OBJCOPY="${llvm_bindir}/llvm-objcopy"
		export OBJDUMP="${llvm_bindir}/llvm-objdump"
		export READELF="${llvm_bindir}/llvm-readelf"
		export STRIP="${llvm_bindir}/llvm-strip"
		if use clang-polly; then
			# The upstream patch loads LLVMPolly.so by name.
			export LD_LIBRARY_PATH="$(get_llvm_prefix -b)/$(get_libdir)${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
		fi
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

	if use bore-dev; then
		eapply --fuzz=0 -- "${patches_prefix}-bore-dev.patch"
	elif use bore || use rt-bore || use cachyos-hardened; then
		cp "${patches_prefix}-bore.patch" "${T}/bore.patch" || die
		eapply --fuzz=0 -d "${T}" -- "${FILESDIR}/cachyos-sources-6.18.55-bore-rebase.patch"
		eapply --fuzz=0 -- "${T}/bore.patch"
	elif use bmq || use pds || use bmq-lfbmq; then
		local prjc=prjc
		use bmq-lfbmq && prjc=prjc-lfbmq
		cp "${patches_prefix}-${prjc}.patch" "${T}/${prjc}.patch" || die
		eapply --fuzz=0 -d "${T}" -- "${FILESDIR}/cachyos-sources-6.18.55-${prjc}-rebase.patch"
		eapply --fuzz=0 -- "${T}/${prjc}.patch"
	fi

	if use sched-ext-peek; then
		eapply --fuzz=0 -- "${DISTDIR}/cachyos-sched-ext-b99db259aa4e75b3051e0b4ea464c08700829d3b.patch"
		cp "${DISTDIR}/cachyos-sched-ext-83659f4458c702385efc657ff678cdcec74d7342.patch" "${T}/peek.patch" || die
		eapply --fuzz=0 -d "${T}" -- "${FILESDIR}/6.18.55-sched-ext-peek-rebase.patch"
		eapply --fuzz=0 -- "${T}/peek.patch"
		eapply --fuzz=0 -- "${DISTDIR}/cachyos-sched-ext-2f15c2b511c5322cefafbcd49ab496eeaed9c045.patch"
		eapply --fuzz=0 -- "${DISTDIR}/cachyos-sched-ext-f853a289756a2d3c6addd17dbe40c24b95082ad0.patch"
	fi

	if use handheld; then
		cp "${patches_prefix}-handheld.patch" "${T}/handheld.patch" || die
		eapply --fuzz=0 -d "${T}" -- "${FILESDIR}/cachyos-sources-6.18.55-handheld-rebase.patch"
		eapply "${T}/handheld.patch"
	fi

	local feature
	for feature in acpi-call aufs poc-selector clang-polly; do
		use "${feature}" && eapply "${patches_prefix}-${feature}.patch"
	done
	use governor-nap && eapply "${patches_prefix}-nap-governor.patch"
	use governor-reflex && eapply "${patches_prefix}-reflex-governor.patch"

	if use cachyos-hardened; then
		cp "${patches_prefix}-hardened.patch" "${T}/hardened.patch" || die
		eapply --fuzz=0 -d "${T}" -- "${FILESDIR}/cachyos-sources-6.18.55-hardened-rebase.patch"
		eapply --fuzz=0 -- "${T}/hardened.patch"
	fi

	if use rt || use rt-bore; then
		eapply "${patches_prefix}-rt-i915.patch"
	fi

	cp "${configs_prefix}-config" .config || die

	if use clang; then
		eapply "${patches_prefix}-dkms-clang.patch"
	fi

	# Apply user patches (from /etc/portage/patches/)
	eapply_user

	# CachyOS ships a prebuilt BPF object in its source tarball.
	rm -f tools/testing/selftests/tc-testing/action-ebpf || die

	# --- Kernel config modifications ---

	if use server; then
		scripts/config -d CACHY || die
	else
		scripts/config -e CACHY || die
	fi

	if use bore || use bore-dev || use cachyos-hardened; then
		scripts/config -e SCHED_BORE || die
	elif use bmq || use bmq-lfbmq; then
		scripts/config -e SCHED_ALT -e SCHED_BMQ || die
	elif use pds; then
		scripts/config -e SCHED_ALT -d SCHED_BMQ -e SCHED_PDS || die
	elif use rt; then
		scripts/config -e PREEMPT_RT || die
	elif use rt-bore; then
		scripts/config -e SCHED_BORE -e PREEMPT_RT || die
	fi

	if use handheld; then
		scripts/config -e AMD_PRIVATE_COLOR -d RCU_LAZY_DEFAULT_OFF \
			-m EXTCON_STEAMDECK -m MFD_STEAMDECK -m SENSORS_STEAMDECK \
			-m LEDS_STEAMDECK -m SND_SOC_AW87XXX -m HID_LENOVO_GO \
			-m HID_LENOVO_GO_S -m HID_MSI_CLAW -m ZOTAC_ZONE_HID \
			-m ZOTAC_ZONE_PLATFORM || die
	fi
	if use sched-ext-peek; then
		scripts/config -e SCHED_CLASS_EXT || die
	fi
	if use clang-polly; then
		scripts/config -e POLLY_CLANG || die
	fi
	if use acpi-call; then
		scripts/config -m ACPI_CALL || die
	fi
	if use aufs; then
		scripts/config -m AUFS_FS || die
	fi
	if use poc-selector; then
		scripts/config -e SCHED_POC_SELECTOR || die
	fi
	if use governor-nap; then
		scripts/config -e CPU_IDLE_GOV_NAP || die
	fi
	if use governor-reflex; then
		scripts/config -e CPU_FREQ_GOV_SCHEDUTIL -m CPU_FREQ_GOV_REFLEX || die
	fi

	# Keep existing upstream driver defaults; provide independent opt-outs.
	if ! use adios; then
		scripts/config -d MQ_IOSCHED_ADIOS -d MQ_IOSCHED_DEFAULT_ADIOS || die
	elif use adios-default; then
		scripts/config -e MQ_IOSCHED_DEFAULT_ADIOS || die
	fi
	if ! use v4l2loopback; then
		scripts/config -d V4L2_LOOPBACK || die
	fi
	if ! use vhba; then
		scripts/config -d VHBA || die
	fi
	if ! use apple-t2; then
		scripts/config -d SENSORS_APPLESMC_T2 -d T2BCE_CORE -d T2BCE_DMA \
			-d T2BCE_VHCI -d T2BCE_AUDIO || die
	fi
	if use amd-private-color; then
		scripts/config -e AMD_PRIVATE_COLOR || die
	fi

	if ! use asus-armoury; then
		scripts/config -d ASUS_ARMOURY || die
	fi
	if ! use asus-ally; then
		scripts/config -d HID_ASUS_ALLY || die
	fi
	if ! use asus-wmi-legacy; then
		scripts/config -d ASUS_WMI_DEPRECATED_ATTRS || die
	fi
	if ! use unprivileged-userns; then
		scripts/config -d USER_NS_UNPRIVILEGED || die
	fi
	if ! use anon-min-protection; then
		scripts/config --set-val ANON_MIN_RATIO 0 || die
	fi
	if ! use clean-low-protection; then
		scripts/config --set-val CLEAN_LOW_RATIO 0 || die
	fi
	if ! use clean-min-protection; then
		scripts/config --set-val CLEAN_MIN_RATIO 0 || die
	fi

	### Enable KCFI
	if use kcfi; then
		scripts/config -e CFI -e CFI_AUTO_DEFAULT || die
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
	if ! use rt && ! use rt-bore; then
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

	# Preserve the default LTS output; server selects madvise unless overridden.
	if use hugepage_madvise || { use server && ! use hugepage_always; }; then
		scripts/config -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE || die
	else
		scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS || die
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
		ewarn "kernel-builtin-zfs only stages ZFS sources and a build helper."
		ewarn "It does not build or install ZFS modules for this distribution kernel."
		ewarn "Use sys-fs/zfs and sys-fs/zfs-kmod for managed ZFS support."
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
