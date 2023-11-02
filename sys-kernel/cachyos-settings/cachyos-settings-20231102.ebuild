# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8
inherit udev tmpfiles
SETTINGS_COMMIT="a1bb435163c6ae1a31eb4b904ffde4c1e2ab00d5"
DESCRIPTION="Configuration files that tweak sysctl values, add udev rules to automatically set schedulers, and provide additional optimizations."
HOMEPAGE="https://github.com/CachyOS/CachyOS-Settings"
SRC_URI="https://github.com/CachyOS/CachyOS-Settings/archive/${SETTINGS_COMMIT}.tar.gz -> ${P}.tar.gz"
S="${WORKDIR}/CachyOS-Settings-${SETTINGS_COMMIT}/etc/"
IUSE="systemd zram"
REQUIRED_USE="zram? ( systemd )"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"

DEPEND="virtual/udev
	sys-apps/hdparm
	sys-process/procps
	zram? (
		sys-apps/zram-generator
		app-arch/zstd
	)
	systemd? ( sys-apps/systemd )
	!systemd? ( sys-apps/systemd-utils[tmpfiles] )"
RDEPEND="${DEPEND}"

src_prepare(){
if usex systemd; then rm -f "${S}/security/limits.d/99-esync.conf"
fi

if usex zram; then rm -rf "${S}/systemd/zram-generator.conf"
fi
eapply_user

}

src_install() {
	insinto /etc
	doins -r "${S}/modprobe.d"
	doins -r "${S}/security"
	doins -r "${S}/sysctl.d"
	if use systemd; then doins -r "${S}/systemd"
	fi
	insinto /usr/lib
	doins -r "${S}/tmpfiles.d"
	udev_dorules "${S}/udev/rules.d/30-zram.rules"
	udev_dorules "${S}/udev/rules.d/40-hpet-permissions.rules"
	udev_dorules "${S}/udev/rules.d/50-sata.rules"
	udev_dorules "${S}/udev/rules.d/60-ioschedulers.rules"
	udev_dorules "${S}/udev/rules.d/69-hdparm.rules"
	udev_dorules "${S}/udev/rules.d/71-nvidia.rules"
	udev_dorules "${S}/udev/rules.d/99-cpu-dma-latency.rules"
}

pkg_postinst() {
	udev_reload
	tmpfiles_process thp.conf
}

pkg_postrm() {
	udev_reload
}
