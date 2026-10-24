#!/usr/bin/env python3
"""Verify mixed 7.3 binary/source groups, release paths and valid USE sets."""
import itertools
import os
from pathlib import Path
import re
import subprocess

from portage.dep import check_required_use

ROOT = Path(__file__).resolve().parents[1]
EBUILD = ROOT / "sys-kernel/cachyos-kernel-bin/cachyos-kernel-bin-7.3.0-r3.ebuild"
FLAGS = ["cachyos lto", "cachyos gcc"] + [
    f"{scheduler} {lto}".strip()
    for scheduler in ("bore", "bmq", "eevdf", "rt-bore", "server")
    for lto in ("lto", "")
]
SHELL = '''
inherit() { :; }; use() { [[ " $USE " == *" $1 "* ]]; }
PV=7.3.0 PR=r3 SLOT=7.3.0 WORKDIR=unused
source "$1"
_cachyos_setup_kv
printf '%s|%s|%s|%s|%s|%s\\n' "$KV_FULL" "$KV_LOCALVERSION" \
    "$(_cachyos_pkgrel)" "$(_cachyos_bin_distfile)" \
    "$(_cachyos_headers_distfile)" "$(_cachyos_source_pkg)"
'''
for flags in FLAGS:
    release, localversion, pkgrel, kernel, headers, source = subprocess.check_output(
        ["bash", "-c", SHELL, "bash", str(EBUILD)],
        env=dict(os.environ, USE=flags), text=True,
    ).strip().split("|")
    expected_pr = "4" if flags in ("cachyos lto", "cachyos gcc") else "2"
    scheduler = flags.split()[0]
    variant = "" if flags == "cachyos lto" else "gcc" if scheduler == "cachyos" else scheduler + ("-lto" if "lto" in flags.split() else "")
    suffix = "cachyos" + ("-" + variant if variant else "")
    stem = "linux-" + suffix
    assert release == f"7.3.0-{expected_pr}-{suffix}", flags
    assert localversion == f"-{expected_pr}-{suffix}", flags
    assert pkgrel == expected_pr, flags
    assert source == f"cachyos-7.3.0-{expected_pr}", flags
    assert kernel == f"{stem}-7.3.0-{expected_pr}-x86_64_v3.pkg.tar.zst", flags
    assert headers == f"{stem}-headers-7.3.0-{expected_pr}-x86_64_v3.pkg.tar.zst", flags

content = EBUILD.read_text()
iuse = re.search(r'^IUSE="([^"]*)"', content, re.M).group(1).split()
available = sorted(flag.lstrip("+-") for flag in iuse)
required = re.search(r'^REQUIRED_USE="([^"]*)"', content, re.M).group(1)
valid = []
for bits in itertools.product((False, True), repeat=len(available)):
    enabled = {flag for flag, bit in zip(available, bits) if bit}
    if check_required_use(required, enabled, available.__contains__, eapi="8"):
        valid.append(enabled)
expected = [set(flags.split()) | debug for flags in FLAGS for debug in (set(), {"debug"})]
assert len(valid) == 24 and all(flags in expected for flags in valid)
assert not {"deckify", "hardened", "muqss"} & set(available)
print("PASS: 12 mixed release/source/kernel/header mappings; 512 USE sets, exactly 24 valid")
