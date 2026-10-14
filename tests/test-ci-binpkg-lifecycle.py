#!/usr/bin/env python3
"""Behavior checks for dependency reuse, isolated cases and run-owned cleanup.

Needs Portage (as do test-ci-use-matrix.py and the CI containers). No network,
package installs or signing keys. Node, when available, runs the cleanup script.
"""

import bz2
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tarfile

import portage.xpak

from ci_matrix_cases import matrix_cases, usable_cases

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=90, **kwargs)


with tempfile.TemporaryDirectory(prefix="ci-binpkg-test-", dir="/var/tmp") as tmp:
    temp = Path(tmp)
    config = temp / "etc/portage"
    for name in ("package.use", "binrepos.conf"):
        (config / name).mkdir(parents=True)
    tools = temp / "bin"
    tools.mkdir()
    calls = temp / "calls.jsonl"
    artifact = temp / "artifact"
    artifact.mkdir()
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
               CI_BINPKG_OUT=str(artifact), TEST_CONFIG=str(config),
               TEST_CALLS=str(calls), TEST_PLAN="[binary  N     ] dev-util/ci-dep-1\n")
    # Run the actual shell helpers, redirecting only container-owned paths.
    scripts = {}
    for name in ("producer", "consumer"):
        source = (ROOT / f"tests/ci-binpkg-{name}.sh").read_text()
        source = source.replace("/etc/portage", str(config))
        source = source.replace("/var/db/repos/cachyos-overlay", str(ROOT))
        source = source.replace("/var/cache/edb/binhost", str(temp / "index"))
        scripts[name] = temp / f"{name}.sh"
        scripts[name].write_text(source)
    (tools / "emerge").write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
config = pathlib.Path(os.environ["TEST_CONFIG"])
entries = [p.read_text() for p in (config / "package.use").rglob("*") if p.is_file()]
with open(os.environ["TEST_CALLS"], "a") as f:
    f.write(json.dumps({"args": sys.argv[1:], "use": entries}) + "\\n")
if "--pretend" in sys.argv:
    print(os.environ["TEST_PLAN"])
    sys.exit(int(os.environ.get("TEST_EXIT", "0")))
if "--buildpkg" in sys.argv:
    (config / "package.use/zz-autounmask").write_text("dev-util/ci-dep feature\\n")
''')
    (tools / "emaint").write_text('''#!/usr/bin/env bash
