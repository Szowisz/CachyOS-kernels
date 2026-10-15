#!/usr/bin/env python3
"""Assert prepared CachyOS source/dist-kernel features, before or after olddefconfig.

Usage: python3 tests/test-source-features.py EBUILD TREE 'USE overrides'
Run make olddefconfig separately to also prove Kconfig dependency resolution.
"""
from pathlib import Path
import re
import sys

from portage.dep import check_required_use
from portage.versions import pkgsplit, vercmp


def check(ebuild: Path, tree: Path, overrides: str) -> None:
    source = ebuild.read_text()
    flags = re.search(r'^IUSE="([^"]*)"', source, re.M).group(1).split()
    available = {f.lstrip('+-') for f in flags}
    pv = pkgsplit(ebuild.stem)[1]
    if vercmp(pv, '6.18.55' if pv.startswith('6.18.') else '7.2.10') < 0:
        print(f'SKIP: {ebuild.name}: feature audit predates this checker')
        return
    enabled = {f[1:] for f in flags if f.startswith('+')}
    for flag in overrides.split():
        if flag.startswith('-'):
            enabled.discard(flag[1:])
        else:
            enabled.add(flag)
    required = re.search(r'^REQUIRED_USE="([^"]*)"', source, re.M).group(1)
    # The eclass validates LLVM slot selection; this checker tests source features.
    required = required.replace('${LLVM_REQUIRED_USE}', '')
    required = re.sub(r'!?llvm_slot_\d+', '', required)
    assert check_required_use(required, enabled, available.__contains__, eapi='8')
    config = dict(re.findall(r'^CONFIG_(\w+)=(.*)$', (tree / '.config').read_text(), re.M))

    def expect(symbol: str, value: str) -> None:
        assert config.get(symbol, 'n') == value, (ebuild.name, overrides, symbol, value, config.get(symbol))

    def exists(path: str) -> None:
        assert (tree / path).is_file(), f'{overrides}: missing implementation {path}'

    if 'kcfi' in enabled:
        expect('CFI', 'y')
    if 'kernel-builtin-zfs' in enabled:
        exists('zfs/META')
        exists('kernel-build.sh')
    for flag in enabled:
        if flag.replace('_', '-').startswith('hz-ticks-'):
            expect('HZ', flag.replace('_', '-').removeprefix('hz-ticks-'))
    if 'server' in available:
        expect('CACHY', 'n' if 'server' in enabled else 'y')
    for selector, symbol, path in [
        ('bore', 'SCHED_BORE', 'kernel/sched/bore.c'),
        ('cachyos-hardened', 'SCHED_BORE', 'kernel/sched/bore.c'),
        ('rt-bore', 'SCHED_BORE', 'kernel/sched/bore.c'),
        ('bmq', 'SCHED_BMQ', 'kernel/sched/bmq.h'),
        ('bmq-lfbmq', 'SCHED_BMQ', 'kernel/sched/bmq.h'),
        ('pds', 'SCHED_PDS', 'kernel/sched/pds.h'),
        ('muqss', 'SCHED_MUQSS', 'kernel/sched/MuQSS.c'),
    ]:
        if selector in enabled:
            expect(symbol, 'y')
            exists(path)
    if enabled & {'bmq', 'bmq-lfbmq', 'pds'}:
        expect('SCHED_ALT', 'y')
        alt_core = (tree / 'kernel/sched/alt_core.c').read_text()
        for helper in ('rt_mutex_futex_pre_schedule', 'rt_mutex_futex_post_schedule'):
            assert f'void {helper}(void)' in alt_core, f'missing futex scheduler API: {helper}'
        if pv.startswith('6.18.'):
            assert 'void sched_mm_cid_exit(struct task_struct *t)' in alt_core
            assert 'blk_plug_invalidate_ts(tsk)' not in alt_core
    if 'bmq-lfbmq' in enabled:
        exists('kernel/sched/sched_preempt_mask.c')
    if enabled & {'rt', 'rt-bore'}:
        expect('PREEMPT_RT', 'y')
    if 'eevdf' in enabled and '-6.18.' not in ebuild.name:
        expect('SCHED_POC_SELECTOR', 'y')
        exists('kernel/sched/poc_selector.c')
    if 'aufs' in enabled:
        expect('AUFS_FS', 'm')
        exists('fs/aufs/Kconfig')
    if 'deckify' in enabled:
        expect('ACPI_CALL', 'y')
        exists('drivers/platform/x86/acpi_call.c')
        display = (tree / 'drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c').read_text()
        backlight = re.search(r'static void amdgpu_dm_backlight_set_level\([^;]*?\n\{(.*?)\n\}', display, re.S).group(1)
        assert 'u32 prev_brightness;' in backlight, 'handheld backlight uses undeclared prev_brightness'
    if 'deckify' in enabled:
        for symbol in ['MFD_STEAMDECK', 'HID_LENOVO_GO', 'ZOTAC_ZONE_HID', 'HID_MSI']:
            expect(symbol, 'm')
        exists('drivers/mfd/steamdeck.c')
        expect('AMD_PRIVATE_COLOR', 'y')
    if ebuild.name.startswith('cachyos-kernel-'):
        expect('LOCALVERSION', '"-cachyos-dist"')
        expect('MODPROBE_PATH', '"/sbin/modprobe"')
        for flag, symbol in [
            ('llvm-lto-thin', 'LTO_CLANG_THIN'),
            ('llvm-lto-thin-dist', 'LTO_CLANG_THIN_DIST'),
            ('llvm-lto-full', 'LTO_CLANG_FULL'),
            ('llvm-lto-none', 'LTO_NONE'),
            ('autofdo', 'AUTOFDO_CLANG'), ('propeller', 'PROPELLER_CLANG'),
        ]:
            if flag in enabled:
                expect(symbol, 'y')
    assert not list(tree.rglob('*.rej')), 'unhandled patch rejects'
    assert not (tree / 'tools/testing/selftests/tc-testing/action-ebpf').exists()
    print(f'PASS: {ebuild.name}: source/config assertions USE={overrides!r}')


if __name__ == '__main__':
    check(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
