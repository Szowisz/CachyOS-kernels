# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

ANANICY_COMMIT="5a46bac4c681d9daaf3ffccecf373c42c84270dd" # for rules
MYPV="${PV/_rc/-rc}"

inherit cmake

DESCRIPTION="Ananicy rewritten in C++ for much lower CPU and memory usage (powered by CachyOS rules)"
HOMEPAGE="https://gitlab.com/ananicy-cpp/ananicy-cpp"
SRC_URI="
	https://gitlab.com/ananicy-cpp/ananicy-cpp/-/archive/v${MYPV}/${PN}-v${MYPV}.tar.bz2
	https://github.com/CachyOS/ananicy-rules/archive/${ANANICY_COMMIT}.tar.gz -> ananicy-rules-${ANANICY_COMMIT}.tar.gz
"
S="${WORKDIR}/${PN}-v${MYPV}"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"
IUSE="systemd"

RDEPEND="
	dev-cpp/nlohmann_json
	dev-libs/libfmt
	dev-libs/spdlog
	systemd? ( sys-apps/systemd )
"
DEPEND="
	${RDEPEND}
	dev-cpp/std-format
	sys-auth/rtkit
"

PATCHES=(
	"${FILESDIR}/${P}-system-std-format.patch"
)

src_configure() {
	local mycmakeargs=(
		-DENABLE_SYSTEMD=$(usex systemd)
		-DUSE_EXTERNAL_FMTLIB=ON
		-DUSE_EXTERNAL_JSON=ON
		-DUSE_EXTERNAL_SPDLOG=ON
	)
	cmake_src_configure
}

src_install() {
	cmake_src_install
	doinitd "${FILESDIR}/${PN}.initd"
	insinto /etc
	mv "${WORKDIR}/ananicy-rules-${ANANICY_COMMIT}" "${WORKDIR}/ananicy.d" || die
	doins -r "${WORKDIR}/ananicy.d"
}
