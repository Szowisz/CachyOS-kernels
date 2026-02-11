# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8
inherit optfeature systemd tmpfiles udev

DESCRIPTION="Configuration files that tweak sysctl values, add udev rules to automatically set schedulers, and provide additional optimizations."
HOMEPAGE="https://github.com/CachyOS/CachyOS-Settings"
SRC_URI="https://github.com/CachyOS/CachyOS-Settings/archive/${PV}.tar.gz -> ${P}.tar.gz"

S="${WORKDIR}/CachyOS-Settings-${PV}"

IUSE="X zram"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"

RDEPEND="
	app-admin/ananicy-cpp
	sys-apps/hdparm
	sys-apps/inxi
	sys-process/procps
	virtual/udev
	X? ( x11-drivers/xf86-input-libinput )
	zram? (
		sys-apps/zram-generator
		app-arch/zstd
	)
"

src_install() {
	# /etc configs
	insinto /etc
	doins -r "${S}/etc/debuginfod"
	doins -r "${S}/etc/security"

	# scripts
	dobin "${S}"/usr/bin/*

	# /usr/lib configs
	insinto /usr/lib
	doins -r "${S}/usr/lib/modprobe.d"
	doins -r "${S}/usr/lib/modules-load.d"
	doins -r "${S}/usr/lib/NetworkManager"
	doins -r "${S}/usr/lib/sysctl.d"
	doins -r "${S}/usr/lib/tmpfiles.d"

	# systemd unit
	systemd_dounit "${S}/usr/lib/systemd/system/pci-latency.service"

	# systemd service drop-ins
	insinto "$(systemd_get_systemunitdir)/rtkit-daemon.service.d"
	doins "${S}/usr/lib/systemd/system/rtkit-daemon.service.d/override.conf"

	insinto "$(systemd_get_systemunitdir)/user@.service.d"
	doins "${S}/usr/lib/systemd/system/user@.service.d/delegate.conf"

	# systemd daemon config drop-ins
	local utildir
	utildir="$(systemd_get_utildir)"
	utildir="${utildir#"${EPREFIX}"}"

	insinto "${utildir}"
	doins -r "${S}/usr/lib/systemd/journald.conf.d"
	doins -r "${S}/usr/lib/systemd/system.conf.d"
	doins -r "${S}/usr/lib/systemd/timesyncd.conf.d"
	doins -r "${S}/usr/lib/systemd/user.conf.d"

	# zram-generator config
	if use zram; then
		insinto "${utildir}"
		doins "${S}/usr/lib/systemd/zram-generator.conf"
	fi

	# udev rules
	local rule
	for rule in "${S}"/usr/lib/udev/rules.d/*.rules; do
		udev_dorules "${rule}"
	done

	# X11 config
	if use X; then
		insinto /usr/share/X11/xorg.conf.d
		doins "${S}/usr/share/X11/xorg.conf.d/20-touchpad.conf"
	fi

	# GNOME schema override and icon
	insinto /usr/share/glib-2.0/schemas
	doins "${S}/usr/share/glib-2.0/schemas/zz_cachyos.org.gnome.login-screen.gschema.override"

	insinto /usr/share/icons
	doins "${S}/usr/share/icons/cachyos.svg"
}

pkg_postinst() {
	udev_reload
	tmpfiles_process thp.conf

	optfeature "game-performance power profile switching" sys-power/power-profiles-daemon
}

pkg_postrm() {
	udev_reload
}
