# Copyright 2023-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI="8"
ETYPE="sources"
EXTRAVERSION="-cachyos"
K_WANT_GENPATCHES="base extras"
K_GENPATCHES_VER="10"

# make sure kernel-2 know right version without guess
K_BASE_VER="$PV"

inherit kernel-2 optfeature
detect_version


# disable all patch from kernel-2
UNIPATCH_LIST_DEFAULT=""

DESCRIPTION="Linux SCHED-EXT + Cachy Sauce + BORE Kernel by CachyOS with other patches and improvements"
HOMEPAGE="https://github.com/CachyOS/linux-cachyos"
SRC_URI="
	${KERNEL_BASE_URI}/linux-${KV_MAJOR}.${KV_MINOR}.${KV_PATCH}.tar.xz -> linux-${KV_MAJOR}.${KV_MINOR}.tar.xz
	${GENPATCHES_URI}
"
LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="
	+bore-sched-ext bore echo rt rt-bore eevdf sched-ext
	hardened +auto-cpu-optimization kcfi
	hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_625 hz_ticks_750 +hz_ticks_1000
	+per-gov tickrate_perodic tickrate_idle +tickrate_full preempt_full preempt_voluntary preempt_server
	+o3 os +bbr3
	+lru_config_standard lru_config_stats lru_config_none
	+vma_config_standard vma_config_stats vma_config_none
	+hugepage_always hugepage_madvise
	damon
"
REQUIRED_USE="
	^^ ( bore-sched-ext bore echo rt rt-bore eevdf sched-ext )
	^^ ( hz_ticks_100 hz_ticks_250 hz_ticks_300 hz_ticks_500 hz_ticks_600 hz_ticks_625 hz_ticks_750 hz_ticks_1000 )
	^^ ( tickrate_perodic tickrate_idle tickrate_full )
	rt? ( ^^ ( preempt_full preempt_voluntary preempt_server ) )
	rt-bore? ( ^^ ( preempt_full preempt_voluntary preempt_server ) )
	?? ( o3 os )
	^^ ( lru_config_standard lru_config_stats lru_config_none )
	^^ ( vma_config_standard vma_config_stats vma_config_none )
	^^ ( hugepage_always hugepage_madvise )
"

_set_hztick_rate() {
	local _HZ_ticks=$1
	if [[ $_HZ_ticks == 300 ]]; then
		scripts/config -e HZ_300 --set-val HZ 300 || die
	else
		scripts/config -d HZ_300 -e "HZ_${_HZ_ticks}" --set-val HZ "${_HZ_ticks}" || die
	fi
}

_eapply() {
	local _patch=$1
	# no die, due https://github.com/CachyOS/kernel-patches/commit/19dd3a1f0aaa0deb61964e9d88a361804e3c6a24 have bugs
	einfo "Applying ${_patch} (-p1) ..."
	patch -p1 -N -i "${_patch}" -d "$S"
}

