#!/usr/bin/env python3
"""Behavior checks for the shared kernel Kbuild CI helper.

Stub `make`/`clang`/`rustc`/`bindgen` binaries record invocations and emulate
olddefconfig feature loss, so argument/toolchain/preservation/failure
assertions run with no host clang and no real kernel tree. Where
.ci/issue60 ships a real prepared 7.3.1 BORE tree, the actual scheduler
compilation runs red (unfixed source) and green (patched source) in an owned
scratch copy under /var/tmp — that smoke uses the real toolchain by design.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import ci_kernel_expected as expected_module  # noqa: E402

HELPER = ROOT / "tests/ci-kernel-kbuild.sh"
PATCH = ROOT / "sys-kernel/cachyos-sources/files/cachyos-sources-7.3.1-bore-protect-slice.patch"
ISSUE60_TREE = ROOT / ".ci/issue60/linux-7.3.1-cachyos"
FAIR = Path("kernel/sched/fair.c")
EBUILD = ROOT / "sys-kernel/cachyos-sources/cachyos-sources-7.3.1.ebuild"


def run(args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=300, **kwargs)


def tool_stub(tools: Path, name: str, body: str) -> None:
    path = tools / name
    path.write_text(f"#!/bin/bash\n{body}\n")
    path.chmod(0o755)


def workflow_step(text, name):
    block = text.split(f"    - name: {name}\n", 1)[1].split("\n    - name:", 1)[0]
    return block, textwrap.dedent(block.split("      run: |\n", 1)[1])


with tempfile.TemporaryDirectory(prefix="ci-kbuild-test-", dir="/var/tmp") as tmp:
    temp = Path(tmp)
    tools = temp / "bin"
    tools.mkdir()
    calls = temp / "calls.txt"
    evidence = temp / "evidence"
    tree = temp / "tree"
    tree.mkdir()
    (tree / "Makefile").write_text("fake\n")

    def write_config(config_text):
        (tree / ".config").write_text(config_text)

    # Stub make: appends the invocation, emulates olddefconfig config loss
    # through MAKE_DROP=<SYMBOL,SYMBOL>, honors MAKE_EXIT and
    # MAKE_WRITE_CONFIG (literal text written into .config).
    tool_stub(tools, "make", '''set -u
for arg in "$@"; do [[ "$arg" == -C ]] && shift 2 && break; done
last="${!#}"
if [[ "$last" == --version ]]; then
  echo "stub make 4.0"
  exit 0
fi
printf 'make %s\\n' "$*" >> "''' + str(calls) + '''"
if [[ "$last" == *olddefconfig* ]]; then
  if [[ -n "${MAKE_WRITE_CONFIG:-}" ]]; then
    printf '%s' "${MAKE_WRITE_CONFIG}" > "''' + str(tree) + '''/.config"
  fi
  if [[ -n "${MAKE_DROP:-}" ]]; then
    for sym in ${MAKE_DROP//,/ }; do
      sed -i -e "/^CONFIG_${sym}=/d" -e "/^# CONFIG_${sym} is not set/d" \\
        -e "/CONFIG_${sym}=/d" "''' + str(tree) + '''/.config"
      printf '# CONFIG_%s is not set\\n' "${sym}" >> "''' + str(tree) + '''/.config"
    done
  fi
  exit "${MAKE_EXIT:-0}"
fi
exit "${MAKE_EXIT:-0}"
''')
    # Stub compilers: always "present" for mocked tests; the clang-free
    # negative below removes them from PATH deliberately.
    for name in ("clang", "gcc", "rustc", "bindgen", "ccache"):
        tool_stub(tools, name, f'echo "{name} stub 1.0"\nexit 0\n')
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
    env.pop("CCACHE_DIR", None)
    # Real kernel trees are not needed for mocked runs.
    env.pop("CI_MAKE_FLAGS", None)

    thin = ("CONFIG_LTO_CLANG_THIN=y\nCONFIG_SCHED_BORE=y\nCONFIG_AUTOFDO_CLANG=y\n"
            "CONFIG_PROPELLER_CLANG=y\nCONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y\n"
            "CONFIG_TCP_CONG_BBR3=y\nCONFIG_DEFAULT_TCP_CONG=\"bbr3\"\n"
            "CONFIG_X86_NATIVE_CPU=y\nCONFIG_HZ_1000=y\nCONFIG_HZ=1000\n"
            "CONFIG_NO_HZ_FULL=y\nCONFIG_CACHY=y\n"
            "CONFIG_PREEMPT=y\nCONFIG_PREEMPT_DYNAMIC=y\n"
            "CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y\n"
            "CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y\n"
            "# CONFIG_SCHED_ALT is not set\n# CONFIG_SCHED_MUQSS is not set\n"
            "# CONFIG_PREEMPT_RT is not set\n# CONFIG_LTO_NONE is not set\n"
            "# CONFIG_AUFS_FS is not set\n# CONFIG_CFI is not set\n")

    write_config(thin)
    calls.write_text("")
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree),
                  "bore o3 llvm-lto-thin -llvm-lto-none"], env=env)
    assert result.returncode == 0, result.stdout
    invoked = calls.read_text().splitlines()
    assert len(invoked) == 2, invoked
    assert "LLVM=1" in invoked[0] and "olddefconfig" in invoked[0]
    assert "kernel/sched/" in invoked[1] and "LLVM_IAS=1" in invoked[1]
    print("PASS: ThinLTO case selects LLVM and runs olddefconfig then kernel/sched/")

    for symbol in ("PREEMPT", "PREEMPT_DYNAMIC", "TRANSPARENT_HUGEPAGE_ALWAYS",
                   "CPU_FREQ_DEFAULT_GOV_PERFORMANCE"):
        write_config(thin)
        calls.write_text("")
        result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree), ""],
                     env=dict(env, MAKE_DROP=symbol))
        assert result.returncode != 0, (symbol, result.stdout)
        assert not any(target in calls.read_text() for target in ("bzImage", "modules"))
    write_config(thin.replace("CONFIG_NO_HZ_FULL=y", "CONFIG_HZ_PERIODIC=y"))
    calls.write_text("")
    result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree),
                  "tickrate-periodic -tickrate-full"], env=dict(env, MAKE_DROP="HZ_PERIODIC"))
    assert result.returncode != 0, result.stdout
    assert "bzImage" not in calls.read_text()
    print("PASS: default preemption/governor/THP and periodic tick loss stop compilation")
    rt_config = thin.replace("CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y\n", "") \
        .replace("# CONFIG_PREEMPT_RT is not set", "CONFIG_PREEMPT_RT=y")
    write_config(rt_config)
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree), "rt-bore -bore"], env=env)
    assert result.returncode == 0, result.stdout
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree),
                  "rt-bore -bore hugepage-always"], env=env)
    assert result.returncode != 0 and "TRANSPARENT_HUGEPAGE_ALWAYS" in result.stdout
    print("PASS: RT's Kconfig THP exclusion is respected; explicit lost selection fails")

    # Intentional missing-compiler negative: a mocked run with no clang in
    # PATH must fail before touching make, not fabricate a toolchain.
    # A controlled minimal PATH: symlink only the utilities the helper needs
    # so a tool's absence is real (host /usr/bin carries rustc/clang).
    core = temp / "core"
    core.mkdir()
    for util in ("bash", "python3", "grep", "sed", "date", "nproc", "head",
                 "mkdir", "cp", "cat", "dirname", "sort", "tr", "mktemp"):
        target = shutil.which(util)
        assert target, util
        (core / util).symlink_to(target)

    tools_no_clang = temp / "bin-no-clang"
    tools_no_clang.mkdir()
    for stub in tools.iterdir():
        if stub.name != "clang":
            (tools_no_clang / stub.name).symlink_to(stub)
    clang_free = dict(env)
    clang_free["PATH"] = f"{tools_no_clang}:{core}"
    assert not shutil.which("clang", path=clang_free["PATH"])
    write_config(thin)
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree),
                  "bore o3 llvm-lto-thin -llvm-lto-none", str(evidence)], env=clang_free)
    assert result.returncode != 0, result.stdout
    assert "clang required" in result.stdout, result.stdout
    assert "unbound variable" not in result.stdout, result.stdout
    record = (evidence / "toolchain.env").read_text()
    assert all(field in record for field in ("status=failed", "started=", "finished=",
                                              "elapsed_seconds=", "clang=missing")), record
    assert (evidence / "config.final").read_text() == thin
    print("PASS: missing clang fails clearly and retains complete failure evidence")

    gcc_config = ("CONFIG_LTO_NONE=y\n# CONFIG_SCHED_BORE is not set\n"
                  "# CONFIG_AUTOFDO_CLANG is not set\n"
                  "# CONFIG_PROPELLER_CLANG is not set\n"
                  "CONFIG_TCP_CONG_BBR3=y\nCONFIG_DEFAULT_TCP_CONG=\"bbr3\"\n"
                  "CONFIG_X86_NATIVE_CPU=y\nCONFIG_HZ_1000=y\nCONFIG_HZ=1000\n"
                  "CONFIG_CC_OPTIMIZE_FOR_SIZE=y\nCONFIG_NO_HZ_FULL=y\n"
                  "CONFIG_PREEMPT=y\nCONFIG_PREEMPT_DYNAMIC=y\n"
                  "CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y\n"
                  "CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y\n"
                  "CONFIG_CACHY=y\n# CONFIG_SCHED_ALT is not set\n"
                  "# CONFIG_SCHED_MUQSS is not set\n# CONFIG_PREEMPT_RT is not set\n"
                  "# CONFIG_AUFS_FS is not set\n# CONFIG_CFI is not set\n")
    write_config(gcc_config)
    calls.write_text("")
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree),
                  "eevdf os -o3 llvm-lto-none -llvm-lto-thin -bore -autofdo -propeller"], env=env)
    assert result.returncode == 0, result.stdout
    invoked = calls.read_text().splitlines()
    assert all("CC=gcc" in line and "LLVM=1" not in line for line in invoked), invoked
    print("PASS: LTO_NONE case selects gcc without LLVM args")

    write_config(gcc_config)
    calls.write_text("")
    gcc_use = "eevdf os -o3 llvm-lto-none -llvm-lto-thin -bore -autofdo -propeller"
    result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree), gcc_use],
                 env=dict(env, CCACHE_DIR=str(temp / "ccache")))
    assert result.returncode == 0, result.stdout
    assert all("CC=ccache gcc" in line and " CC=gcc" not in line
               for line in calls.read_text().splitlines()), calls.read_text()
    no_gcc = temp / "bin-no-gcc"
    no_gcc.mkdir()
    for stub in tools.iterdir():
        if stub.name != "gcc":
            (no_gcc / stub.name).symlink_to(stub)
    llvm_only = dict(env, PATH=f"{no_gcc}:{core}")
    assert not shutil.which("gcc", path=llvm_only["PATH"])
    write_config(gcc_config)
    calls.write_text("")
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree), gcc_use], env=llvm_only)
    assert result.returncode == 0, result.stdout
    assert all("LLVM=1" in line for line in calls.read_text().splitlines())
    print("PASS: GCC full builds keep ccache; LLVM-only stage3 supports LTO_NONE")

    # Default-case drift: a make stub that drops the *default* BORE, ThinLTO,
    # AutoFDO, Propeller must fail, not false-green.
    write_config(thin)
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree), ""],
                 env=dict(env, MAKE_DROP="SCHED_BORE,LTO_CLANG_THIN,AUTOFDO_CLANG,PROPELLER_CLANG"))
    assert result.returncode != 0, result.stdout
    assert "Feature lost" in result.stdout, result.stdout
    print("PASS: make-stub default drift (BORE/LTO/AutoFDO/Propeller) fails")

    # Rust loss must fail a full build and surface in the synced config.
    rust_config = thin + "CONFIG_RUST=y\n"
    write_config(rust_config)
    result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree), "", str(evidence)],
                 env=dict(env, MAKE_DROP="RUST"))
    assert result.returncode != 0, result.stdout
    assert "RUST" in result.stdout, result.stdout
    assert "CONFIG_RUST=" not in (evidence / "config.final").read_text()
    status = (evidence / "toolchain.env").read_text()
    assert "status=failed" in status and "rust=lost" in status
    assert "finished=" in status, status
    print("PASS: olddefconfig Rust loss fails full mode; evidence records loss")

    # Rust kept + toolchain present passes; missing rustc fails full mode.
    write_config(rust_config)
    result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree), "", str(evidence)],
                 env=env)
    assert result.returncode == 0, result.stdout
    assert (evidence / "toolchain.env").read_text().count("rust=y")
    tools_no_rustc = temp / "bin-no-rustc"
    tools_no_rustc.mkdir()
    for stub in tools.iterdir():
        if stub.name != "rustc":
            (tools_no_rustc / stub.name).symlink_to(stub)
    no_rustc = dict(env)
    no_rustc["PATH"] = f"{tools_no_rustc}:{core}"
    assert not shutil.which("rustc", path=no_rustc["PATH"]), \
        shutil.which("rustc", path=no_rustc["PATH"])
    write_config(rust_config)
    result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree), ""], env=no_rustc)
    assert result.returncode != 0 and "Rust" in result.stdout, result.stdout
    # sched is explicitly C-only: RUST kept with missing tools is recorded,
    # not claimed as coverage.
    write_config(rust_config)
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree), "", str(evidence)],
                 env=no_rustc)
    assert result.returncode == 0, result.stdout
    assert "rust=limited" in (evidence / "toolchain.env").read_text()
    print("PASS: full enforces Rust toolchain; sched records C-only limitation")

    # Failure trap keeps the original exit, latest synced config and finish.
    write_config(thin)
    evidence2 = temp / "evidence-fail"
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree), "", str(evidence2)],
                 env=dict(env, MAKE_EXIT="2",
                          MAKE_WRITE_CONFIG="CONFIG_LTO_NONE=y\n"))
    assert result.returncode != 0
    assert (evidence2 / "config.final").read_text() == "CONFIG_LTO_NONE=y\n"
    record = (evidence2 / "toolchain.env").read_text()
    assert "status=failed" in record and "finished=" in record
    print("PASS: failure evidence keeps synced config, status and finish time")

    # Full mode invokes both real link targets with deterministic metadata.
    write_config(rust_config)
    calls.write_text("")
    result = run(["bash", str(HELPER), "full", str(EBUILD), str(tree), "bore", str(evidence)],
                 env=env)
    assert result.returncode == 0, result.stdout
    invoked = [l for l in calls.read_text().splitlines() if l.startswith("make ")]
    assert len(invoked) == 3, invoked
    assert "bzImage" in invoked[1] and "modules" in invoked[2]
    assert "KBUILD_BUILD_TIMESTAMP=1970-01-01" in invoked[1]
    record = (evidence / "toolchain.env").read_text()
    assert "status=passed" in record
    print("PASS: full mode runs olddefconfig, bzImage and modules with evidence")

    # Negative expectations: an eevdf case fails if BORE sneaks back on.
    write_config(thin)  # has CONFIG_SCHED_BORE=y
    result = run(["bash", str(HELPER), "sched", str(EBUILD), str(tree),
                  "eevdf -bore"], env=env)
    assert result.returncode != 0
    assert "stay off" in result.stdout, result.stdout
    print("PASS: unselected scheduler staying on fails the negative check")

    # Pre-7.3/LTS effective cases go through the same expectations.
    ebuild_618 = ROOT / "sys-kernel/cachyos-sources/cachyos-sources-6.18.55.ebuild"
    lts_default = ("CONFIG_LTO_NONE=y\n# CONFIG_SCHED_BORE is not set\n"
                   "CONFIG_TCP_CONG_BBR3=y\nCONFIG_DEFAULT_TCP_CONG=\"bbr3\"\n"
                   "CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y\n"
                   "CONFIG_HZ_1000=y\nCONFIG_HZ=1000\nCONFIG_X86_NATIVE_CPU=y\n"
                   "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y\n"
                   "CONFIG_NO_HZ_FULL=y\nCONFIG_CACHY=y\n"
                   "CONFIG_PREEMPT=y\nCONFIG_PREEMPT_DYNAMIC=y\n"
                   "CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y\n"
                   "# CONFIG_CFI is not set\n# CONFIG_AUFS_FS is not set\n")
    write_config(lts_default)
    result = run(["bash", str(HELPER), "olddefconfig", str(ebuild_618), str(tree), ""],
                 env=env)
    assert result.returncode == 0, result.stdout
    result = run(["bash", str(HELPER), "olddefconfig", str(ebuild_618), str(tree), ""],
                 env=dict(env, MAKE_DROP="TRANSPARENT_HUGEPAGE_ALWAYS"))
    assert result.returncode != 0
    print("PASS: 6.18 LTS default case asserted (and drift detected)")
    lts_rt = lts_default.replace("CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y\n", "") \
        .replace("CONFIG_PREEMPT=y\n", "").replace("CONFIG_PREEMPT_DYNAMIC=y\n", "") \
        + "CONFIG_PREEMPT_RT=y\n"
    write_config(lts_rt)
    result = run(["bash", str(HELPER), "sched", str(ebuild_618), str(tree), "rt -eevdf"], env=env)
    assert result.returncode == 0, result.stdout
    result = run(["bash", str(HELPER), "sched", str(ebuild_618), str(tree),
                  "rt -eevdf hugepage-always"], env=env)
    assert result.returncode != 0 and "TRANSPARENT_HUGEPAGE_ALWAYS" in result.stdout
    print("PASS: LTS implicit THP default respects RT; explicit incompatible request fails")
    for version in ("6.18.55", "7.2.11", "7.3.0-r3"):
        ebuild = ROOT / f"sys-kernel/cachyos-sources/cachyos-sources-{version}.ebuild"
        baseline = lts_default if version.startswith("6.") else thin
        write_config(baseline)
        result = run(["bash", str(HELPER), "olddefconfig", str(ebuild), str(tree), ""], env=env)
        assert result.returncode == 0, (version, result.stdout)
        for symbol in ("PREEMPT", "PREEMPT_DYNAMIC", "CPU_FREQ_DEFAULT_GOV_PERFORMANCE"):
            write_config(baseline)
            result = run(["bash", str(HELPER), "full", str(ebuild), str(tree), ""],
                         env=dict(env, MAKE_DROP=symbol))
            assert result.returncode != 0, (version, symbol, result.stdout)
    print("PASS: retained older-version defaults cannot disappear during synchronization")

# Actual BORE compile: red without the fix, green with it, real clang/Kbuild.
if ISSUE60_TREE.is_dir() and (ISSUE60_TREE / ".config").is_file() and PATCH.is_file():
    with tempfile.TemporaryDirectory(prefix="ci-kbuild-issue60-", dir="/var/tmp") as tmp:
        scratch = Path(tmp) / "linux-7.3.1-cachyos"
        # Own scratch copy: the read-only evidence tree is never modified.
        shutil.copytree(ISSUE60_TREE, scratch, symlinks=True)
        fair = scratch / FAIR
        original = fair.read_bytes()
        try:
            subprocess.run(["patch", "-R", "-p1", "--fuzz=0", "-d", str(scratch), "-i", str(PATCH)],
                           check=True, capture_output=True)
            red = run(["bash", str(HELPER), "sched", str(EBUILD), str(scratch), "bore"])
            assert red.returncode != 0
            assert "normalized_sysctl_sched_base_slice" in red.stdout, red.stdout
            print("PASS: actual unfixed BORE kernel/sched/ compile fails with the issue-60 error")
        finally:
            fair.write_bytes(original)
        green = run(["bash", str(HELPER), "sched", str(EBUILD), str(scratch), "bore"])
        assert green.returncode == 0, green.stdout
        assert (scratch / "kernel/sched/fair.o").is_file()
        print("PASS: actual patched BORE kernel/sched/ compile produces fair.o")
else:
    print("SKIP: real BORE red/green needs .ci/issue60 tree and shared patch")

# Shared changed-path -> retained-version detector (same module both
# workflows call; assert the concrete mappings the review found broken).
detect = expected_module.affected_versions
assert detect(["sys-kernel/cachyos-kernel/cachyos-kernel-6.18.55.ebuild"]) == ["6.18.55"]
assert detect(["sys-kernel/cachyos-sources/files/cachyos-sources-prjc-futex-schedule.patch"]) \
    == ["6.18.55", "7.2.11"]
assert detect(["sys-kernel/cachyos-sources/files/cachyos-sources-7.3.0-muqss-rebase.patch"]) \
    == ["7.3.0-r3", "7.3.1"]
assert detect(["sys-kernel/cachyos-kernel/files/cachyos-sources-7.3.0-muqss-rebase.patch"]) \
    == ["7.3.0-r3", "7.3.1"]
assert "7.3.0" not in detect(["sys-kernel/cachyos-sources/files/cachyos-sources-7.3.0-muqss-rebase.patch"])
assert detect(["tests/ci-kernel-kbuild.sh"]) == ["6.18.55", "7.2.11", "7.3.0-r3", "7.3.1"]
assert detect(["tests/ci_kernel_expected.py"]) == detect(["tests/ci-kernel-kbuild.sh"])
for path in ("tests/ci-binpkg-producer.sh", "tests/ci-binpkg-consumer.sh",
             "tests/ci-portage-setup.sh", "tests/ci_matrix_cases.py",
             "tests/test-ci-binpkg-lifecycle.py"):
    result = run([sys.executable, str(ROOT / "tests/ci_kernel_expected.py"), "detect"],
                 input=path + "\n")
    assert result.returncode == 0, result.stdout
    assert result.stdout.splitlines() == ["6.18.55", "7.2.11", "7.3.0-r3", "7.3.1"], path
assert detect([".github/workflows/ebuild-kernel-build.yml"]) == detect(["tests/ci-kernel-kbuild.sh"])
assert detect([".github/workflows/ebuild-test-musl-llvm.yml"]) == detect(["tests/ci-kernel-kbuild.sh"])
assert detect(["sys-kernel/cachyos-sources/files/6.19.0/misc/0002-fix-autofdo-propeller-lto-thin-dist.patch"]) \
    == ["6.18.55", "7.2.11", "7.3.0-r3", "7.3.1"]
# The former local BORE fix is retained as an unused file after the official refresh.
assert detect(["sys-kernel/cachyos-sources/files/cachyos-sources-7.3.1-bore-protect-slice.patch"]) == []
assert detect(["app-admin/ananicy-cpp/ananicy-cpp-1.0.ebuild"]) == []
print("PASS: detector maps ebuilds/shared patches/helpers to retained versions only")

# Both workflows call the shared detector and trigger on its inputs.
glibc = (ROOT / ".github/workflows/ebuild-test.yml").read_text()
musl = (ROOT / ".github/workflows/ebuild-test-musl-llvm.yml").read_text()
for name, text in (("glibc", glibc), ("musl", musl)):
    assert "ci_kernel_expected.py detect" in text, name
    assert "cachyos-kernel/**" in text, name
    assert "ci_kernel_expected.py" in text, name
    assert "ebuild-kernel-build.yml" in text, name
    assert "test-ci-kernel-kbuild.py" in text, name
    assert 'ebuild-(test(-musl-llvm)?|binpkg-cleanup)' not in text, \
        "stale broken WORKFLOW_CHANGED regex must be gone"
print("PASS: workflows share the detector and trigger on kernel/helper paths")

# Execute actual workflow step bodies; only package/compiler calls are stubbed.
with tempfile.TemporaryDirectory(prefix="ci-workflow-boundaries-", dir="/var/tmp") as tmp:
    scratch = Path(tmp)
    tools = scratch / "bin"
    tools.mkdir()
    calls = scratch / "calls"
    output = scratch / "output"
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
               CALLS=str(calls), GITHUB_OUTPUT=str(output), REAL_PYTHON=sys.executable)
    tool_stub(tools, "bash", '''case "$1" in
  tests/ci-binpkg-consumer.sh) echo consumer >> "$CALLS"; exit 0 ;;
  tests/ci-kernel-kbuild.sh)
    echo kbuild >> "$CALLS"
    if [[ "$MISSING_TREE" == 1 ]]; then exec /bin/bash "$@"; fi
    exit 0 ;;
  *) exec /bin/bash "$@" ;;
esac''')
    tool_stub(tools, "python3", '''if [[ "$1" == tests/test-source-features.py ]]; then
  echo verify >> "$CALLS"
  exit 0
fi
exec "$REAL_PYTHON" "$@"''')
    names = ("Consume binary deps and merge source ebuild",
             "Compile installed scheduler directory", "Verify installed source features")
    for flags, missing, wanted_status, wanted_calls in (
            ("bmq-lfbmq -bore -eevdf", True, 0, []),
            ("bore -eevdf", False, 0, ["consumer", "kbuild", "verify"]),
            ("bore -eevdf", True, 2, ["consumer", "kbuild"])):
        calls.write_text("")
        output.write_text("")
        status = 0
        for name in names:
            block, body = workflow_step(glibc, name)
            condition = re.search(r"^      if: (.+)$", block, re.M)
            if condition:
                assert condition[1] == "steps.merge.outputs.installed == 'true'", condition[1]
                if "installed=true" not in output.read_text().splitlines():
                    continue
            body = body.replace("${{ matrix.version }}", "7.3.1") \
                .replace("${{ matrix.use_flags }}", flags) \
                .replace("/usr/src/", str(scratch / "usr-src") + "/")
            result = run(["/bin/bash", "-c", body], cwd=ROOT,
                         env=dict(env, MISSING_TREE=str(int(missing))))
            status = result.returncode
            if status:
                break
        assert status == wanted_status, (flags, status, result.stdout)
        assert calls.read_text().splitlines() == wanted_calls, (flags, calls.read_text())
    print("PASS: decoded workflow skips unsupported cases, compiles supported cases, fails missing trees")

    # Model status-D output without deleting, staging or committing real files.
    tool_stub(tools, "git", '''[[ "$1" == diff ]] || exit 0
for arg in "$@"; do
  [[ "$arg" == --diff-filter=AM ]] && exit 0
done
printf '%s\\n' "$DELETED_PATH"''')
    deleted_cases = (
        ("sys-kernel/cachyos-sources/files/cachyos-sources-prjc-futex-schedule.patch",
         {"6.18.55", "7.2.11"}),
        ("sys-kernel/cachyos-sources/files/unused-ci-fixture.patch", set()),
        ("sys-kernel/cachyos-sources/cachyos-sources-99.0.0.ebuild", set()),
        ("tests/ci-binpkg-consumer.sh", set(detect(["tests/ci-kernel-kbuild.sh"]))),
    )
    for text in (glibc, musl):
        _, body = workflow_step(text, "Detect new ebuild versions")
        body = body.replace("${{ github.event_name }}", "pull_request")
        body = re.sub(r"\$\{\{ github\.[^}]+\}\}", "fixture-base", body)
        for path, wanted in deleted_cases:
            output.write_text("")
            result = run(["/bin/bash", "-e", "-o", "pipefail", "-c", body], cwd=ROOT,
                         env=dict(env, DELETED_PATH=path))
            assert result.returncode == 0, result.stdout
            actual = json.loads(output.read_text().strip().split("versions=", 1)[1])
            assert set(actual) == wanted, (path, actual, wanted)
    print("PASS: both decoded detectors retain deletion consumers without inventing version jobs")

# Manual workflow: env-passed inputs, validated case through producer and
# consumer, binary-only prereqs, real full targets, bounded ccache/timeout.
manual = (ROOT / ".github/workflows/ebuild-kernel-build.yml").read_text()
assert "workflow_dispatch:" in manual and 'Manual Kernel Build' in manual
# Inputs must arrive through env:, never interpolated into a run: body.
for block in manual.split("run: |")[1:]:
    step = block.split("\n    - name:", 1)[0]
    assert "${{ github.event.inputs" not in step, step[:200]
assert "MANUAL_VERSION:" in manual and "MANUAL_USE_FLAGS:" in manual
assert "ci_kernel_expected.py validate" in manual
assert "dev-util/ccache" in manual and "dev-builds/ccache" not in manual
assert "--usepkgonly" in manual and "|| emerge" not in manual
assert "--case" in manual and "--extra-deps" in manual
assert "ci-binpkg-producer.sh /tmp/manual-version.txt glibc" in manual
assert "ci-binpkg-consumer.sh /ci-binpkg" in manual
assert "timeout 4h" in manual and "ci-kernel-kbuild.sh full" in manual
full_job = manual.split("\n  full-build:", 1)[1]
job_budget = int(re.search(r"^    timeout-minutes: (\d+)$", full_job, re.M).group(1))
step_budgets = [int(re.search(r"^      timeout-minutes: (\d+)$", step, re.M).group(1))
                for step in full_job.split("\n    - name:")[1:]]
assert job_budget <= 360 and sum(step_budgets) <= job_budget - 20, step_budgets
assert 'kernel-build-evidence-' in manual
assert "dev-lang/rust-bin" in manual and "dev-util/bindgen" in manual
cleanup = (ROOT / ".github/workflows/ebuild-binpkg-cleanup.yml").read_text()
assert '"Manual Kernel Build"' in cleanup and 'ci-binpkgs-manual-' in cleanup
assert 'ci-binpkgs-manual-${runId}-${attempt}' in cleanup
assert 'kernel-build-evidence-' not in cleanup, "evidence must outlive dependency cleanup"
print("PASS: manual workflow env-inputs, validated case, binary-only prereqs, bounded full build")

# Validation must reject malicious/multiline inputs before any package call.
validation_files = tempfile.TemporaryDirectory(prefix="ci-manual-inputs-", dir="/var/tmp")
input_root = Path(validation_files.name)
evil = [f'7.3.1$(touch {input_root / "pwned"})', '7.3.1`id`', '7.3.1;id', '7.3.1\nkcfi',
        '7.3.1 || true']
validation = manual.split("Validate requested version and USE case", 1)[1] \
    .split("- name:", 1)[0]
script = validation.split("run: |", 1)[1]
script = "\n".join(line[8:] for line in script.splitlines() if line.strip())
script = script.replace("/tmp/manual-", str(input_root / "manual-"))
for bad in evil:
    result = run(["bash", "-c", script], cwd=ROOT,
                 env=dict(os.environ, MANUAL_VERSION=bad, MANUAL_USE_FLAGS="bore"))
    assert result.returncode != 0, (bad, result.stdout)
    assert not (input_root / "pwned").exists()
    result = run(["bash", "-c", script], cwd=ROOT,
                 env=dict(os.environ, MANUAL_VERSION="7.3.1", MANUAL_USE_FLAGS=bad))
    assert result.returncode != 0, (bad, result.stdout)
multiline = run(["bash", "-c", script], cwd=ROOT,
                env=dict(os.environ, MANUAL_VERSION="7.3.1",
                         MANUAL_USE_FLAGS="bore\nkcfi"))
assert multiline.returncode != 0
good = run(["bash", "-c", script], cwd=ROOT,
           env=dict(os.environ, MANUAL_VERSION="7.3.1", MANUAL_USE_FLAGS="bore o3"))
assert good.returncode == 0, good.stdout
assert (input_root / "manual-case.txt").read_text().strip() == "7.3.1|bore o3"
bad_flag = run(["bash", "-c", script], cwd=ROOT,
               env=dict(os.environ, MANUAL_VERSION="7.3.1", MANUAL_USE_FLAGS="bore fakeflag"))
assert bad_flag.returncode != 0
validation_files.cleanup()
print("PASS: manual input executes nothing before validation; multiline/unknown rejected")

# Producer manual mode enumerates only the validated case, not the matrix.
producer = (ROOT / "tests/ci-binpkg-producer.sh").read_text()
assert "--case" in producer and "--extra-deps" in producer
assert "ci_matrix_cases.py" in producer  # matrix still used without --case
print("PASS: producer keeps matrix default and restricts --case to one validated case")
