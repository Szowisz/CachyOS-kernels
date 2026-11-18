# Copyright 2025-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Virtual for CachyOS kernel sources"
SLOT="0"
KEYWORDS="~amd64"
IUSE="cachyos-hardened"

RDEPEND="
	cachyos-hardened? ( sys-kernel/cachyos-sources[cachyos-hardened(-)] )
	!cachyos-hardened? ( sys-kernel/cachyos-sources )
"
