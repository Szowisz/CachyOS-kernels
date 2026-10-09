#!/usr/bin/env python3
"""Exercise THP choices from every source/dist-kernel ebuild without building Linux."""

from pathlib import Path
import re
import subprocess

from portage.dep import check_required_use


ROOT = Path(__file__).resolve().parents[1]
ebuilds = sorted(
    path
    for package in ("cachyos-sources", "cachyos-kernel")
    for path in (ROOT / "sys-kernel" / package).glob("*.ebuild")
)
assert ebuilds, "No source/dist-kernel ebuilds found"
checked = 0
for ebuild in ebuilds:
    source = ebuild.read_text()
    iuse = re.search(r'^IUSE="([^"]*)"', source, re.MULTILINE).group(1).split()
    available = {flag.lstrip("+-") for flag in iuse}
    defaults = {flag[1:] for flag in iuse if flag.startswith("+")}
    always = next(flag for flag in available if flag in ("hugepage-always", "hugepage_always"))
    madvise = always.replace("always", "madvise")
    required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.MULTILINE).group(1)
    # LLVM slot constraints come from an eclass and do not affect THP selection.
    required = required.replace("${LLVM_REQUIRED_USE}", "")
    # Execute the actual inline THP conditionals, not a duplicate selection algorithm.
    blocks = re.findall(r"\tif use hugepage[-_][^\n]*\n.*?\tfi\n", source, re.DOTALL)
    assert blocks, f"{ebuild.name}: no inline THP configuration found"
    shell = """
use() {
    [[ " $IUSE " == *" $1 "* ]] || die "Undeclared USE flag: $1"
    [[ " $USE " == *" $1 "* ]]
}
die() { printf '%s\\n' "$*" >&2; exit 1; }
scripts/config() { printf '%s\\n' "$@"; }
""" + "\n".join(blocks)

    for server in ((False, True) if "server" in available else (False,)):
        for choice in (None, "auto", "always", "madvise", "both"):
            enabled = defaults.copy()
            if server:
                enabled.add("server")
            if choice is not None:
                enabled.difference_update((always, madvise))
                if choice in ("always", "both"):
                    enabled.add(always)
                if choice in ("madvise", "both"):
                    enabled.add(madvise)
            valid = bool(check_required_use(required, enabled, available.__contains__, eapi="8"))
            expected_valid = choice != "both" and (choice != "auto" or "server" in available)
            assert valid == expected_valid, (
                f"{ebuild.name}: server={server}, choice={choice}: unexpected REQUIRED_USE result"
            )
            if not valid:
                checked += 1
                continue
            result = subprocess.run(
                ["bash", "-e", "-c", 'USE=$1; IUSE=$2\n' + shell, "thp-test",
                 " ".join(sorted(enabled)), " ".join(sorted(available))],
                capture_output=True, text=True,
            )
            assert result.returncode == 0, f"{ebuild.name}: {result.stderr}"
            args = result.stdout.splitlines()
            assert len(args) % 2 == 0, f"Unexpected scripts/config arguments: {args}"
            expected = choice if choice in ("always", "madvise") else ("madvise" if server else "always")
            # Both possible starting defaults must converge to exactly one requested mode.
            for initial in ("always", "madvise"):
                config = {"TRANSPARENT_HUGEPAGE_" + name.upper(): name == initial
                          for name in ("always", "madvise")}
                for operation, symbol in zip(args[::2], args[1::2]):
                    assert operation in ("-e", "-d") and symbol in config, args
                    config[symbol] = operation == "-e"
                actual = {symbol for symbol, enabled_value in config.items() if enabled_value}
                assert actual == {"TRANSPARENT_HUGEPAGE_" + expected.upper()}, (
                    f"{ebuild.name}: server={server}, choice={choice}, initial={initial}: "
                    f"expected {expected}, got {actual}"
                )
            checked += 1
print(f"PASS: {checked} THP default/override/conflict cases across {len(ebuilds)} ebuilds")
