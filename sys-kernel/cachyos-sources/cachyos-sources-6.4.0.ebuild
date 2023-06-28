# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI="8"
ETYPE="sources"
EXTRAVERSION="-cachyos"
K_EXP_GENPATCHES_NOUSE="1"
K_WANT_GENPATCHES="base extras"
K_GENPATCHES_VER="1"

inherit kernel-2 optfeature
detect_version

DESCRIPTION="CachyOS provides enhanced kernels that offer improved performance and other benefits."
HOMEPAGE="https://github.com/CachyOS/linux-cachyos"
SRC_URI="${KERNEL_URI} ${GENPATCHES_URI}"

LICENSE="GPL-3"
KEYWORDS="~amd64"
IUSE="+bore-eevdf bore pds bmq cfs tt"
REQUIRED_USE="bore-eevdf? ( !bore !pds !bmq !cfs !tt ) bore? ( !pds !bmq !cfs !tt !bore-eevdf ) pds? ( !bore !bmq !cfs !tt !bore-eevdf ) tt? ( !bore !pds !bmq !cfs !bore-eevdf ) bmq? ( !tt !bore !pds !cfs !bore-eevdf )"

src_prepare() {
	eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/all/0001-cachyos-base-all.patch"

	if use bore-eevdf; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-EEVDF.patch"
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-bore-eevdf.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-bore-eevdf" .config || die
	fi

	if use bore; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-bore.patch"
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/misc/0001-bore-tuning-sysctl.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-bore" .config || die
	fi

#	if use eevdf; then
#		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-EEVDF.patch"
#		cp "${FILESDIR}/config-x86_64-eevdf" .config
#	fi

	if use pds; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-prjc-cachy.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-pds" .config || die
	fi

	if use bmq; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-prjc-cachy.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-bmq" .config || die
	fi

	if use tt; then
		eapply "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/sched/0001-tt-cachy.patch"
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-tt" .config || die
	fi

	if use cfs; then
		cp "${FILESDIR}/${KV_MAJOR}.${KV_MINOR}/config-x86_64-cfs" .config || die
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
	if use bore-eevdf; then
		scripts/config -e HZ_500
		scripts/config --set-val HZ 500
	fi

	if use bore; then
                scripts/config -e HZ_500
                scripts/config --set-val HZ 500
        fi

	if use cfs; then
                scripts/config -e HZ_500
                scripts/config --set-val HZ 500
        fi

# 1000 HZ
	if use pds; then
                scripts/config -e HZ_1000
                scripts/config --set-val HZ 1000
        fi

	if use bmq; then
                scripts/config -e HZ_1000
                scripts/config --set-val HZ 1000
        fi

	if use tt; then
                scripts/config -e HZ_1000
                scripts/config --set-val HZ 1000
        fi

# Enable MGLRU - now it's available by default in config
#scripts/config -e LRU_GEN
#scripts/config -e LRU_GEN_ENABLED
#scripts/config -d LRU_GEN_STATS

# Enable PER_VMA_LOCK
scripts/config -e PER_VMA_LOCK
scripts/config -d PER_VMA_LOCK_STATS

# Enabling better ZSTD modules and kernel compression ratio
scripts/config --set-val MODULE_COMPRESS_ZSTD_LEVEL 19
scripts/config -d MODULE_COMPRESS_ZSTD_ULTRA
scripts/config --set-val ZSTD_COMP_VAL 22

# Enable bbr2
scripts/config -m TCP_CONG_CUBIC
scripts/config -d DEFAULT_CUBIC
scripts/config -e TCP_CONG_BBR2
scripts/config -e DEFAULT_BBR2
scripts/config --set-str DEFAULT_TCP_CONG bbr2

# Switch into FQ - bbr2 doesn't work properly with FQ_CODEL
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
