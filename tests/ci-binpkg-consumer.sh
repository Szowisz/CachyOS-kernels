#!/usr/bin/env bash
# Consume same-run dependencies, then install the actual target from source.
# Usage: ci-binpkg-consumer.sh <artifact-dir> <version> [USE flags]
set -euo pipefail

ARTIFACT="${1:?missing artifact}"
VERSION="${2:?missing version}"
USE_FLAGS="${3:-}"
test -s "${ARTIFACT}/pkgdir/Packages"
if ! grep -Fxq "${VERSION}|${USE_FLAGS}" "${ARTIFACT}/cases"; then
	echo "Case not covered by producer: ${VERSION} USE=${USE_FLAGS}" >&2
	exit 1
fi

cat > /etc/portage/binrepos.conf/ci-binhost.conf <<EOF
[ci-binhost]
priority = 0
sync-uri = file://${ARTIFACT}/pkgdir
verify-signature = false
EOF
# Only this run's local binrepo is unsigned. Public binhost remains preferred
# and signature-checked; the producer's dependency autounmask edits stay active.
printf '=sys-kernel/cachyos-sources-%s %s\n' "${VERSION}" "${USE_FLAGS}" \
	> /etc/portage/package.use/ci-case

# -K requires a binary of the explicit target even with --onlydeps. Instead,
# verify Portage's dependency-only plan contains no source merges. The repo,
# profile, config and binhost indexes are frozen across these two invocations.
DEP_OPTS=(--verbose --color=n --onlydeps --usepkg --getbinpkg
	--autounmask=n --binpkg-respect-use=y
	--usepkg-exclude sys-kernel/cachyos-sources)
PLAN=$(mktemp)
trap 'rm -f "${PLAN}"' EXIT
emerge --pretend "${DEP_OPTS[@]}" "=sys-kernel/cachyos-sources-${VERSION}" | tee "${PLAN}"
if grep -Eq '^\[ebuild[[:space:]]' "${PLAN}"; then
	echo 'Missing dependency binary; refusing repeated source builds. Re-run all jobs.' >&2
	exit 1
fi
emerge "${DEP_OPTS[@]}" "=sys-kernel/cachyos-sources-${VERSION}"

# Sources package only installs the prepared source tree, not a compiled kernel.
emerge --verbose --nodeps --usepkg=n --getbinpkg=n --buildpkg=n \
	"=sys-kernel/cachyos-sources-${VERSION}"
