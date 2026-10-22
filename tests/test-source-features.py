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
        if vercmp(pv, '7.3.0') >= 0:
            expect('ARCH_SUPPORTS_CFI', 'y')
            expect('CFI_AUTO_DEFAULT', 'y')
    if vercmp(pv, '7.3.0') >= 0:
        normalized = {flag.replace('_', '-') for flag in enabled}
        for flag, symbol in [
            ('tickrate-periodic', 'HZ_PERIODIC'), ('tickrate-idle', 'NO_HZ_IDLE'),
            ('tickrate-full', 'NO_HZ_FULL'),
            ('llvm-lto-thin', 'LTO_CLANG_THIN'), ('llvm-lto-full', 'LTO_CLANG_FULL'),
            ('llvm-lto-thin-dist', 'LTO_CLANG_THIN_DIST'), ('llvm-lto-none', 'LTO_NONE'),
            ('autofdo', 'AUTOFDO_CLANG'), ('propeller', 'PROPELLER_CLANG'),
            ('mnative', 'X86_NATIVE_CPU'), ('mzen4', 'MZEN4'),
            ('hugepage-always', 'TRANSPARENT_HUGEPAGE_ALWAYS'),
            ('hugepage-madvise', 'TRANSPARENT_HUGEPAGE_MADVISE'),
            ('o3', 'CC_OPTIMIZE_FOR_PERFORMANCE_O3'), ('debug', 'CC_OPTIMIZE_FOR_SIZE'),
        ]:
            if flag in normalized:
                expect(symbol, 'y')
        if not normalized & {'rt', 'rt-bore'}:
            expect('PREEMPT_DYNAMIC', 'y')
            expect('PREEMPT_LAZY' if 'preempt-lazy' in normalized else 'PREEMPT', 'y')
        for level in range(1, 5):
            if f'mgeneric-v{level}' in normalized:
                expect('GENERIC_CPU', 'y')
                expect('X86_64_VERSION', str(level))
        if 'bbr3' in enabled:
            expect('TCP_CONG_BBR', 'm')
            expect('TCP_CONG_BBR3', 'y')
            expect('DEFAULT_TCP_CONG', '"bbr3"')
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
        # 7.3 follows the shipped config: PKGBUILD no longer forces POC on.
        if vercmp(pv, '7.3.0') < 0:
            expect('SCHED_POC_SELECTOR', 'y')
        if config.get('SCHED_POC_SELECTOR') == 'y':
            exists('kernel/sched/poc_selector.c')
    if 'os' in enabled:
        expect('CC_OPTIMIZE_FOR_SIZE', 'y')
        expect('CC_OPTIMIZE_FOR_PERFORMANCE', 'n')
    if 'muqss' in enabled:
        if vercmp(pv, '7.3.0') < 0:
            expect('MUQSS_IOTIME', 'y')
        else:
            for symbol in ('SCHED_BORE', 'SCHED_ALT', 'SCHED_BMQ', 'SCHED_PDS',
                           'PREEMPT_RT', 'SCHED_POC_SELECTOR'):
                expect(symbol, 'n')
            # v0.32 uses standard HZ/tick/preemption choices, not legacy NODEF.
            assert 'config HZ_1000_NODEF' not in (tree / 'kernel/Kconfig.hz').read_text()
            for hz in (100, 250, 300, 500, 600, 750, 1000):
                if f'hz-ticks-{hz}' in normalized:
                    expect(f'HZ_{hz}', 'y')
        assert 'source "kernel/Kconfig.MuQSS"' in (tree / 'init/Kconfig').read_text()
        assert 'config SCHED_MUQSS' in (tree / 'kernel/Kconfig.MuQSS').read_text()
    if 'aufs' in enabled:
        expect('AUFS_FS', 'm')
        exists('fs/aufs/Kconfig')
    if 'deckify' in enabled:
        expect('ACPI_CALL', 'y')
        exists('drivers/platform/x86/acpi_call.c')
        if pv == '7.2.11':
            hid = (tree / 'drivers/hid/hid-steam.c').read_text()

            def body(name: str) -> str:
                definitions = re.findall(r'^static [^\n]*\b' + name + r'\([\s\S]*?^\}', hid, re.M)
                assert len(definitions) == 1, (name, len(definitions))
                return definitions[0]

            recv = body('steam_recv_report_id')
            assert 'u8 *data, int size, u8 report_id)' in recv
            assert 'unsigned int retries = 50;' in recv and 'u32 len;' in recv
            assert 'steam_recv_report_id(steam, reply, rsize, report_id)' in body('steam_exchange_report_id')
            assert re.search(r'\bsteam_recv_report\b', hid) is None
            assert 'steam_is_valve_interface(struct hid_device *hdev, int quirks)' in body('steam_is_valve_interface')
            assert 'steam_is_valve_interface(hdev, id->driver_data)' in body('steam_probe')
            cancel = 'cancel_delayed_work_sync(&steam->coalesce_rumble_work);'
            for name in ('steam_register', 'steam_unregister', 'steam_probe'):
                assert cancel in body(name), name
            assert 'guard(spinlock_irqsave)(&steam->lock);' in body('steam_raw_event')
            assert 'steam->lock' not in body('steam_do_ibex_battery_event')
            for name in ('steam_haptic_pulse', 'steam_haptic_rumble'):
                assert 'hid_hw_output_report(steam->hdev' in body(name), name
            assert 'STEAM_QUIRK_WIRELESS | STEAM_QUIRK_IBEX' in body('steam_register')
        backlight_file = 'amdgpu_dm_backlight.c' if vercmp(pv, '7.3.0') >= 0 else 'amdgpu_dm.c'
        display = (tree / 'drivers/gpu/drm/amd/display/amdgpu_dm' / backlight_file).read_text()
        backlight = re.search(r'(?:static )?void amdgpu_dm_backlight_set_level\([^;]*?\n\{(.*?)\n\}', display, re.S).group(1)
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
