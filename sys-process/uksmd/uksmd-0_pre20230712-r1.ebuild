# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

inherit linux-info meson systemd

MY_COMMIT="97b7f88f984e98288ad972e01990ef3fa681a735"

DESCRIPTION="Userspace KSM helper daemon"
HOMEPAGE="https://github.com/CachyOS/uksmd"
SRC_URI="https://github.com/CachyOS/uksmd/archive/${MY_COMMIT}.tar.gz"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64 ~x86"

DEPEND="sys-libs/libcap-ng
	sys-process/procps:="
RDEPEND="${DEPEND}"

PATCHES=(
	"${FILESDIR}/0001-uksmdstats-fixes.patch"
	"${FILESDIR}/0002-translate.patch"
)

CONFIG_CHECK="~KSM"

S="${WORKDIR}/uksmd-${MY_COMMIT}"


src_install() {
	meson_src_install

	newinitd "${FILESDIR}/uksmd.init" uksmd
	systemd_dounit uksmd.service
}
