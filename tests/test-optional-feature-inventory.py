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

for version in ("7.3.0", "7.2.11", "6.18.55"):
    features = updater.VALIDATED_HIDDEN_FEATURES[version]
    series = ".".join(version.split(".")[:2])
    paths = {f"{details.get('series', series)}/{details['path']}"
             for details in features.values() if "path" in details}
    assert not updater.audit_hidden_patch_inventory(version, paths)
    if version == "7.3.0":
        assert not any("muqss" in path for path in paths)
        muqss = features["muqss"]
        assert muqss["external_uri"] == "https://github.com/ckolivas/linux/commit/4ceaa4d07af63d9d495f4cbb570547feb39d1236.patch"
    missing = paths - {f"{series}/sched/0001-prjc-cachy.patch"}
    assert any("pds" in error for error in updater.audit_hidden_patch_inventory(version, missing))
    for package in ("cachyos-sources", "cachyos-kernel"):
        revision = "-r1" if version == "7.3.0" else ""
        ebuild = ROOT / f"sys-kernel/{package}/{package}-{version}{revision}.ebuild"
        source = ebuild.read_text()
        iuse = re.search(r'^IUSE="([^"]*)"', source, re.M).group(1).split()
        available = {flag.lstrip("+-") for flag in iuse}
        defaults = {flag[1:] for flag in iuse if flag.startswith("+")}
        assert not defaults & {"pds", "bmq-lfbmq", "deckify", "cachyos-hardened"}
        required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.M).group(1)
        slots = {f"llvm_slot_{slot}" for slot in range(17, 24)}
        required = required.replace('${LLVM_REQUIRED_USE}', '^^ ( ' + ' '.join(sorted(slots)) + ' )')
        available |= slots
        if package == "cachyos-kernel":
            defaults.add("llvm_slot_23")
        for scheduler in {"pds", "bmq-lfbmq", "muqss"} & available:
            use = (defaults - {"bore", "eevdf"}) | {scheduler}
            assert check_required_use(required, use, available.__contains__, eapi="8"), scheduler
            assert not check_required_use(required, use | {"bore"}, available.__contains__, eapi="8"), scheduler
        if package != "cachyos-sources":
            continue
        upstream = {name: version for name in updater.UPSTREAM_PACKAGES}
        if version == "7.3.0":
            upstream["linux-cachyos-hardened"] = "7.2.11"
            upstream["linux-cachyos-lts"] = "6.18.55"
            assert "muqss" in available
            assert not {"cachyos-hardened", "bmq-lfbmq"} & available
        target_version = version + revision
        assert not updater.audit_feature_inventory(source, target_version, upstream, lts=version.startswith("6."))
        if version == "7.3.0":
            external_uri = features["muqss"]["external_uri"]
            assert updater.audit_feature_inventory(source.replace(external_uri, "https://invalid.example/muqss.patch"), target_version, upstream)
            assert updater.audit_feature_inventory(source, "7.3.0-r2", upstream)
            assert "${CACHYOS_PATCH_URI}/sched/0001-muqss-cachy.patch" not in source
        broken = source.replace("-e SCHED_ALT -d SCHED_BMQ -e SCHED_PDS", "")
        assert updater.audit_feature_inventory(broken, target_version, upstream, lts=version.startswith("6."))
        # Generation refuses unvalidated inherited flags/URIs instead of emitting stale wiring.
        next_version = {"7.3.0": "7.3.1", "7.2.11": "7.2.12", "6.18.55": "6.18.56"}[version]
        with tempfile.TemporaryDirectory(prefix="cachyos-feature-test-", dir="/var/tmp") as tmp:
            target = Path(tmp) / f"cachyos-sources-{next_version}.ebuild"
            target.write_text("keep existing target\n")
            with patch.object(updater, "get_zfs_commit", return_value=None), patch.object(updater, "get_genpatches_version_from_template", return_value="1"):
                result = updater.copy_and_update_ebuild(ebuild, next_version, tmp, force=True,
                    lts=version.startswith("6."), upstream_versions={name: next_version for name in upstream})
            assert result is None
            assert target.read_text() == "keep existing target\n"
print("PASS: immutable feature inventory, opt-in defaults, scheduler/LLVM negatives and fail-closed generation")

# Retained binary-only providers must be installable with their defaults.
for ebuild in sorted((ROOT / "sys-kernel/cachyos-kernel-bin").glob("*.ebuild")):
    source = ebuild.read_text()
    flags = re.search(r'^IUSE="([^"]*)"', source, re.M).group(1).split()
    available = {flag.lstrip("+-") for flag in flags}
    defaults = {flag[1:] for flag in flags if flag.startswith("+")}
    required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.M).group(1)
    assert check_required_use(required, defaults, available.__contains__, eapi="8"), ebuild.name
    if "hardened" in available:
        assert "^^ ( hardened )" in required
        assert not check_required_use(required, defaults - {"hardened"}, available.__contains__, eapi="8")
        assert 'name="hardened"' in (ebuild.parent / "metadata.xml").read_text()
print("PASS: retained binary default USE and hardened selector/metadata")
