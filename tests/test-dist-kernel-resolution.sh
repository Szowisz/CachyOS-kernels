#!/usr/bin/env bash
# Test script for dist-kernel dependency resolution and regression prevention
# Covers:
# 1. Git rename detection fixture verification (95a3aa54 detection)
# 2. Green test 1: All current kernel, virtual, and bin packages resolve with emerge --pretend
# 3. Red test 1: Issue #55 negative historical control (7.2.4 with dist-kernel-7.2.4.ebuild lacking _p0)
# 4. Green test 2: >=p2 dependency satisfied by _p3 provider (7.2.3-r2 with 7.2.3_p3)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== Dist-Kernel Dependency Resolution Test Suite ==="

# 1. Check git rename detection fixture (95a3aa54)
echo "--- Testing git diff rename detection on 95a3aa54 ---"
detected_version=$(git diff --no-renames --name-only --diff-filter=AM e464ee60 95a3aa54 | \
  grep -E "^sys-kernel/cachyos-sources/cachyos-sources-.*\.ebuild$" | \
  grep -v "9999" | \
  sed -E 's|^sys-kernel/cachyos-sources/cachyos-sources-(.+)\.ebuild$|\1|' | \
  sort -V || true)

if [ "${detected_version}" = "6.18.50" ]; then
  echo "PASS: git diff rename detection correctly extracted 6.18.50 from 95a3aa54"
else
  echo "FAIL: expected 6.18.50, got '${detected_version}'"
  exit 1
fi

# 2. Run Portage emerge --pretend tests in isolated Gentoo container
echo "--- Running emerge --pretend resolution tests in Gentoo container ---"
docker run --rm \
  -v "${REPO_ROOT}:/var/db/repos/CachyOS-kernels:ro" \
  -v /var/db/repos/gentoo:/var/db/repos/gentoo:ro \
  docker.io/gentoo/stage3:latest /bin/bash -c '
set -euo pipefail

mkdir -p /etc/portage/repos.conf /etc/portage/package.use
cat > /etc/portage/repos.conf/cachyos.conf <<EOF
[CachyOS-kernels]
location = /var/db/repos/CachyOS-kernels
auto-sync = no
priority = 50
EOF
echo "ACCEPT_KEYWORDS=\"~amd64\"" >> /etc/portage/make.conf
cat > /etc/portage/package.use/kernel <<EOF
>=dev-util/perf-7.2 libpfm
>=sys-kernel/installkernel-70 dracut
EOF

echo "=== TEST 1: Current snapshot (all 13 packages) ==="
pass_count=0
for f in /var/db/repos/CachyOS-kernels/sys-kernel/cachyos-kernel/cachyos-kernel-*.ebuild; do
  pkg=$(basename "$f" .ebuild)
  emerge --pretend "=sys-kernel/${pkg}" >/dev/null 2>&1
  echo "PASS: =sys-kernel/${pkg}"
  pass_count=$((pass_count + 1))
done

for f in /var/db/repos/CachyOS-kernels/virtual/dist-kernel/dist-kernel-*.ebuild; do
  pkg=$(basename "$f" .ebuild)
  emerge --pretend "=virtual/${pkg}" >/dev/null 2>&1
  echo "PASS: =virtual/${pkg}"
  pass_count=$((pass_count + 1))
done

for f in /var/db/repos/CachyOS-kernels/sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-*.ebuild; do
  pkg=$(basename "$f" .ebuild)
  emerge --pretend "=sys-kernel/${pkg}" >/dev/null 2>&1
  echo "PASS: =sys-kernel/${pkg}"
  pass_count=$((pass_count + 1))
done
echo "Total passed in current snapshot: ${pass_count} / 13"

echo "=== TEST 2: Negative control for Issue #55 (7.2.4 without _p0) ==="
temp_overlay=$(mktemp -d)
cp -a /var/db/repos/CachyOS-kernels/. "${temp_overlay}/"
mv "${temp_overlay}/virtual/dist-kernel/dist-kernel-7.2.4_p0.ebuild" "${temp_overlay}/virtual/dist-kernel/dist-kernel-7.2.4.ebuild"
sed -i "s|location = .*|location = ${temp_overlay}|" /etc/portage/repos.conf/cachyos.conf

set +e
out=$(emerge --pretend =sys-kernel/cachyos-kernel-7.2.4 2>&1)
res=$?
set -e
echo "Issue 55 reproduction exit code: ${res}"
if [ ${res} -ne 0 ] && echo "${out}" | grep -q "there are no ebuilds to satisfy \">=virtual/dist-kernel-7.2.4_p0\""; then
  echo "PASS: Issue #55 correctly caught (failed specifically with missing >=virtual/dist-kernel-7.2.4_p0)"
else
  echo "FAIL: Issue #55 not caught as expected! Output: ${out}"
  exit 1
fi

echo "=== TEST 3: >=p2 with p3 verification (7.2.3-r2 with 7.2.3_p3) ==="
emerge --pretend =sys-kernel/cachyos-kernel-7.2.3-r2 >/dev/null 2>&1
echo "PASS: 7.2.3-r2 (>=virtual/dist-kernel-7.2.3_p2) successfully satisfied by 7.2.3_p3"

rm -rf "${temp_overlay}"
'

echo "=== All Dist-Kernel Tests Passed Successfully ==="