set -eu
[[ "$*" == 'binhost --fix' ]]
printf 'PACKAGES: 0\\n' > "$CI_BINPKG_OUT/pkgdir/Packages"
''')
    # Snapshot creation is checked separately; no reading real /etc in this test.
    (tools / "tar").write_text('#!/usr/bin/env bash\nexit 0\n')
    (tools / "getuto").write_text('#!/usr/bin/env bash\nexit 0\n')
    for path in tools.iterdir():
        path.chmod(0o755)

    # User patches must not apply a 7.x-only workload fix to stable perf 6.19.
    checkout = temp / "checkout"
    checkout.mkdir()
    setup = temp / "setup.sh"
    setup.write_text((ROOT / "tests/ci-portage-setup.sh").read_text()
                     .replace("/etc/portage", str(config))
                     .replace("/var/db/repos/cachyos-overlay", str(temp / "overlay")))
    result = run(["bash", str(setup), "musl", str(checkout)], env=env)
    assert result.returncode == 0, result.stdout
    patches = config / "patches/dev-util"
    assert not (patches / "perf").exists(), "Unversioned patch breaks stable perf"
    for perf in ("perf-7.1", "perf-7.2"):
        assert (patches / perf / "perf-musl-code-with-type-uint.patch").is_file()
    assert not (patches / "perf-6.19.12").exists()
    calls.write_text("")
    print("PASS: musl perf workaround is scoped to affected 7.1/7.2, not stable 6.19")

    version = sorted((ROOT / "sys-kernel/cachyos-sources").glob("*.ebuild"))[-1].stem.removeprefix("cachyos-sources-")
    versions = temp / "versions"
    versions.write_text(version + "\n")
    result = run(["bash", str(scripts["producer"]), str(versions), "glibc"], env=env)
    assert result.returncode == 0, result.stdout
    produced = [json.loads(line) for line in calls.read_text().splitlines()]
    cases = usable_cases(ROOT, version, "glibc")
    assert len(produced) == len(cases) > 1
    for call, case in zip(produced, cases):
        target_entries = [line for content in call["use"] for line in content.splitlines()
                          if "cachyos-sources" in line]
        assert target_entries == [f"=sys-kernel/cachyos-sources-{version} {case}"], target_entries
        assert "--onlydeps" in call["args"] and "--getbinpkg" in call["args"]
    assert matrix_cases(ROOT, "musl") == [""]
    assert not (config / "package.use/ci-case").exists()
    assert (config / "package.use/zz-autounmask").read_text() == "dev-util/ci-dep feature\n"

    # Covered dependencies: pretend + merge, then force target source phases.
    calls.write_text("")
    result = run(["bash", str(scripts["consumer"]), str(artifact), version, ""], env=env)
    assert result.returncode == 0, result.stdout
    consumed = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(consumed) == 3
    assert consumed[0]["args"] == ["--pretend", *consumed[1]["args"]]
    assert "--onlydeps" in consumed[1]["args"]
    assert {"--nodeps", "--usepkg=n", "--getbinpkg=n"} <= set(consumed[2]["args"])
    assert "dev-util/ci-dep feature\n" in consumed[0]["use"]
    # Missing binary or a failed resolver must abort before either merge.
    for plan, exit_code in (("[ebuild  N     ] dev-util/ci-dep-1", "0"), ("", "1")):
        calls.write_text("")
        result = run(["bash", str(scripts["consumer"]), str(artifact), version, ""],
                     env=dict(env, TEST_PLAN=plan, TEST_EXIT=exit_code))
        assert result.returncode != 0
        assert len(calls.read_text().splitlines()) == 1
    print("PASS: producer replaces cases; consumers abort on source deps/resolver failure and force source target")

    # Real emerge: verify the exact invoked plan works without a target binary,
    # and the source-dependency guard matches real Portage output, not a guess.
    fixture = temp / "portage"
    repo = fixture / "repo"
    profile = repo / "profiles/test"
    config = fixture / "etc/portage"
    pkgdir = fixture / "pkgdir"
    # A tiny real repository/config root avoids relying on Portage's private
    # test harness or any fixture signing keys.
    temp.chmod(0o755)
    for path in (profile, config, pkgdir / "dev-util", fixture / "var/tmp"):
        path.mkdir(parents=True)
    (fixture / "usr/share/portage").mkdir(parents=True)
    (fixture / "usr/share/portage/config").symlink_to("/usr/share/portage/config")
    (profile / "make.defaults").write_text('ARCH="amd64"\nCHOST="x86_64-pc-linux-gnu"\nACCEPT_KEYWORDS="amd64"\n')
    (profile / "eapi").write_text("8\n")
    (repo / "profiles/repo_name").write_text("test_repo\n")
    (repo / "profiles/categories").write_text("dev-util\nsys-kernel\n")
    (config / "make.profile").symlink_to(profile)
    (config / "make.conf").write_text(
        f'PKGDIR="{pkgdir}"\nPORTAGE_TMPDIR="{fixture}/var/tmp"\n'
        'FEATURES="-news -strict -binpkg-request-signature -ipc-sandbox -network-sandbox -pid-sandbox"\n')
    for cpv, deps in (("sys-kernel/cachyos-sources-1", "dev-util/ci-dep"), ("dev-util/ci-dep-1", "")):
        category, pf = cpv.split("/")
        ebuild = repo / category / pf.rsplit("-", 1)[0] / f"{pf}.ebuild"
        ebuild.parent.mkdir(parents=True)
        ebuild.write_text(f'EAPI=8\nSLOT="0"\nKEYWORDS="amd64"\nRDEPEND="{deps}"\n')
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w"):
        pass
    binary = pkgdir / "dev-util/ci-dep-1.tbz2"
    binary.write_bytes(bz2.compress(archive.getvalue()))
    portage.xpak.tbz2(str(binary)).recompose_mem(portage.xpak.xpak_mem({
        "EAPI": "8", "SLOT": "0", "KEYWORDS": "amd64", "CATEGORY": "dev-util",
        "PF": "ci-dep-1", "repository": "test_repo", "BUILD_TIME": "1", "CHOST": "x86_64-pc-linux-gnu",
    }))
    real_env = dict(os.environ, PORTAGE_CONFIGROOT=str(fixture), ROOT="/",
                    SYSROOT="/", EPREFIX=str(fixture), PORTAGE_OVERRIDE_EPREFIX=str(fixture),
                    PORTAGE_REPOSITORIES=f"[DEFAULT]\nmain-repo = test_repo\n[test_repo]\nlocation = {repo}\nmasters =\n")
    index = run(["emaint", "binhost", "--fix"], env=real_env)
    assert index.returncode == 0, index.stdout
    args = [arg.replace(version, "1") for arg in consumed[0]["args"]]
    real_emerge = shutil.which("emerge")
    old = run([real_emerge, "--ignore-default-opts", "--pretend", "--onlydeps",
               "--usepkgonly", "--usepkg-exclude", "sys-kernel/cachyos-sources",
               "=sys-kernel/cachyos-sources-1"], env=real_env)
    assert old.returncode != 0 and "there are no binary packages to satisfy" in old.stdout, old.stdout
    covered = run([real_emerge, "--ignore-default-opts", *args], env=real_env)
    assert covered.returncode == 0 and "[binary" in covered.stdout, covered.stdout
    assert not re.search(r"^\[ebuild\s", covered.stdout, re.M), covered.stdout
    shutil.rmtree(pkgdir)
    missing = run([real_emerge, "--ignore-default-opts", *args], env=real_env)
    assert missing.returncode == 0 and re.search(r"^\[ebuild\s", missing.stdout, re.M), missing.stdout
    # Pass actual Portage plans through the shell guard.
    for plan, succeeds in ((covered.stdout, True), (missing.stdout, False)):
        result = run(["bash", str(scripts["consumer"]), str(artifact), version, ""],
                     env=dict(env, TEST_PLAN=plan))
        assert (result.returncode == 0) == succeeds, result.stdout
    print("PASS: real Portage reproduces old -K target error; corrected dependency plan accepts binary and rejects source")

# Execute privileged cleanup JS with a mocked GitHub API, not substring claims.
cleanup = (ROOT / ".github/workflows/ebuild-binpkg-cleanup.yml").read_text()
script = cleanup.split("        script: |\n", 1)[1]
script = "\n".join(line[10:] for line in script.splitlines())
if shutil.which("node"):
    fixture_js = '''
