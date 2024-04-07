# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI="8"
ETYPE="sources"
EXTRAVERSION="-cachyos"
K_EXP_GENPATCHES_NOUSE="1"
K_WANT_GENPATCHES="base extras"
K_GENPATCHES_VER="6"

inherit kernel-2 optfeature
detect_version

DESCRIPTION="CachyOS provides enhanced kernels that offer improved performance and other benefits."
HOMEPAGE="https://github.com/CachyOS/linux-cachyos"
SRC_URI="${KERNEL_URI} ${GENPATCHES_URI}"

LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="+bore-sched-ext bore eevdf rt-bore sched-ext"
REQUIRED_USE="bore-sched-ext? ( !sched-ext !bore !eevdf !rt-bore ) bore? ( !eevdf !rt-bore !bore-sched-ext !sched-ext ) eevdf? ( !bore !rt-bore !bore-sched-ext !sched-ext ) rt-bore? ( !bore !eevdf !bore-sched-ext !sched-ext ) sched-ext? ( !bore !eevdf !rt-bore !bore-sched-ext )"

src_prepare() {
	eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/all/0001-cachyos-base-all.patch"

	if use bore; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-bore-cachy.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-bore" .config || die
	fi

	if use eevdf; then
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-eevdf" .config || die
	fi

	if use bore-sched-ext; then
                eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-sched-ext.patch"
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-bore-cachy.patch"
                cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-bore-sched-ext" .config || die
        fi


	if use sched-ext; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-sched-ext.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-sched-ext" .config || die
	fi

	if use rt-bore; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/misc/0001-rt.patch"
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-bore-cachy-rt.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-rt-bore" .config || die
	fi
	eapply_user

sh "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/auto-cpu-optimization.sh"

# Remove CachyOS's localversion
find . -name "localversion*" -delete
scripts/config -u LOCALVERSION

# Enable CachyOS tweaks
scripts/config -e CACHY

# Setting tick rate
scripts/config -d HZ_300

# 500 HZ
	if use bore; then
		scripts/config -e HZ_500
		scripts/config --set-val HZ 500
	fi

	if use eevdf; then
                scripts/config -e HZ_500
                scripts/config --set-val HZ 500
        fi

	if use sched-ext; then
		scripts/config -e HZ_500
                scripts/config --set-val HZ 500
        fi

	if use bore-sched-ext; then
                scripts/config -e HZ_500
                scripts/config --set-val HZ 500
        fi


# 1000 HZ
	if use rt-bore; then
		scripts/config -e HZ_1000
                scripts/config --set-val HZ 1000
        fi

# Enable MGLRU - now it's available by default in config
#scripts/config -e LRU_GEN
#scripts/config -e LRU_GEN_ENABLED
#scripts/config -d LRU_GEN_STATS

# Enable BORE
	if use bore; then
		scripts/config -e SCHED_BORE
	fi

	if use bore-sched-ext; then
		scripts/config -e SCHED_BORE
	fi

# Enable sched-ext
	if use sched-ext; then
		scripts/config -e SCHED_CLASS_EXT
	fi

	if use bore-sched-ext; then
                scripts/config -e SCHED_CLASS_EXT
        fi

# Enable rt-bore
	if use rt-bore; then
                scripts/config -e SCHED_BORE -e PREEMPT_COUNT -e PREEMPTION -d PREEMPT_VOLUNTARY -d PREEMPT -d PREEMPT_NONE -e PREEMPT_RT -d PREEMPT_DYNAMIC -d PREEMPT_BUILD
        fi

# Disable debug for sched-ext and bore-sched-ext: https://github.com/CachyOS/linux-cachyos/issues/187
	if use sched-ext; then
		scripts/config -d DEBUG_INFO -d DEBUG_INFO_BTF -d DEBUG_INFO_DWARF4 -d DEBUG_INFO_DWARF5 -d PAHOLE_HAS_SPLIT_BTF -d DEBUG_INFO_BTF_MODULES -d SLUB_DEBUG -d PM_DEBUG -d PM_ADVANCED_DEBUG -d PM_SLEEP_DEBUG -d ACPI_DEBUG -d SCHED_DEBUG -d LATENCYTOP -d DEBUG_PREEMPT
	fi

	if use bore-sched-ext; then
                scripts/config -d DEBUG_INFO -d DEBUG_INFO_BTF -d DEBUG_INFO_DWARF4 -d DEBUG_INFO_DWARF5 -d PAHOLE_HAS_SPLIT_BTF -d DEBUG_INFO_BTF_MODULES -d SLUB_DEBUG -d PM_DEBUG -d PM_ADVANCED_DEBUG -d PM_SLEEP_DEBUG -d ACPI_DEBUG -d SCHED_DEBUG -d LATENCYTOP -d DEBUG_PREEMPT
        fi

# Enable PER_VMA_LOCK - now it's in config
#scripts/config -e PER_VMA_LOCK
#scripts/config -d PER_VMA_LOCK_STATS

# Enabling better ZSTD modules and kernel compression ratio - now set that using ZSTD_CLEVEL variable
#scripts/config --set-val MODULE_COMPRESS_ZSTD_LEVEL 19
#scripts/config -d MODULE_COMPRESS_ZSTD_ULTRA
#scripts/config --set-val ZSTD_COMP_VAL 22

# Enable bbr3
scripts/config -m TCP_CONG_CUBIC
scripts/config -d DEFAULT_CUBIC
scripts/config -e TCP_CONG_BBR
scripts/config -e DEFAULT_BBR
scripts/config --set-str DEFAULT_TCP_CONG bbr

# Switch into FQ - bbr3 doesn't work properly with FQ_CODEL
scripts/config -m NET_SCH_FQ_CODEL
scripts/config -e NET_SCH_FQ
scripts/config -d DEFAULT_FQ_CODEL
scripts/config -e DEFAULT_FQ
scripts/config --set-str DEFAULT_NET_SCH fq

# Set performance governor
scripts/config -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
scripts/config -e CPU_FREQ_DEFAULT_GOV_PERFORMANCE

# Set O3
scripts/config -d CC_OPTIMIZE_FOR_PERFORMANCE
scripts/config -e CC_OPTIMIZE_FOR_PERFORMANCE_O3

# Enable full ticks
scripts/config -d HZ_PERIODIC
scripts/config -d NO_HZ_IDLE
scripts/config -d CONTEXT_TRACKING_FORCE
scripts/config -e NO_HZ_FULL_NODEF
scripts/config -e NO_HZ_FULL
scripts/config -e NO_HZ
scripts/config -e NO_HZ_COMMON
scripts/config -e CONTEXT_TRACKING

# Enable full preempt
scripts/config -e PREEMPT_BUILD
scripts/config -d PREEMPT_NONE
scripts/config -d PREEMPT_VOLUNTARY
scripts/config -e PREEMPT
scripts/config -e PREEMPT_COUNT
scripts/config -e PREEMPTION
scripts/config -e PREEMPT_DYNAMIC

# Change hostname
scripts/config --set-str DEFAULT_HOSTNAME "gentoo"

# Miscellaneous
scripts/config -d DRM_SIMPLEDRM
scripts/config -e GENTOO_LINUX_INIT_SYSTEMD
scripts/config --set-str CONFIG_LSM “lockdown,yama,integrity,selinux,apparmor,bpf,landlock”

}

pkg_postinst() {
	kernel-2_pkg_postinst

	optfeature "userspace KSM helper" sys-process/uksmd
	optfeature "auto nice daemon" app-admin/ananicy-cpp
}

pkg_postrm() {
	kernel-2_pkg_postrm
}
