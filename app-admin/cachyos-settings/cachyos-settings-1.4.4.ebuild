# Copyright 2023-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8
inherit optfeature systemd tmpfiles udev

DESCRIPTION="CachyOS sysctl, udev, systemd and desktop configuration"
HOMEPAGE="https://github.com/CachyOS/CachyOS-Settings"
SRC_URI="https://github.com/CachyOS/CachyOS-Settings/archive/${PV}.tar.gz -> ${P}.tar.gz"

S="${WORKDIR}/CachyOS-Settings-${PV}"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"
IUSE="X zram"

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
	local unitdir userunitdir generatordir udevdir
	unitdir="$(systemd_get_systemunitdir)"
	unitdir="${unitdir#"${EPREFIX}"}"
	userunitdir="$(systemd_get_userunitdir)"
	userunitdir="${userunitdir#"${EPREFIX}"}"
	generatordir="$(systemd_get_systemgeneratordir)"
	generatordir="${generatordir#"${EPREFIX}"}"
	udevdir="$(get_udevdir)"
	udevdir="${udevdir#"${EPREFIX}"}"

	# /etc configs
	insinto /etc
	doins -r "${S}/etc/debuginfod"
	doins -r "${S}/etc/security"

	# scripts
	dobin "${S}"/usr/bin/*
	# EAC setup installs Arch packages with pacman and enrolls vendor keys.
	rm "${ED}/usr/bin/eac-setup" || die

	# /usr/lib configs
	insinto /usr/lib
	doins -r "${S}/usr/lib/modprobe.d"
	doins -r "${S}/usr/lib/modules-load.d"
	doins -r "${S}/usr/lib/NetworkManager"
	doins -r "${S}/usr/lib/sysctl.d"
	doins -r "${S}/usr/lib/tmpfiles.d"

	# /usr/lib helpers
	exeinto /usr/lib
	doexe "${S}/usr/lib/iw-set-regdomain"

	# systemd unit
	systemd_dounit \
		"${S}/usr/lib/systemd/system/pci-latency.service" \
		"${S}/usr/lib/systemd/system/cachyos-iw-set-regdomain.path" \
		"${S}/usr/lib/systemd/system/cachyos-iw-set-regdomain.service"

	# systemd service drop-ins
	insinto "${unitdir}/rtkit-daemon.service.d"
	doins "${S}/usr/lib/systemd/system/rtkit-daemon.service.d/override.conf"

	insinto "${unitdir}/user@.service.d"
	doins "${S}/usr/lib/systemd/system/user@.service.d/delegate.conf"

	# systemd slice drop-ins
	insinto "${unitdir}/system.slice.d"
	doins "${S}"/usr/lib/systemd/system/system.slice.d/*.conf

	local slicedir
	for slicedir in session.slice.d slice.d; do
		insinto "${userunitdir}/${slicedir}"
		doins "${S}/usr/lib/systemd/user/${slicedir}"/*.conf
	done

	# systemd daemon config drop-ins
	local utildir
	utildir="$(systemd_get_utildir)"
	utildir="${utildir#"${EPREFIX}"}"

	insinto "${utildir}"
	doins -r "${S}/usr/lib/systemd/journald.conf.d"
	doins -r "${S}/usr/lib/systemd/system.conf.d"
	doins -r "${S}/usr/lib/systemd/timesyncd.conf.d"
	doins -r "${S}/usr/lib/systemd/user.conf.d"

	# zram-generator config; xswap replaces it on kernels that provide xswap
	if use zram; then
		insinto "${utildir}"
		doins "${S}/usr/lib/systemd/zram-generator.conf"

		exeinto "${generatordir}"
		doexe "${S}/usr/lib/systemd/system-generators/xswap-generator"

		insinto "${unitdir}/systemd-zram-setup@.service.d"
		doins "${S}/usr/lib/systemd/system/systemd-zram-setup@.service.d/xswap.conf"
	fi

	# udev helper called by 20-audio-pm.rules
	exeinto "${udevdir}"
	doexe "${S}/usr/lib/udev/audio-pm-ctl"

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