const assert = require('node:assert/strict');
const context = {repo: {owner:'base', repo:'repo'}, payload: {workflow_run: {id:42, run_attempt:2}}};
const deleted = [];
const github = {rest: {actions: {
  listWorkflowRunArtifacts: 'list',
  deleteArtifact: async ({owner,repo,artifact_id}) => {
    assert.equal(owner,'base'); assert.equal(repo,'repo'); deleted.push(artifact_id);
  }
}}, paginate: async (method, args) => {
  assert.equal(method,'list'); assert.equal(args.run_id,42);
  return [
    {id:1,name:'ci-binpkgs-glibc-42-2'}, {id:2,name:'ci-binpkgs-musl-42-2'},
    {id:3,name:'ci-binpkgs-glibc-99-2'}, {id:4,name:'unrelated'},
    {id:5,name:'ci-binpkgs-glibc-42-3'}
  ];
}};
(async () => {
'''
    result = run(["node", "-e", fixture_js + script + "\nassert.deepEqual(deleted,[1,2]); })().catch(e => { console.error(e); process.exit(1); });"])
    assert result.returncode == 0, result.stdout
    print("PASS: cleanup deletes only originating run/attempt artifacts; no other runs, retries or artifacts")
else:
    print("SKIP: cleanup JavaScript execution requires Node (run on host)")
