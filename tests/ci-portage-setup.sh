#!/usr/bin/env bash
# Producer syncs once. Consumers restore its repository, profile and USE config.
# Usage: ci-portage-setup.sh <glibc|musl> <repo-dir> [artifact-dir]
set -euo pipefail

ABI="${1:?missing ABI}"
REPO_DIR="${2:?missing checkout}"
ARTIFACT="${3:-}"
case "${ABI}" in
	glibc) BINHOST_URI="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/" ;;
	musl) BINHOST_URI="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64_musl_llvm/" ;;
	*) echo "Unknown ABI: ${ABI}" >&2; exit 2 ;;
esac

if [[ -n "${ARTIFACT}" ]]; then
	[[ "$(cat "${ARTIFACT}/abi")" == "${ABI}" ]] || { echo 'Wrong binpkg ABI' >&2; exit 1; }
	# Same immutable container image as the producer; no consumer sync.
	tar -xzf "${ARTIFACT}/inputs.tar.gz" -C /
	# Keep downloaded binaries separate from the read-only artifact binrepo.
	echo 'PKGDIR="/var/cache/ci-binpkgs"' >> /etc/portage/make.conf
else
	mkdir -p /etc/portage/{repos.conf,binrepos.conf,package.use,package.accept_keywords}
	cat > /etc/portage/binrepos.conf/gentoo.conf <<EOF
[DEFAULT]
frozen = true

[gentoobinhost]
priority = 10
sync-uri = ${BINHOST_URI}
verify-signature = true
EOF
	# Stable dependencies match the public binhost; only the tested overlay
	# package needs unstable keywords. Never set global USE for matrix cases.
	echo 'sys-kernel/cachyos-sources ~amd64' > /etc/portage/package.accept_keywords/ci
	echo "FEATURES=\"\${FEATURES} getbinpkg -news\"" >> /etc/portage/make.conf
	# Keep CI downloads off IPv6 addresses that may lack a usable route, and let
	# transient DNS resolution failures consume the same bounded retry budget.
	echo 'FETCHCOMMAND="${FETCHCOMMAND} --inet4-only --retry-on-host-error"' >> /etc/portage/make.conf
	echo 'RESUMECOMMAND="${RESUMECOMMAND} --inet4-only --retry-on-host-error"' >> /etc/portage/make.conf
	touch /etc/portage/package.use/zz-autounmask
	emerge --sync -q

	if [[ "${ABI}" == musl ]]; then
		# Only perf 7.1/7.2 have this Rust workload; stable 6.19 does not.
		for PERF_VERSION in 7.1 7.2; do
			mkdir -p "/etc/portage/patches/dev-util/perf-${PERF_VERSION}"
			cat > "/etc/portage/patches/dev-util/perf-${PERF_VERSION}/perf-musl-code-with-type-uint.patch" <<'PATCHEOF'
--- a/tests/workloads/code_with_type.c
+++ b/tests/workloads/code_with_type.c
@@ -6,7 +6,7 @@
 #include <linux/compiler.h>
 #include "../tests.h"

-extern void test_rs(uint count);
+extern void test_rs(unsigned int count);

 static volatile sig_atomic_t done;
PATCHEOF
		done
	fi
fi

mkdir -p /var/db/repos/cachyos-overlay /etc/portage/repos.conf
cp -a "${REPO_DIR}/." /var/db/repos/cachyos-overlay/
cat > /etc/portage/repos.conf/cachyos.conf <<EOF
[CachyOS-kernels]
location = /var/db/repos/cachyos-overlay
auto-sync = no
priority = 50
EOF

# Public binhost signatures are still required. No private signing keys.
getuto
