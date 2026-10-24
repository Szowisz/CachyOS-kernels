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

# Unmasked new binaries must also choose p3 without a same-slot source kernel.
for flags in "" "-cachyos bmq lto -gcc"; do
  out=$(USE="${flags}" emerge --pretend =sys-kernel/cachyos-kernel-bin-7.3.0-r3 2>&1)
  echo "${out}" | grep -q "virtual/dist-kernel-7.3.0_p3"
  if echo "${out}" | grep -q "sys-kernel/cachyos-kernel-[0-9]"; then
    echo "FAIL: unmasked binary pulled source-built kernel: ${out}"
    exit 1
  fi
  echo "PASS: unmasked binary USE=${flags} resolves through p3 without source-built kernel"
done
# Real Portage must reject conflicting schedulers and tick modes before phases.
for package in sources kernel; do
  tick=hz-ticks-100
  [[ ${package} != kernel ]] || tick=hz_ticks_100
  for flags in "muqss" "${tick}"; do
    set +e
    out=$(USE="${flags}" emerge --pretend "=sys-kernel/cachyos-${package}-7.3.0-r3" 2>&1)
    res=$?
    set -e
    if [[ ${res} -eq 0 ]] || ! grep -q "REQUIRED_USE" <<< "${out}"; then
      echo "FAIL: conflicting USE=${flags} accepted for ${package}: ${out}"
      exit 1
    fi
    echo "PASS: real Portage rejects ${package} USE=${flags} against defaults (exit ${res})"
  done
done

# A retained binary must resolve without pulling an unrelated newer kernel.
mkdir -p /etc/portage/package.mask
for pair in "7.3.0-r3 7.3.0_p3" "7.2.9-r1 7.2.9_p1" "6.18.55-r1 6.18.55"; do
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
# BMQ must use the same binary provider, without a same-slot source kernel.
printf "%s\n" "virtual/dist-kernel::gentoo" ">virtual/dist-kernel-7.3.0_p3" > /etc/portage/package.mask/provider
out=$(USE="-cachyos bmq lto -gcc" emerge --pretend =sys-kernel/cachyos-kernel-bin-7.3.0-r3 2>&1)
echo "${out}" | grep -q "virtual/dist-kernel-7.3.0_p3"
if echo "${out}" | grep -q "sys-kernel/cachyos-kernel-[0-9]"; then
  echo "FAIL: BMQ binary pulled a source-built kernel: ${out}"
  exit 1
fi
echo "PASS: BMQ binary resolves without source-built kernel"
out=$(emerge --pretend =sys-kernel/cachyos-kernel-7.3.0-r3 2>&1)
echo "${out}" | grep -q "virtual/dist-kernel-7.3.0_p3"
emerge --pretend =sys-kernel/cachyos-sources-7.3.0-r3 >/dev/null 2>&1
echo "PASS: source r3 resolves; kernel r3 resolves through p3"
rm /etc/portage/package.mask/provider

# A source-only current provider must reproduce the same-slot binary conflict.
current_fixture=$(mktemp -d /var/tmp/cachyos-current-resolution.XXXXXX)
chmod 755 "${current_fixture}"
for directory in metadata profiles sys-kernel virtual; do
  cp -a "/var/db/repos/CachyOS-kernels/${directory}" "${current_fixture}/"
done
sed -i "/=sys-kernel\/cachyos-kernel-bin-7.3.0-r3/d" "${current_fixture}/virtual/dist-kernel/dist-kernel-7.3.0_p3.ebuild"
sed -i "s|location = .*|location = ${current_fixture}|" /etc/portage/repos.conf/cachyos.conf
printf "%s\n" "virtual/dist-kernel::gentoo" ">virtual/dist-kernel-7.3.0_p3" > /etc/portage/package.mask/current
set +e
out=$(emerge --pretend =sys-kernel/cachyos-kernel-bin-7.3.0-r3 2>&1)
res=$?
set -e
if [[ ${res} -eq 0 ]] || ! grep -q "cannot be" <<< "${out}" || ! grep -q "sys-kernel/cachyos-kernel:7.3.0" <<< "${out}"; then
  echo "FAIL: current source-only provider did not reproduce conflict: ${out}"
  exit 1
fi
echo "PASS: current source-only p3 provider fails with same-slot conflict (exit ${res})"
rm /etc/portage/package.mask/current
rm -rf "${current_fixture}"
sed -i "s|location = .*|location = /var/db/repos/CachyOS-kernels|" /etc/portage/repos.conf/cachyos.conf

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