src_prepare() {
	files_dir="${FILESDIR}/${PV}"
	_eapply "${files_dir}/all/0001-cachyos-base-all.patch"

	if use bore-sched-ext; then
		_eapply "${files_dir}/sched/0001-sched-ext.patch"
		_eapply "${files_dir}/sched/0001-bore-cachy-ext.patch"
		cp "${files_dir}/config-bore-sched-ext" .config || die
	fi

	if use bore; then
		_eapply "${files_dir}/sched/0001-bore-cachy.patch"
		cp "${files_dir}/config-bore" .config || die
	fi

	if use "echo"; then
		_eapply "${files_dir}/sched/0001-echo-cachy.patch"
		cp "${files_dir}/config-echo" .config || die
	fi

	if use rt; then
		_eapply "${files_dir}/misc/0001-rt.patch"
		cp "${files_dir}/config-rt" .config || die
	fi

	if use rt-bore; then
		_eapply "${files_dir}/misc/0001-rt.patch"
		_eapply "${files_dir}/sched/0001-bore-cachy-rt.patch"
		cp "${files_dir}/config-rt-bore" .config || die
	fi

	if use sched-ext; then
		_eapply "${files_dir}/sched/0001-sched-ext.patch"
		cp "${files_dir}/config-sched-ext" .config || die
	fi

	if use hardened; then
		_eapply "${files_dir}/misc/0001-hardened.patch"
		cp "${files_dir}/config-hardened" .config || die
	fi

	eapply_user

	if use auto-cpu-optimization; then
		sh "${files_dir}/auto-cpu-optimization.sh" || die
	fi

	# Remove CachyOS's localversion
	find . -name "localversion*" -delete || die
	scripts/config -u LOCALVERSION || die

	# Enable CachyOS tweaks
	scripts/config -e CACHY || die

	# _cpusched
	if use bore-sched-ext; then
		scripts/config -e SCHED_CLASS_EXT -e SCHED_BORE || die
	fi

	if use bore; then
		scripts/config -e SCHED_BORE || die
	fi

	if use "echo"; then
		scripts/config -e ECHO_SCHED || die
	fi

	if use rt; then
		scripts/config -e PREEMPT_COUNT -e PREEMPTION -d PREEMPT_VOLUNTARY -d PREEMPT -d PREEMPT_NONE -e PREEMPT_RT -d PREEMPT_DYNAMIC -d PREEMPT_BUILD || die
	fi

	if use rt-bore; then
		scripts/config -e SCHED_BORE -e PREEMPT_COUNT -e PREEMPTION -d PREEMPT_VOLUNTARY -d PREEMPT -d PREEMPT_NONE -e PREEMPT_RT -d PREEMPT_DYNAMIC -d PREEMPT_BUILD || die
	fi

	if use sched-ext; then
		scripts/config -e SCHED_CLASS_EXT || die
	fi

	# Enable KCFI
	if use kcfi; then
		scripts/config -e ARCH_SUPPORTS_CFI_CLANG -e CFI_CLANG || die
	fi

	# Setting tick rate
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

	### Enable BBR3
	if use bbr3; then
		scripts/config -m TCP_CONG_CUBIC \
			-d DEFAULT_CUBIC \
			-e TCP_CONG_BBR \
			-e DEFAULT_BBR \
			--set-str DEFAULT_TCP_CONG bbr || die
	fi

	### Select LRU config
	if use lru_config_standard; then
		scripts/config -e LRU_GEN -e LRU_GEN_ENABLED -d LRU_GEN_STATS || die
	fi

	if use lru_config_stats; then
		scripts/config -e LRU_GEN -e LRU_GEN_ENABLED -e LRU_GEN_STATS || die
	fi

	if use lru_config_none; then
		scripts/config -d LRU_GEN || die
	fi

	### Select VMA config
	if use vma_config_standard; then
		scripts/config -e PER_VMA_LOCK -d PER_VMA_LOCK_STATS || die
	fi

	if use vma_config_stats; then
		scripts/config -e PER_VMA_LOCK -e PER_VMA_LOCK_STATS || die
	fi

	if use vma_config_none; then
		scripts/config -d PER_VMA_LOCK || die
	fi

	### Select THP
	if use hugepage_always; then
		scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS || die
	fi

	if use hugepage_madvise; then
		scripts/config -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE || die
	fi

	### Enable DAMON
	if use damon; then
		scripts/config -e DAMON \
			-e DAMON_VADDR \
			-e DAMON_DBGFS \
			-e DAMON_SYSFS \
			-e DAMON_PADDR \
			-e DAMON_RECLAIM \
			-e DAMON_LRU_SORT || die
	fi

	### Enable USER_NS_UNPRIVILEGED
	scripts/config -e USER_NS || die

	### Change hostname
	scripts/config --set-str DEFAULT_HOSTNAME "gentoo" || die

	### Set LOCALVERSION
	scripts/config --set-str LOCALVERSION "${PV}" || die
}

pkg_postinst() {
	kernel-2_pkg_postinst

	optfeature "userspace KSM helper" sys-process/uksmd
	optfeature "auto nice daemon" app-admin/ananicy-cpp
	ewarn "Install sys-kernel/scx to Enable sched_ext schedulers"
	ewarn "You can find it in xarblu-overlay"
	ewarn "Then enable/start scx service."
}

pkg_postrm() {
	kernel-2_pkg_postrm
}

# ./script/get_files.py --version 6.8.9_rc4 --previous-commit 365d5af1c93d63e7e53847312b0fc96576a320c5
