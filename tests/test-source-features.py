#!/usr/bin/env python3
"""Assert a prepared CachyOS source tree carries the selected implementations.

Usage: python3 tests/test-source-features.py EBUILD TREE 'USE overrides'

CONFIG symbols are asserted after olddefconfig by tests/ci-kernel-kbuild.sh
(tests/ci_kernel_expected.py); this checker only inspects patched source files
and never branches on the kernel version.
"""
from pathlib import Path
import re
import sys

from ci_kernel_expected import effective_flags, validate_case

SCHEDULER_FILES = {
    'bore': 'kernel/sched/bore.c',
    'cachyos-hardened': 'kernel/sched/bore.c',
    'rt-bore': 'kernel/sched/bore.c',
    'bmq': 'kernel/sched/bmq.h',
    'bmq-lfbmq': 'kernel/sched/bmq.h',
    'pds': 'kernel/sched/pds.h',
    'muqss': 'kernel/sched/MuQSS.c',
}


def check(ebuild: Path, tree: Path, overrides: str) -> None:
    source = ebuild.read_text()
    validate_case(source, overrides)
    enabled = effective_flags(source, overrides)
    config = dict(re.findall(r'^CONFIG_(\w+)=(.*)$', (tree / '.config').read_text(), re.M))

    def expect(symbol: str, value: str) -> None:
        assert config.get(symbol, 'n') == value, (ebuild.name, overrides, symbol, value, config.get(symbol))

    def exists(path: str) -> None:
        assert (tree / path).is_file(), f'{overrides}: missing implementation {path}'

    for selector, path in SCHEDULER_FILES.items():
        if selector in enabled:
            exists(path)
    if enabled & {'bmq', 'bmq-lfbmq', 'pds'}:
        alt_core = (tree / 'kernel/sched/alt_core.c').read_text()
        for helper in ('rt_mutex_futex_pre_schedule', 'rt_mutex_futex_post_schedule'):
            assert f'void {helper}(void)' in alt_core, f'missing futex scheduler API: {helper}'
    if 'bmq-lfbmq' in enabled:
        exists('kernel/sched/sched_preempt_mask.c')
    if config.get('SCHED_POC_SELECTOR') == 'y':
        exists('kernel/sched/poc_selector.c')
    if 'muqss' in enabled:
        assert 'source "kernel/Kconfig.MuQSS"' in (tree / 'init/Kconfig').read_text()
        assert 'config SCHED_MUQSS' in (tree / 'kernel/Kconfig.MuQSS').read_text()
    if 'aufs' in enabled:
        exists('fs/aufs/Kconfig')
    if 'kernel-builtin-zfs' in enabled:
        exists('zfs/META')
        exists('kernel-build.sh')
    if 'deckify' in enabled:
        exists('drivers/platform/x86/acpi_call.c')
        exists('drivers/mfd/steamdeck.c')
        # The backlight setter moved between files across releases; check wherever it lives.
        setter = re.compile(r'(?:static )?void amdgpu_dm_backlight_set_level\([^;]*?\n\{(.*?)\n\}', re.S)
        bodies = [match.group(1)
                  for path in sorted((tree / 'drivers/gpu/drm/amd/display/amdgpu_dm').glob('amdgpu_dm*.c'))
                  for match in [setter.search(path.read_text())] if match]
        assert len(bodies) == 1, f'expected one amdgpu_dm_backlight_set_level, found {len(bodies)}'
        assert 'u32 prev_brightness;' in bodies[0], 'handheld backlight uses undeclared prev_brightness'
    if ebuild.name.startswith('cachyos-kernel-'):
        expect('LOCALVERSION', '"-cachyos-dist"')
        expect('MODPROBE_PATH', '"/sbin/modprobe"')
    assert not list(tree.rglob('*.rej')), 'unhandled patch rejects'
    assert not (tree / 'tools/testing/selftests/tc-testing/action-ebpf').exists()
    print(f'PASS: {ebuild.name}: source tree assertions USE={overrides!r}')


if __name__ == '__main__':
    check(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
