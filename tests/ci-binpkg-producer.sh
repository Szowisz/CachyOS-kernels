#!/usr/bin/env bash
# Build missing dependency instances once; never build/install the source target.
# Usage: ci-binpkg-producer.sh <versions-file> <glibc|musl>
set -euo pipefail

VERSIONS_FILE="${1:?missing versions file}"
ABI="${2:?missing ABI}"
OUT="${CI_BINPKG_OUT:-/ci-binpkg}"
mkdir -p "${OUT}/pkgdir" /etc/portage/package.use
python3 /var/db/repos/cachyos-overlay/tests/ci_matrix_cases.py \
	--versions-file "${VERSIONS_FILE}" --abi "${ABI}" > "${OUT}/cases"

echo "FEATURES=\"\${FEATURES} buildpkg binpkg-multi-instance -binpkg-signing\"" >> /etc/portage/make.conf
printf 'PKGDIR="%s/pkgdir"\n' "${OUT}" >> /etc/portage/make.conf
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
rm /etc/portage/package.use/ci-case

# Standard PKGDIR-aware indexing; an empty local binhost is valid.
emaint binhost --fix
test -s "${OUT}/pkgdir/Packages"
printf '%s\n' "${ABI}" > "${OUT}/abi"
# Includes profile symlink, autounmask edits, patches and frozen public index.
# No keys: consumers bootstrap official public keys themselves with getuto.
mkdir -p /var/cache/edb/binhost
tar --exclude=etc/portage/gnupg -czf "${OUT}/inputs.tar.gz" -C / \
	etc/portage var/db/repos/gentoo var/cache/edb/binhost
