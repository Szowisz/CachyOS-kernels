#!/usr/bin/env bash
# Build missing dependency instances once; never build/install the source target.
# Usage: ci-binpkg-producer.sh <versions-file> <glibc|musl>
#          [--case '<version>|<use>'] [--extra-deps '<atom> [<atom>...]']
# Without --case, dependencies are produced for the whole merge matrix of
# every listed version. --case restricts production to one already-validated
# manual case; --extra-deps adds explicit build-tool atoms to the same plan.
set -euo pipefail

VERSIONS_FILE="${1:?missing versions file}"
ABI="${2:?missing ABI}"
shift 2
ONLY_CASE=""
EXTRA_DEPS=""
while (($#)); do
	case "$1" in
		--case) ONLY_CASE="${2:?--case needs <version>|<use>}"; shift 2 ;;
		--extra-deps) EXTRA_DEPS="${2:?--extra-deps needs atoms}"; shift 2 ;;
		# Backward-compatible positional third arg = --case.
		*) ONLY_CASE="$1"; shift ;;
	esac
done
OUT="${CI_BINPKG_OUT:-/ci-binpkg}"
mkdir -p "${OUT}/pkgdir" /etc/portage/package.use
if [[ -n "${ONLY_CASE}" ]]; then
	# Manual dispatch: enumerate only the validated requested case, never the
	# entire unrelated matrix for the same version.
	printf '%s\n' "${ONLY_CASE}" > "${OUT}/cases"
else
	python3 /var/db/repos/cachyos-overlay/tests/ci_matrix_cases.py \
		--versions-file "${VERSIONS_FILE}" --abi "${ABI}" > "${OUT}/cases"
fi

echo "FEATURES=\"\${FEATURES} buildpkg binpkg-multi-instance -binpkg-signing\"" >> /etc/portage/make.conf
printf 'PKGDIR="%s/pkgdir"\n' "${OUT}" >> /etc/portage/make.conf
# Keep the dependency autounmask scratch file separate from the case file.
touch /etc/portage/package.use/zz-autounmask
while IFS='|' read -r version flags; do
	# Replace, not accumulate: contradictory cases for one version must not mix.
	printf '=sys-kernel/cachyos-sources-%s %s\n' "${version}" "${flags}" \
		> /etc/portage/package.use/ci-case
	echo "=== Dependencies: ${version} USE=${flags} ==="
	emerge --verbose --oneshot --onlydeps --usepkg --getbinpkg --buildpkg \
		--autounmask --autounmask-continue --autounmask-write \
		--usepkg-exclude sys-kernel/cachyos-sources \
		"=sys-kernel/cachyos-sources-${version}"
done < "${OUT}/cases"
rm -f /etc/portage/package.use/ci-case

# Genuine Kbuild prerequisites (ccache, Rust/bindgen for a configured Rust
# build, bc, elfutils) are provisioned here once; consumers install the
# binaries only. They are CI tooling, not ebuild RDEPEND.
if [[ -n "${EXTRA_DEPS}" ]]; then
	read -r -a extra_deps <<< "${EXTRA_DEPS}"
	emerge --verbose --oneshot --usepkg --getbinpkg --buildpkg \
		--autounmask --autounmask-continue --autounmask-write \
		"${extra_deps[@]}"
	# Record extra deps as covered cases too: a consumer for a version that
	# was only built via the matrix still refuses them.
	printf '%s\n' "${extra_deps[@]}" >> "${OUT}/cases"
	sort -u -o "${OUT}/cases" "${OUT}/cases"
fi

# Standard PKGDIR-aware indexing; an empty local binhost is valid.
emaint binhost --fix
test -s "${OUT}/pkgdir/Packages"
printf '%s\n' "${ABI}" > "${OUT}/abi"
# Includes profile symlink, autounmask edits, patches and frozen public index.
# No keys: consumers bootstrap official public keys themselves with getuto.
mkdir -p /var/cache/edb/binhost
tar --exclude=etc/portage/gnupg -czf "${OUT}/inputs.tar.gz" -C / \
	etc/portage var/db/repos/gentoo var/cache/edb/binhost
