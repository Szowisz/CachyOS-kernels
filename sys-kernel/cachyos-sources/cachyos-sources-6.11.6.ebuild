# Copyright 2023-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI="8"
ETYPE="sources"
EXTRAVERSION="-cachyos" # Not used in kernel-2, just due to most ebuilds have it
K_USEPV="1"
K_WANT_GENPATCHES="base extras experimental"
K_GENPATCHES_VER="8"
ZFS_COMMIT="baa50314567afd986a00838f0fa65fdacbd12daf"

# make sure kernel-2 know right version without guess
CKV="$(ver_cut 1-3)"

inherit kernel-2 optfeature
detect_version

# disable all patch from kernel-2
#UNIPATCH_LIST_DEFAULT=""

DESCRIPTION="Linux SCHED-EXT + BORE + Cachy Sauce Kernel by CachyOS with other patches and improvements"
HOMEPAGE="https://github.com/CachyOS/linux-cachyos"
LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="
	experimental
	+bore-sched-ext bore bmq rt rt-bore eevdf sched-ext
	deckify hardened +auto-cpu-optimization kcfi
	+llvm-lto-thin llvm-lto-full
	zfs
	hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_625 hz_ticks_750 +hz_ticks_1000
	+per-gov tickrate_perodic tickrate_idle +tickrate_full preempt_full preempt_voluntary preempt_server
	+o3 os debug +bbr3
	+hugepage_always hugepage_madvise
	mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4
	mnative_amd mnative_intel
	mk8 mk8sse3 mk10 mbarcelona mbobcat mjaguar mbulldozer mpiledriver msteamroller mexcavator mzen mzen2 mzen3 mzen4
	mmpsc matom mcore2 mnehalem mwestmere msilvermont msandybridge mivybridge mhaswell mbroadwell mskylake mskylakex mcannonlake micelake mgoldmont mgoldmontplus mcascadelake mcooperlake mtigerlake msapphirerapids mrocketlake malderlake
"
REQUIRED_USE="
	^^ ( bore-sched-ext bore bmq rt rt-bore eevdf sched-ext )
	?? ( llvm-lto-thin llvm-lto-full )
	^^ ( hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_625 hz_ticks_750 hz_ticks_1000 )
	^^ ( tickrate_perodic tickrate_idle tickrate_full )
	rt? ( ^^ ( preempt_full preempt_voluntary preempt_server ) )
	rt-bore? ( ^^ ( preempt_full preempt_voluntary preempt_server ) )
	?? ( o3 os debug )
	^^ ( hugepage_always hugepage_madvise )
	?? ( auto-cpu-optimization mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4 mnative_amd mnative_intel mk8 mk8sse3 mk10 mbarcelona mbobcat mjaguar mbulldozer mpiledriver msteamroller mexcavator mzen mzen2 mzen3 mzen4 mmpsc matom mcore2 mnehalem mwestmere msilvermont msandybridge mivybridge mhaswell mbroadwell mskylake mskylakex mcannonlake micelake mgoldmont mgoldmontplus mcascadelake mcooperlake mtigerlake msapphirerapids mrocketlake malderlake )
