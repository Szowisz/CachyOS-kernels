# Copyright 2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v3

EAPI=8

ANANICY_COMMIT="ebf4fa421e128ccb3c16e4a0cbff4a00d06aacdc" # for rules
MYPV="${PV/_rc/-rc}"

inherit cmake

DESCRIPTION="Ananicy rewritten in C++ with CachyOS rules"
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
	sys-auth/rtkit
"

src_prepare() {
	default

	# GCC 16 no longer exposes getpid() transitively via unrelated headers.
	# Upstream still misses the direct include in v1.2.0.
	sed -i '/#include <string_view>/a #include <unistd.h>' \
		src/platform/linux/debug.cpp || die
	sed -i '/#include <thread>/a #include <unistd.h>' \
		src/platform/linux/process.cpp || die
	sed -i '/#include <systemd\/sd-login.h>/a #include <unistd.h>' \
		src/platform/systemd/service.cpp || die

	cmake_prepare
}

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
