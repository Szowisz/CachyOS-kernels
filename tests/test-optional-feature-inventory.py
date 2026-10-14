#!/usr/bin/env python3
"""Check cross-series inputs, branch pins and opt-in feature constraints."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import re
import tempfile
from unittest.mock import patch

from portage.dep import check_required_use

ROOT = Path(__file__).resolve().parents[1]
spec = spec_from_file_location("updater", ROOT / "sys-kernel/cachyos-sources/script/update_ebuild.py")
updater = module_from_spec(spec)
spec.loader.exec_module(updater)

for version in ("7.2.10", "6.18.55"):
    features = updater.VALIDATED_HIDDEN_FEATURES[version]
    series = ".".join(version.split(".")[:2])
    paths = {f"{details.get('series', series)}/{details['path']}"
             for details in features.values() if "path" in details}
    assert not updater.audit_hidden_patch_inventory(version, paths)
    if version == "7.2.10":
        missing = paths - {"6.18/misc/nap-governor.patch"}
        assert any("governor-nap" in error for error in updater.audit_hidden_patch_inventory(version, missing))
    for package in ("cachyos-sources", "cachyos-kernel"):
        ebuild = ROOT / f"sys-kernel/{package}/{package}-{version}.ebuild"
        source = ebuild.read_text()
        iuse = re.search(r'^IUSE="([^"]*)"', source, re.M).group(1).split()
        available = {flag.lstrip("+-") for flag in iuse}
        defaults = {flag[1:] for flag in iuse if flag.startswith("+")}
        assert not defaults & {"governor-nap", "governor-reflex", "clang-polly", "sched-ext-peek"}
        required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.M).group(1)
        slots = {f"llvm_slot_{slot}" for slot in range(17, 24)}
        required = required.replace('${LLVM_REQUIRED_USE}', '^^ ( ' + ' '.join(sorted(slots)) + ' )')
        available |= slots
        if package == "cachyos-kernel":
            defaults.add("llvm_slot_23")
            for slot in range(17, 24):
                use = (defaults - slots) | {"clang-polly", f"llvm_slot_{slot}"}
                assert bool(check_required_use(required, use, available.__contains__, eapi="8")) == (slot >= 20)
            gcc = (defaults - {"clang", "llvm-lto-thin", "autofdo", "propeller"}) | {"llvm-lto-none", "clang-polly"}
            assert not check_required_use(required, gcc, available.__contains__, eapi="8")
        for flag in {"governor-reflex", "sched-ext-peek"} & available:
            for scheduler in {"bmq", "pds", "bmq-lfbmq", "muqss"} & available:
                use = (defaults - {"bore", "eevdf"}) | {flag, scheduler}
                assert not check_required_use(required, use, available.__contains__, eapi="8")
        if package != "cachyos-sources":
            continue
        upstream = {name: version for name in updater.UPSTREAM_PACKAGES}
        assert not updater.audit_feature_inventory(source, version, upstream, lts=version.startswith("6."))
        if version == "6.18.55":
            for commit in features["sched-ext-peek"]["commits"]:
                broken = source.replace(f"{commit}.patch", "obsolete.patch")
                assert updater.audit_feature_inventory(broken, version, upstream, lts=True)
        # Generation refuses unvalidated inherited flags/URIs instead of emitting stale wiring.
        next_version = "7.2.11" if version.startswith("7.") else "6.18.56"
        with tempfile.TemporaryDirectory(prefix="cachyos-feature-test-", dir="/var/tmp") as tmp:
            target = Path(tmp) / f"cachyos-sources-{next_version}.ebuild"
            target.write_text("keep existing target\n")
            with patch.object(updater, "get_zfs_commit", return_value=None), patch.object(updater, "get_genpatches_version_from_template", return_value="1"):
                result = updater.copy_and_update_ebuild(ebuild, next_version, tmp, force=True,
                    lts=version.startswith("6."), upstream_versions={name: next_version for name in upstream})
            assert result is None
            assert target.read_text() == "keep existing target\n"
print("PASS: immutable feature inventory, opt-in defaults, scheduler/LLVM negatives and fail-closed generation")
