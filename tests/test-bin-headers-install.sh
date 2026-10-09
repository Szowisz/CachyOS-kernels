#!/usr/bin/env bash
# Issue #57: execute real bin src_install functions with synthetic packages,
# then check the installed tree and real ROOT-scoped eselect list/set.
# Portage filesystem helpers are stubbed; no downloads, kernel builds or merges.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v eselect >/dev/null || { echo 'FATAL: eselect not installed' >&2; exit 1; }
run=$(mktemp -d "${TMPDIR:-/var/tmp}/cachyos-bin-issue57.XXXXXX")
trap 'rm -rf "$run"' EXIT

inherit() { :; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ewarn() { printf 'WARN: %s\n' "$*" >&2; }
use() { [[ " $USE " == *" $1 "* ]]; }
ver_cut() { [[ $1 == 1-3 ]] || die "Unsupported ver_cut: $1"; printf '%s\n' "$PV"; }
dodir() { local p; for p; do mkdir -p "${ED}${p}"; done; }
insinto() { insdest=$1; mkdir -p "${ED}${insdest}"; }
doins() { cp "$@" "${ED}${insdest}/"; }
newins() { cp "$1" "${ED}${insdest}/$2"; }
dosym() { mkdir -p "${ED}$(dirname "$2")"; ln -s "$1" "${ED}$2"; }
dostrip() { :; }
kernel-install_compress_modules() { compress_called=1; }

make_fixture() {
	mkdir -p "$h/include/linux" "$h/scripts/basic" "$h/arch/x86/include" \
		"$b/kernel" "$WORKDIR/modprep/scripts/basic" "$WORKDIR/modprep/include/config"
	printf 'fixture-modules\n' > "$b/modules.order"
	# CachyOS ships modules already zstd-compressed.
	printf 'fixture-module\n' > "$b/kernel/fixture.ko.zst"
	printf 'FIXTURE-VMLINUZ\n' > "$b/vmlinuz"
	printf 'fixture-map\n' > "$h/System.map"
	printf 'CONFIG_MODULES=y\n' > "$h/.config"
	printf 'VERSION = %s\n' "${PV%%.*}" > "$h/Makefile"
	printf 'mainmenu "Linux Kernel Configuration"\n' > "$h/Kconfig"
	printf 'fixture-symvers\n' > "$h/Module.symvers"
	printf 'fixture-module-h\n' > "$h/include/linux/module.h"
	printf 'fixture-build\n' > "$h/scripts/Makefile.build"
	printf 'fixture-arch-header\n' > "$h/arch/x86/include/fixture.h"
	printf '#!/bin/sh\necho upstream-fixdep\n' > "$h/scripts/basic/fixdep"
	printf '#!/bin/sh\necho upstream-sign-file\n' > "$h/scripts/sign-file"
	chmod 0755 "$h/scripts/basic/fixdep" "$h/scripts/sign-file"
	# Local tools must replace upstream executables without replacing Kbuild files.
	printf '#!/bin/sh\necho local-fixdep\n' > "$WORKDIR/modprep/scripts/basic/fixdep"
	chmod 0755 "$WORKDIR/modprep/scripts/basic/fixdep"
	printf '%s\n' "$KV_FULL" > "$WORKDIR/modprep/include/config/kernel.release"
	# Upstream Kconfig output must survive the locally regenerated copy.
	mkdir -p "$h/include/config" "$h/include/generated" "$WORKDIR/modprep/include/generated"
	printf '%s\n' "$KV_FULL" > "$h/include/config/kernel.release"
	local g
	for g in config/auto.conf generated/autoconf.h generated/compile.h generated/rustc_cfg; do
		printf 'upstream %s\n' "$g" > "$h/include/$g"
		printf 'local %s\n' "$g" > "$WORKDIR/modprep/include/$g"
	done
	printf 'CONFIG_MODULES=y\nCONFIG_LOCAL=y\n' > "$WORKDIR/modprep/.config"
	printf 'drop-me\n' > "$WORKDIR/modprep/Makefile"
	printf 'drop-me\n' > "$WORKDIR/modprep/scripts/basic/fixdep.o"
}

run_case() (
	local tag=$1 USE=$2 invalid=${3:-} compress_called=0
	_cachyos_setup_kv
	WORKDIR=$run/$PF/$tag/work ED=$run/$PF/$tag/image
	local h=$WORKDIR/headerspkg/usr/lib/modules/$KV_FULL/build
	local b=$WORKDIR/binpkg/usr/lib/modules/$KV_FULL
	make_fixture

	if [[ $invalid == plain-ko ]]; then
		printf 'fixture-module\n' > "$b/kernel/plain.ko"
		src_install
		[[ $compress_called == 1 ]] || die "$PF: uncompressed module not compressed"
		printf 'PASS: %s compresses uncompressed modules\n' "$PF"
		exit 0
	fi
	if [[ -n $invalid ]]; then
		if [[ $invalid == mismatched ]]; then
			mv "${h%/build}" "${h%/$KV_FULL/build}/wrong-release-variant"
		else
			mv "${h%/build}" "$WORKDIR/missing-headers"
		fi
		local phase
		for phase in src_configure src_install; do
			if ( "$phase" ) > "$WORKDIR/rejected.log" 2>&1; then
				die "$PF: $phase accepted $invalid headers"
			fi
			# Rejection must name the exact path, not a fallback release.
			grep -Fq "$h" "$WORKDIR/rejected.log" && ! grep -q 'Auto-detected' "$WORKDIR/rejected.log" ||
				{ cat "$WORKDIR/rejected.log"; die "$PF: unexpected $phase rejection"; }
		done
		printf 'PASS: %s rejects %s headers\n' "$PF" "$invalid"
		exit 0
	fi

	src_install
	# Recompressing already compressed modules makes zstd read stdin and abort.
	[[ $compress_called == 0 ]] || die "$PF: compressor ran with no uncompressed modules"
	local d=$ED/usr/src/linux-$KV_FULL f
	for f in Makefile Kconfig Module.symvers System.map .config include/linux/module.h \
		scripts/Makefile.build arch/x86/include/fixture.h scripts/sign-file \
		include/config/auto.conf include/generated/{autoconf.h,compile.h,rustc_cfg}; do
		cmp "$h/$f" "$d/$f" || die "$PF: changed or missing $f"
	done
	cmp "$WORKDIR/modprep/scripts/basic/fixdep" "$d/scripts/basic/fixdep" || die 'Local tool not installed'
	[[ -x $d/scripts/basic/fixdep && -x $d/scripts/sign-file ]] || die 'Build tools not executable'
	[[ ! -e $d/scripts/basic/fixdep.o ]] || die 'modprep object leaked'
	[[ $(< "$d/include/config/kernel.release") == "$KV_FULL" ]] || die 'Wrong generated release'
	cmp "$b/vmlinuz" "$d/arch/x86/boot/bzImage" || die 'Kernel image changed'
	cmp "$b/modules.order" "$ED/lib/modules/$KV_FULL/modules.order" || die 'Module tree changed'
	[[ $(< "$d/dist-kernel") == "$CATEGORY/$PF:$SLOT" ]] || die 'Wrong dist-kernel marker'
	for f in build source; do
		[[ -L $ED/lib/modules/$KV_FULL/$f ]] || die "Missing module $f symlink"
	done
	ROOT="$ED" eselect kernel list | grep -Fq "linux-$KV_FULL" || die 'Kernel not listed'
	ROOT="$ED" eselect kernel set "linux-$KV_FULL"
	[[ $(readlink "$ED/usr/src/linux") == "linux-$KV_FULL" ]] || die 'Kernel not selected'
	printf 'PASS: %s USE=%s (%s) preserves build tree and eselect selection\n' "$PF" "$USE" "$KV_FULL"
)

shopt -s nullglob
ebuilds=( "$repo"/sys-kernel/cachyos-kernel-bin/*.ebuild )
[[ ${#ebuilds[@]} -gt 0 ]] || die 'No bin ebuilds found'
for ebuild in "${ebuilds[@]}"; do
	(
		CATEGORY=sys-kernel PN=cachyos-kernel-bin
		PF=${ebuild##*/} PF=${PF%.ebuild}
		PVR=${PF#"$PN-"} PV=$PVR PR=r0
		if [[ $PVR =~ ^(.+)-r([0-9]+)$ ]]; then
			PV=${BASH_REMATCH[1]} PR=r${BASH_REMATCH[2]}
		fi
		SLOT=$PV WORKDIR=$run/$PF/work USE=
		source "$ebuild"
		defaults= bore=false
		for flag in $IUSE; do
			[[ $flag != +* ]] || defaults+=" ${flag#+}"
			[[ ${flag#+} != bore ]] || bore=true
		done
		run_case default "$defaults"
		run_case mismatched "$defaults" mismatched
		run_case missing "$defaults" missing
		run_case plain-ko "$defaults" plain-ko
		if $bore; then
			run_case bore 'bore'
		fi
	)
done
printf 'PASS: all %s bin ebuilds checked\n' "${#ebuilds[@]}"