"
SRC_URI="
	${KERNEL_URI}
	${GENPATCHES_URI}
	zfs? ( https://github.com/cachyos/zfs/archive/$ZFS_COMMIT.tar.gz -> zfs-$ZFS_COMMIT.tar.gz )
"

_set_hztick_rate() {
	local _HZ_ticks=$1
	if [[ $_HZ_ticks == 300 ]]; then
		scripts/config -e HZ_300 --set-val HZ 300 || die
	else
		scripts/config -d HZ_300 -e "HZ_${_HZ_ticks}" --set-val HZ "${_HZ_ticks}" || die
	fi
}


src_unpack() {
	kernel-2_src_unpack
	### Push ZFS to linux
	use zfs && (unpack zfs-$ZFS_COMMIT.tar.gz && mv zfs-$ZFS_COMMIT zfs || die)
	use zfs && (cp $FILESDIR/kernel-build-zsh.sh zfs/ || die)
}

src_prepare() {
	files_dir="${FILESDIR}/${PV}"
	eapply "${files_dir}/all/0001-cachyos-base-all.patch"

	if use bore-sched-ext; then
		eapply "${files_dir}/sched/0001-sched-ext.patch"
		eapply "${files_dir}/sched/0001-bore-cachy-ext.patch"
		cp "${files_dir}/config-bore-sched-ext" .config || die
	fi

	if use bore; then
		eapply "${files_dir}/sched/0001-bore-cachy.patch"
		cp "${files_dir}/config-bore" .config || die
	fi

	if use bmq; then
		eapply "${files_dir}/sched/0001-prjc-cachy.patch"
		cp "${files_dir}/config-bmq" .config || die
	fi

	if use eevdf; then
		eapply "${files_dir}/sched/0001-eevdf-next.patch"
		cp "${files_dir}/config-eevdf" .config || die
	fi

	if use rt; then
		eapply "${files_dir}/misc/0001-rt.patch"
		cp "${files_dir}/config-rt-bore" .config || die
	fi

	if use rt-bore; then
		eapply "${files_dir}/misc/0001-rt.patch"
		eapply "${files_dir}/sched/0001-bore-cachy-rt.patch"
		cp "${files_dir}/config-rt-bore" .config || die
	fi

	if use sched-ext; then
		eapply "${files_dir}/sched/0001-sched-ext.patch"
		cp "${files_dir}/config-sched-ext" .config || die
	fi

	if use hardened; then
		eapply "${files_dir}/misc/0001-hardened.patch"
		cp "${files_dir}/config-hardened" .config || die
	fi

	if use deckify; then
		eapply "${files_dir}/misc/0001-wifi-ath11k-Rename-QCA2066-fw-dir-to-QCA206X.patch"
		eapply "${files_dir}/misc/0001-acpi-call.patch"
		eapply "${files_dir}/misc/0001-handheld.patch"
		cp "${files_dir}/config-deckify" .config || die
	fi

	eapply_user

	if use auto-cpu-optimization; then
		sh "${files_dir}/auto-cpu-optimization.sh" || die
	fi

	# Remove CachyOS's localversion
	#find . -name "localversion*" -delete || die
	#scripts/config -u LOCALVERSION || die

	### Selecting CachyOS config
	scripts/config -e CACHY || die

	### Selecting the CPU scheduler
	if use bore-sched-ext; then
		scripts/config -e SCHED_CLASS_EXT -e SCHED_BORE || die
	fi

	if use bore || use hardened; then
		scripts/config -e SCHED_BORE || die
	fi

	if use bmq; then
		scripts/config -e SCHED_ALT -e SCHED_BMQ || die
	fi

	if use rt; then
		scripts/config -e PREEMPT_COUNT -e PREEMPTION -d PREEMPT_VOLUNTARY -d PREEMPT -d PREEMPT_NONE -d PREEMPT_RT -d PREEMPT_DYNAMIC -e PREEMPT_BUILD -e PREEMPT_BUILD_AUTO -e PREEMPT_AUTO || die
	fi

	if use rt-bore; then
		scripts/config -e SCHED_BORE -e PREEMPT_COUNT -e PREEMPTION -d PREEMPT_VOLUNTARY -d PREEMPT -d PREEMPT_NONE -d PREEMPT_RT -d PREEM
PT_DYNAMIC -e PREEMPT_BUILD -e PREEMPT_BUILD_AUTO -e PREEMPT_AUTO || die
	fi

	if use sched-ext; then
		scripts/config -e SCHED_CLASS_EXT || die
	fi

	### Enable KCFI
	if use kcfi; then
		scripts/config -e ARCH_SUPPORTS_CFI_CLANG -e CFI_CLANG -e CFI_AUTO_DEFAULT || die
	fi

	### Select LLVM level
	if use llvm-lto-thin; then
		scripts/config -e LTO -e LTO_CLANG -e ARCH_SUPPORTS_LTO_CLANG -e ARCH_SUPPORTS_LTO_CLANG_THIN -d LTO_NONE -e HAS_LTO_CLANG -d LTO_CLANG_FULL -e LTO_CLANG_THIN -e HAVE_GCC_PLUGINS || die
	elif use llvm-lto-full; then
		scripts/config -e LTO -e LTO_CLANG -e ARCH_SUPPORTS_LTO_CLANG -e ARCH_SUPPORTS_LTO_CLANG_THIN -d LTO_NONE -e HAS_LTO_CLANG -e LTO_CLANG_FULL -d LTO_CLANG_THIN -e HAVE_GCC_PLUGINS || die
	else
		scripts/config -e LTO_NONE || die
	fi

	## LLVM patch
	if use kcfi || use llvm-lto-thin || use llvm-lto-full; then
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
	elif use hz_ticks_625; then
		_set_hztick_rate 625
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
	if use tickrate_perodic; then
		scripts/config -d NO_HZ_IDLE -d NO_HZ_FULL -d NO_HZ -d NO_HZ_COMMON -e HZ_PERIODIC || die
	fi

	if use tickrate_idle; then
		scripts/config -d HZ_PERIODIC -d NO_HZ_FULL -e NO_HZ_IDLE -e NO_HZ -e NO_HZ_COMMON || die
	fi

	if use tickrate_full; then
		scripts/config -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL_NODEF -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING || die
	fi

	### Select preempt type
	if use preempt_full; then
		scripts/config -e PREEMPT_BUILD -d PREEMPT_NONE -d PREEMPT_VOLUNTARY -e PREEMPT -e PREEMPT_COUNT -e PREEMPTION -e PREEMPT_DYNAMIC || die
	fi

	if use preempt_voluntary; then
		scripts/config -e PREEMPT_BUILD -d PREEMPT_NONE -e PREEMPT_VOLUNTARY -d PREEMPT -e PREEMPT_COUNT -e PREEMPTION -d PREEMPT_DYNAMIC || die
	fi

	if use preempt_server; then
		scripts/config -e PREEMPT_NONE_BUILD -e PREEMPT_NONE -d PREEMPT_VOLUNTARY -d PREEMPT -d PREEMPTION -d PREEMPT_DYNAMIC || die
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
			-d DEBUG_PREEMPT
	fi

	### Enable BBR3
	if use bbr3; then
		scripts/config -m TCP_CONG_CUBIC \
			-d DEFAULT_CUBIC \
			-e TCP_CONG_BBR \
			-e DEFAULT_BBR \
			--set-str DEFAULT_TCP_CONG bbr || die
	fi

	### Select THP
	if use hugepage_always; then
		scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS || die
	fi

	if use hugepage_madvise; then
		scripts/config -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE || die
	fi

	### Select CPU optimization
	march_list=(mgeneric mgeneric_v1 mgeneric_v2 mgeneric_v3 mgeneric_v4 mnative_amd mnative_intel mk8 mk8sse3 mk10 mbarcelona mbobcat mjaguar mbulldozer mpiledriver msteamroller mexcavator mzen mzen2 mzen3 mzen4 mmpsc matom mcore2 mnehalem mwestmere msilvermont msandybridge mivybridge mhaswell mbroadwell mskylake mskylakex mcannonlake micelake mgoldmont mgoldmontplus mcascadelake mcooperlake mtigerlake msapphirerapids mrocketlake malderlake)
	for MMARCH in "${march_list[@]}"; do
		if use "${MMARCH}"; then
			MARCH_TRIMMED=${MMARCH:1}
			MARCH=$(echo "$MARCH_TRIMMED" | tr '[:lower:]' '[:upper:]')
			if [ "$MARCH" != "GENERIC" ]; then
				if [[ "$MARCH" =~ GENERIC_V[1-4] ]]; then
					X86_64_LEVEL="${MARCH//GENERIC_V}"
					scripts/config --set-val X86_64_VERSION "${X86_64_LEVEL}"
				else
					scripts/config -k -d CONFIG_GENERIC_CPU
					scripts/config -k -e "CONFIG_M${MARCH}"
				fi
			 fi
			break
		fi
	done

	### Enable USER_NS_UNPRIVILEGED
	scripts/config -e USER_NS || die

	### Change hostname
	scripts/config --set-str DEFAULT_HOSTNAME "gentoo" || die

	### Set LOCALVERSION
	#scripts/config --set-str LOCALVERSION "${PV}" || die
}

pkg_postinst() {
	kernel-2_pkg_postinst

	optfeature "userspace KSM helper" sys-process/uksmd
	optfeature "NVIDIA opensource module" "x11-drivers/nvidia-drivers[kernel-open]"
	optfeature "NVIDIA module" x11-drivers/nvidia-drivers
	use zfs && ewarn "ZFS support build way: https://github.com/CachyOS/linux-cachyos/blob/f843b48b52fb52c00f76b7d29f70ba1eb2b4cc06/linux-cachyos-server/PKGBUILD#L573, and you can check linux/zfs/kernel-build-zsh.sh as example"
	ewarn "Install sys-kernel/scx to Enable sched_ext schedulers"
	ewarn "You can find it in xarblu-overlay"
	ewarn "Then enable/start scx service."
}

pkg_postrm() {
	kernel-2_pkg_postrm
}

# 450048a1621bd7a3d965e00f32901dbe1c8f1a3f
