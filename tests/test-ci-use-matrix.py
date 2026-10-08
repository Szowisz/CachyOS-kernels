#!/usr/bin/env python3
"""Check the CI USE matrix against source ebuild defaults and REQUIRED_USE."""

from pathlib import Path
import re

from portage.dep import check_required_use


ROOT = Path(__file__).resolve().parents[1]
workflow = (ROOT / ".github/workflows/ebuild-test.yml").read_text()
# ponytail: literal quoted matrix only; use a YAML parser if expressions are added.
matrix = workflow.split("        use_flags:\n", 1)[1].split("    container:", 1)[0]
cases = re.findall(r'^\s+- "([^"]*)"', matrix, re.MULTILINE)
assert cases and "" in cases, "Missing CI USE matrix or default case"

ebuilds = sorted((ROOT / "sys-kernel/cachyos-sources").glob("*.ebuild"))
assert ebuilds, "Missing source ebuilds"
failures = []
checked = skipped = 0
for ebuild in ebuilds:
    if "9999" in ebuild.name:
        continue
    source = ebuild.read_text()
    iuse = re.search(r'^IUSE="([^"]*)"', source, re.MULTILINE).group(1).split()
    available = {flag.lstrip("+-") for flag in iuse}
    defaults = {flag[1:] for flag in iuse if flag.startswith("+")}
    required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.MULTILINE).group(1)

    for case in cases:
        flags = case.split()
        # Match the workflow's version-dependent variant exclusions.
        if any(flag in flags and flag not in available
               for flag in ("bmq", "bmq-lfbmq", "deckify")):
            skipped += 1
            continue
        checked += 1
        unknown = {flag.lstrip("-") for flag in flags} - available
        if unknown:
            failures.append(f"{ebuild.name} USE={case!r}: unknown {sorted(unknown)}")
            continue
        enabled = defaults.copy()
        for flag in flags:
            if flag.startswith("-"):
                enabled.discard(flag[1:])
            else:
                enabled.add(flag)
        result = check_required_use(required, enabled, available.__contains__, eapi="8")
        if not result:
            failures.append(f"{ebuild.name} USE={case!r}: {result.tounicode()}")

if failures:
    print("\n".join(failures[:8]))
    raise SystemExit(f"FAIL: {len(failures)} invalid cases out of {checked}; {skipped} unsupported cases skipped")
print(f"PASS: {checked} CI USE cases across {len(ebuilds)} ebuilds; {skipped} unsupported cases skipped")
