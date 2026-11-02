#!/usr/bin/env bash
# Shared kernel Kbuild check for an installed cachyos-sources tree.
# Modes:
#   olddefconfig - synchronize the shipped config, then assert the effective
#                  case (ebuild defaults + USE overrides) survived.
#   sched        - olddefconfig + compile kernel/sched/ (real C objects;
#                  alternative schedulers build through Kbuild). C-only:
#                  does not cover the Rust toolchain; see evidence comment.
#   full         - olddefconfig + compile bzImage and modules with real
#                  links. Fails if Rust or selected tooling is lost.
# Usage: ci-kernel-kbuild.sh <olddefconfig|sched|full> <ebuild> <source-tree> <USE> [log-dir]
set -uo pipefail

MODE="${1:?missing mode}"
EBUILD="${2:?missing ebuild path}"
TREE="${3:?missing source tree}"
USE_FLAGS="${4:-}"
EVIDENCE="${5:-}"

declare -a MKARGS=() USE_WORDS=()
read -r -a USE_WORDS <<< "${USE_FLAGS}"

STATUS=failed
RUST_WAS=off
JOBS="${JOBS:-$(nproc)}"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_SECONDS=$SECONDS
die() { echo "$*" >&2; exit 1; }

record_evidence() {
	local status=$1 exit_code=$2
	[[ -n "${EVIDENCE}" ]] || return 0
	mkdir -p "${EVIDENCE}"
	{
		echo "mode=${MODE} ebuild=${EBUILD##*/} tree=${TREE} use=${USE_FLAGS}"
		echo "status=${status} exit_code=${exit_code} jobs=${JOBS} mkargs=${MKARGS[*]}"
		echo "started=${STARTED}"
		echo "elapsed_seconds=$((SECONDS - START_SECONDS))"
		# sched/olddefconfig are C-only checks; say so in the evidence.
		echo "rust=${RUST_WAS}"
		for tool in clang gcc rustc bindgen ccache make; do
			if command -v "${tool}" >/dev/null; then
				printf '%s=%s\n' "${tool}" "$("${tool}" --version 2>/dev/null | head -1)"
			else
				echo "${tool}=missing"
			fi
		done
		echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "${EVIDENCE}/toolchain.env"
	# Latest synchronized config is the evidence, never a stale pre-sync copy.
	if [[ -f "${TREE}/.config" ]]; then
		cp "${TREE}/.config" "${EVIDENCE}/config.final"
	else
		printf '# .config unavailable at exit\n' > "${EVIDENCE}/config.final"
	fi
}

finish() {
	local code=$?
	trap - EXIT
	if ! record_evidence "${STATUS}" "${code}"; then
		echo "Could not save kernel build evidence" >&2
		((code == 0)) && code=1
	fi
	exit "${code}"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -f "${TREE}/.config" || ! -f "${TREE}/Makefile" || ! -f "${EBUILD}" ]]; then
	echo "Need ebuild + configured kernel tree: ${EBUILD} ${TREE}" >&2
	exit 2
fi

# Derive the toolchain from the shipped config's selected LLVM features, not
# the stale CC_IS_* marker: config decides clang vs gcc, never the flag name.
need_clang() {
	for symbol in LTO_CLANG_THIN LTO_CLANG_THIN_DIST LTO_CLANG_FULL \
		AUTOFDO_CLANG PROPELLER_CLANG CFI; do
		grep -q "^CONFIG_${symbol}=y$" "${TREE}/.config" && return 0
	done
	return 1
}

have_rust() { grep -q "^CONFIG_RUST=y$" "${TREE}/.config"; }

