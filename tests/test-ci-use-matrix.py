#!/usr/bin/env python3
"""Check the CI USE matrix against source ebuild defaults and REQUIRED_USE."""

from pathlib import Path
import re

from portage.dep import check_required_use

from ci_matrix_cases import OPTIONAL_VARIANT_FLAGS, usable_cases


ROOT = Path(__file__).resolve().parents[1]
workflow = (ROOT / ".github/workflows/ebuild-test.yml").read_text()
# A checker-only change must select the latest source version, not versions=[].
changed_pattern = re.search(r'WORKFLOW_CHANGED=.*?grep -E "([^"]+)"', workflow, re.S).group(1)
assert re.search(changed_pattern, "tests/test-source-features.py"), "Checker change skips source tests"
assert not re.search(changed_pattern, "README.md")
# ponytail: literal quoted matrix only; use a YAML parser if expressions are added.
matrix = workflow.split("        use_flags:\n", 1)[1].split("    container:", 1)[0]
cases = re.findall(r'^\s+- "([^"]*)"', matrix, re.MULTILINE)
assert cases and "" in cases, "Missing CI USE matrix or default case"
consumer_flags = re.search(r'for OPTIONAL_FLAG in ([^;]+); do', workflow).group(1).split()
assert set(consumer_flags) == set(OPTIONAL_VARIANT_FLAGS), "Producer/consumer skip rules differ"

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
    version = ebuild.stem.removeprefix("cachyos-sources-")
    producer_cases = usable_cases(ROOT, version, "glibc")
    if version == "7.2.10":
        assert "governor-nap governor-reflex" in producer_cases
        assert "clang-polly" in producer_cases
    if version == "6.18.55":
        assert "sched-ext-peek" in producer_cases
    assert producer_cases == [case for case in cases if not any(
        flag in case.split() and flag not in available for flag in OPTIONAL_VARIANT_FLAGS)]
    if "bore-dev" in available:
        for extra in ({"bore-dev"}, {"adios-default", "-adios"}):
            conflict = (defaults | (extra - {"-adios"})) - ({"adios"} if "-adios" in extra else set())
            assert not check_required_use(required, conflict, available.__contains__, eapi="8"), extra
        for feature in ("poc-selector", "governor-reflex", "sched-ext-peek"):
            if feature not in available:
                continue
            for scheduler in {"bmq", "pds", "bmq-lfbmq", "muqss"} & available:
                conflict = (defaults - {"eevdf", "bore"}) | {scheduler, feature}
                assert not check_required_use(required, conflict, available.__contains__, eapi="8"), (feature, scheduler)

    for case in cases:
        flags = case.split()
        # Match the workflow's version-dependent variant exclusions.
        if any(flag in flags and flag not in available
               for flag in OPTIONAL_VARIANT_FLAGS):
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
