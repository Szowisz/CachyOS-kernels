# Copyright 2021-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Virtual to depend on any Distribution Kernel"
SLOT="0/${PVR}"
KEYWORDS="~amd64"

RDEPEND="
	|| (
		~sys-kernel/cachyos-kernel-${PV}
		~sys-kernel/cachyos-kernel-bin-${PV}
		~sys-kernel/gentoo-kernel-${PV}
		~sys-kernel/gentoo-kernel-bin-${PV}
		~sys-kernel/vanilla-kernel-${PV%_p*}
	)
"