check_rust_tools() {
	local missing=()
	command -v rustc >/dev/null || missing+=(rustc)
	command -v bindgen >/dev/null || missing+=(bindgen)
	if ((${#missing[@]})); then
		echo "Rust enabled in config but toolchain missing: ${missing[*]}" >&2
		return 1
	fi
}

# Full builds leave CPU/memory headroom for LTO and evidence handling.
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
if [[ "${MODE}" == full ]] && ((JOBS > 2)); then
	JOBS=2
fi
MKARGS+=("KBUILD_BUILD_TIMESTAMP=1970-01-01" "KBUILD_BUILD_USER=ci" "KBUILD_BUILD_HOST=ci")
[[ "${MODE}" == full ]] && MKARGS+=(V=1)

kmake() {
	# shellcheck disable=SC2086
	make -C "${TREE}" ${CI_MAKE_FLAGS:-} -j"${JOBS}" "${MKARGS[@]}" "$@"
}


# LLVM features require clang; LLVM-only stage3 also uses it without LTO.
if need_clang || ! command -v gcc >/dev/null; then
	command -v clang >/dev/null || die "clang required by selected features or native toolchain; not installed"
	COMPILER=clang
	MKARGS+=(LLVM=1 LLVM_IAS=1)
else
	COMPILER=gcc
fi

# Cache only compiler results, never a prepared source/object tree.
if [[ "${MODE}" == full && -n "${CCACHE_DIR:-}" ]] && command -v ccache >/dev/null; then
	mkdir -p "${CCACHE_DIR}" || die "Could not create compiler cache"
	ccache -M "${CCACHE_LIMIT:-2G}" >/dev/null || die "Could not limit compiler cache"
	MKARGS+=("CC=ccache ${COMPILER}" "HOSTCC=ccache ${COMPILER}")
else
	MKARGS+=("CC=${COMPILER}")
fi

# Pre-sync toolchain check: a full build must not proceed when Rust is
# configured but the toolchain cannot keep it through olddefconfig.
if have_rust; then
	if [[ "${MODE}" == full ]]; then
		check_rust_tools || die "full build requires the configured Rust toolchain"
		RUST_WAS=y
	elif ! check_rust_tools; then
		# C-only sched/olddefconfig fast paths cannot rebuild Rust objects;
		# record the limitation in evidence instead of claiming coverage.
		RUST_WAS=limited
	else
		RUST_WAS=y
	fi
fi

# Configuration synchronization first: Kconfig dependency resolution can
# drop selected features (missing LLVM, Rust or profiles), and the check
# must detect that instead of compiling a silently stripped tree.
kmake olddefconfig || exit

# Effective-case preservation: ebuild defaults and requested overrides must
# survive olddefconfig on every retained version/path. The expectation list
# comes from the shared ci_kernel_expected.py so this stays one place.
EXPECTED=$(python3 "$(dirname "${BASH_SOURCE[0]}")/ci_kernel_expected.py" \
	expected "${EBUILD}" "${USE_WORDS[@]}") || exit 2
[[ -z "${EXPECTED}" ]] &&
	die "no config expectations for ${EBUILD##*/} USE='${USE_FLAGS}' (broken helper)"
while IFS= read -r line; do
	[[ -n "${line}" ]] || continue
	if [[ "${line}" == "# CONFIG_"*" is not set" ]]; then
		# Negative expectation = the feature must not be enabled. A symbol
		# absent from this tree's Kconfig also counts as off (e.g. SCHED_BMQ
		# only exists once a PRJC patch applied it).
		symbol="${line#\# CONFIG_}"
		symbol="${symbol% is not set}"
		grep -Eq "^CONFIG_${symbol}=[ym]" "${TREE}/.config" &&
			die "Feature must stay off but is enabled: CONFIG_${symbol}"
	else
		grep -Fxq "${line}" "${TREE}/.config" ||
			die "Feature lost in olddefconfig: expected '${line}'"
	fi
done <<< "${EXPECTED}"

if have_rust; then
	if [[ "${MODE}" == full ]]; then
		# Full must never silently weaken the config.
		check_rust_tools || die "Rust toolchain lost before build"
		RUST_WAS=y
	elif ! check_rust_tools; then
		echo "note: CONFIG_RUST kept, but rustc/bindgen unavailable; C-only coverage" >&2
		RUST_WAS=limited
	fi
elif [[ "${RUST_WAS}" == y || "${RUST_WAS}" == limited ]]; then
	echo "CONFIG_RUST=y lost during olddefconfig (toolchain missing at sync time)" >&2
	RUST_WAS=lost
	[[ "${MODE}" == full ]] && exit 1
fi

case "${MODE}" in
	olddefconfig) ;;
	sched)
		# Real scheduler-directory compilation. Kbuild picks fair.o, bmq,
		# pds, MuQSS or the alt objects per .config; never force fair.o.
		kmake kernel/sched/ || exit
		;;
	full)
		# Whole kernel image and all configured modules with real linking.
		kmake bzImage || exit
		kmake modules || exit
		;;
	*)
		echo "Unknown mode: ${MODE}" >&2
		exit 2
		;;
esac
STATUS=passed
