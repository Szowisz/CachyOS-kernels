# Copyright 1999-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{11..15} )
VERIFY_SIG_OPENPGP_KEY_PATH=/usr/share/openpgp-keys/arnaldocarvalhodemelo.asc
inherit cmake python-single-r1 verify-sig

MY_P="dwarves-${PV}"
PAHOLE_PATCHES_COMMIT="4235eec8e257993ea4d5d0016d2f0845014d2ee8"
PAHOLE_PATCH_URI="https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDs/${PAHOLE_PATCHES_COMMIT}/pahole"

DESCRIPTION="pahole (Poke-a-Hole) and other DWARF utilities"
HOMEPAGE="https://git.kernel.org/cgit/devel/pahole/pahole.git/"
SRC_URI="
	http://fedorapeople.org/~acme/dwarves/${MY_P}.tar.xz
	verify-sig? ( http://fedorapeople.org/~acme/dwarves/${MY_P}.tar.sign )
	${PAHOLE_PATCH_URI}/0002-dwarf_loader-Take-the-merged-CU-language-from-a-CU-t.patch
		-> pahole-${PAHOLE_PATCHES_COMMIT}-merged-cu-language.patch
	${PAHOLE_PATCH_URI}/0003-dwarf_loader-Load-types-that-kept-CUs-use-from-exclu.patch
		-> pahole-${PAHOLE_PATCHES_COMMIT}-excluded-cu-types.patch
"
S="${WORKDIR}/${MY_P}"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64"
IUSE="debug"
REQUIRED_USE="${PYTHON_REQUIRED_USE}"

RDEPEND="${PYTHON_DEPS}
	>=dev-libs/elfutils-0.178
	virtual/zlib:=
	elibc_musl? (
		sys-libs/obstack-standalone
		sys-libs/argp-standalone
	)
"
DEPEND="${RDEPEND}"
BDEPEND="verify-sig? ( sec-keys/openpgp-keys-arnaldocarvalhodemelo )"

DOCS=( README README.ctracer NEWS )
PATCHES=(
	"${FILESDIR}/${PN}-1.10-python-import.patch"
	"${DISTDIR}/pahole-${PAHOLE_PATCHES_COMMIT}-merged-cu-language.patch"
	"${DISTDIR}/pahole-${PAHOLE_PATCHES_COMMIT}-excluded-cu-types.patch"
)

src_unpack() {
	if use verify-sig; then
		verify-sig_uncompress_verify_unpack "${DISTDIR}/${MY_P}.tar.xz" \
			"${DISTDIR}/${MY_P}.tar.sign"
	else
		default
	fi
}

src_prepare() {
	cmake_src_prepare
	python_fix_shebang ostra/ostra-cg ostra/python/ostra.py
	# Keep upstream's test fixtures inside the Portage sandbox.
	sed -i 's|test_master_dir="/tmp/pahole-tests"|test_master_dir="${TMPDIR:-/tmp}/pahole-tests"|' \
		tests/test_lib.sh || die
}

src_test() {
	local -x PATH="${BUILD_DIR}:${PATH}" TMPDIR="${T}"
	local regression rc
	for regression in lang_exclude_merged_cu lang_exclude_lto_refs; do
		sh "${S}/tests/${regression}.sh"
		rc=$?
		# Exit status 2 is upstream's test_skip (missing gcc/clang/lld).
		if [[ ${rc} -eq 2 ]]; then
			ewarn "${regression} skipped"
		elif [[ ${rc} -ne 0 ]]; then
			die "${regression} failed"
		fi
	done
}
