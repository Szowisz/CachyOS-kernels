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
# Historical controls must survive normal package cleanup.
fixtures=$(mktemp -d /var/tmp/cachyos-resolution.XXXXXX)
chmod 755 "${fixtures}"
trap 'rm -rf "${fixtures}"' EXIT
for path in \
  sys-kernel/cachyos-kernel/cachyos-kernel-7.2.4.ebuild \
  sys-kernel/cachyos-kernel/cachyos-kernel-7.2.3-r2.ebuild \
  virtual/dist-kernel/dist-kernel-7.2.4_p0.ebuild \
  virtual/dist-kernel/dist-kernel-7.2.3_p3.ebuild; do
  mkdir -p "${fixtures}/$(dirname "${path}")"
  git show "99fab221:${path}" > "${fixtures}/${path}"
done

docker run --pull=never --rm \
  -v "${fixtures}:/historical:ro" \
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

echo "=== TEST 1: Current snapshot ==="
expected_count=$(find \
  /var/db/repos/CachyOS-kernels/sys-kernel/cachyos-kernel \
  /var/db/repos/CachyOS-kernels/virtual/dist-kernel \
  /var/db/repos/CachyOS-kernels/sys-kernel/cachyos-kernel-bin \
  -maxdepth 1 -name '*.ebuild' | wc -l)
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
echo "Total passed in current snapshot: ${pass_count} / ${expected_count}"
if [ "${pass_count}" -ne "${expected_count}" ]; then
  echo "FAIL: expected ${expected_count} packages, resolved ${pass_count}"
  exit 1
fi

# A retained binary must resolve without pulling an unrelated newer kernel.
mkdir -p /etc/portage/package.mask
for pair in "7.2.11 7.2.11_p0" "7.2.9-r1 7.2.9_p1"; do
  read -r binary provider <<< "${pair}"
  printf "%s\n" "virtual/dist-kernel::gentoo" ">virtual/dist-kernel-${provider}" > /etc/portage/package.mask/provider
  out=$(emerge --pretend "=sys-kernel/cachyos-kernel-bin-${binary}" 2>&1)
  echo "${out}" | grep -q "virtual/dist-kernel-${provider}"
  if echo "${out}" | grep -q "sys-kernel/cachyos-kernel-[0-9]"; then
    echo "FAIL: binary pulled a source-built kernel: ${out}"
    exit 1
  fi
  echo "PASS: retained binary ${binary} resolves via ${provider} without source-built kernel"
done
rm /etc/portage/package.mask/provider

echo "=== TEST 2: Negative control for Issue #55 (7.2.4 without _p0) ==="
temp_overlay=$(mktemp -d /var/tmp/cachyos-resolution.XXXXXX)
chmod 755 "${temp_overlay}"
for directory in metadata profiles sys-kernel virtual; do
  cp -a "/var/db/repos/CachyOS-kernels/${directory}" "${temp_overlay}/"
done
cp -a /historical/. "${temp_overlay}/"
mv "${temp_overlay}/virtual/dist-kernel/dist-kernel-7.2.4_p0.ebuild" "${temp_overlay}/virtual/dist-kernel/dist-kernel-7.2.4.ebuild"
rm -f "${temp_overlay}/virtual/dist-kernel/dist-kernel-7.2.5_p0.ebuild"
mkdir -p /etc/portage/package.mask
printf "%s\n" "virtual/dist-kernel::gentoo" ">virtual/dist-kernel-7.2.4" > /etc/portage/package.mask/issue55
sed -i "s|location = .*|location = ${temp_overlay}|" /etc/portage/repos.conf/cachyos.conf

set +e
out=$(emerge --pretend =sys-kernel/cachyos-kernel-7.2.4 2>&1)
res=$?
set -e
echo "Issue 55 reproduction exit code: ${res}"
if [ ${res} -ne 0 ] && echo "${out}" | grep -q ">=virtual/dist-kernel-7.2.4_p0"; then
  echo "PASS: Issue #55 correctly caught (failed specifically with missing >=virtual/dist-kernel-7.2.4_p0)"
else
  echo "FAIL: Issue #55 not caught as expected! Output: ${out}"
  exit 1
fi

echo "=== TEST 3: >=p2 with p3 verification (7.2.3-r2 with 7.2.3_p3) ==="
printf "%s\n" "virtual/dist-kernel::gentoo" ">virtual/dist-kernel-7.2.3_p3" > /etc/portage/package.mask/issue55
emerge --pretend =sys-kernel/cachyos-kernel-7.2.3-r2 >/dev/null 2>&1
echo "PASS: 7.2.3-r2 (>=virtual/dist-kernel-7.2.3_p2) successfully satisfied by 7.2.3_p3"

rm -rf "${temp_overlay}"
'

echo "=== All Dist-Kernel Tests Passed Successfully ==="
