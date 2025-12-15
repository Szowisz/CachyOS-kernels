# Copyright 2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Virtual for CachyOS kernel sources"
SLOT="0"
KEYWORDS="~amd64"
IUSE="hardened"

RDEPEND="sys-kernel/cachyos-sources[hardened?]"
