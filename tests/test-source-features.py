#!/usr/bin/env python3
"""Assert prepared CachyOS source/dist-kernel features, before or after olddefconfig.

Usage: python3 tests/test-source-features.py EBUILD TREE 'USE overrides'
Run make olddefconfig separately to also prove Kconfig dependency resolution.
"""
from pathlib import Path
import re
import sys

from portage.dep import check_required_use


def check(ebuild: Path, tree: Path, overrides: str) -> None:
    source = ebuild.read_text()
    flags = re.search(r'^IUSE="([^"]*)"', source, re.M).group(1).split()
    available = {f.lstrip('+-') for f in flags}
    if 'bore-dev' not in available:
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
        ('bore-dev', 'SCHED_BORE', 'kernel/sched/bore.c'),
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
    if 'bore-dev' in enabled:
        assert '7.0.0' in (tree / 'include/linux/sched/bore.h').read_text()
    if enabled & {'bmq', 'bmq-lfbmq', 'pds'}:
        expect('SCHED_ALT', 'y')
    if 'bmq-lfbmq' in enabled:
        exists('kernel/sched/sched_preempt_mask.c')
    if enabled & {'rt', 'rt-bore'}:
        expect('PREEMPT_RT', 'y')
    if 'poc-selector' in enabled or ('eevdf' in enabled and 'poc-selector' not in available):
        expect('SCHED_POC_SELECTOR', 'y')
        exists('kernel/sched/poc_selector.c')
    for flag, symbol, path in [
        ('governor-nap', 'CPU_IDLE_GOV_NAP', 'drivers/cpuidle/governors/nap/nap.c'),
        ('governor-reflex', 'CPU_FREQ_GOV_REFLEX', 'drivers/cpufreq/cpufreq_reflex.c'),
        ('aufs', 'AUFS_FS', 'fs/aufs/Kconfig'),
    ]:
        if flag in enabled:
            expect(symbol, 'y' if flag == 'governor-nap' else 'm')
            exists(path)
    if 'governor-reflex' in enabled:
        expect('CPU_FREQ_GOV_SCHEDUTIL', 'y')
        if '-7.2.' in ebuild.name:
            assert 'cpufreq_driver_adjust_perf(rfx_pol->policy,' in (tree / 'drivers/cpufreq/cpufreq_reflex.c').read_text()
    if 'sched-ext-peek' in available:
        ext = (tree / 'kernel/sched/ext.c').read_text()
        if 'sched-ext-peek' in enabled:
            expect('SCHED_CLASS_EXT', 'y')
            for text in ('scx_bpf_dsq_peek(u64 dsq_id)',
                         'BTF_ID_FLAGS(func, scx_bpf_dsq_peek, KF_RCU_PROTECTED | KF_RET_NULL)',
                         'rcu_assign_pointer(dsq->first_task, first_task)',
                         'was_empty && !(dsq->id & SCX_DSQ_FLAG_BUILTIN)',
                         'ret = check_hotplug_seq(sch, ops);'):
                assert text in ext, text
            common = (tree / 'tools/sched_ext/include/scx/common.bpf.h').read_text()
            assert common.index('scx_bpf_dsq_peek(u64 dsq_id) __ksym __weak') < common.index('#include "compat.bpf.h"')
            compat = (tree / 'tools/sched_ext/include/scx/compat.bpf.h').read_text()
            assert 'bpf_cpumask_populate(struct bpf_cpumask *dst' in compat
            assert compat.index('#define __COMPAT_bpf_cpumask_populate') < compat.index('__COMPAT_scx_bpf_dsq_peek') < compat.index('__COMPAT_is_enq_cpu_selected')
            exists('tools/testing/selftests/sched_ext/peek_dsq.bpf.c')
            exists('tools/testing/selftests/sched_ext/peek_dsq.c')
        else:
            assert 'scx_bpf_dsq_peek(u64 dsq_id)' not in ext
    if enabled & {'deckify', 'acpi-call'}:
        expect('ACPI_CALL', 'y' if 'deckify' in enabled else 'm')
        exists('drivers/platform/x86/acpi_call.c')
    for flag, symbols in {
        'adios': ['MQ_IOSCHED_ADIOS'],
        'vhba': ['VHBA'], 'v4l2loopback': ['V4L2_LOOPBACK'],
        'apple-t2': ['SENSORS_APPLESMC_T2', 'T2BCE_CORE', 'T2BCE_DMA', 'T2BCE_VHCI', 'T2BCE_AUDIO'],
        'asus-ally': ['HID_ASUS_ALLY'], 'asus-armoury': ['ASUS_ARMOURY'],
        'asus-wmi-legacy': ['ASUS_WMI_DEPRECATED_ATTRS'],
        'unprivileged-userns': ['USER_NS_UNPRIVILEGED'],
        'hda-aw88399': ['SND_HDA_SCODEC_AW88399', 'SND_HDA_SCODEC_AW88399_I2C'],
        'hda-max98390': ['SND_HDA_SCODEC_MAX98390', 'SND_HDA_SCODEC_MAX98390_I2C'],
    }.items():
        if flag in available:
            for symbol in symbols:
                if flag in enabled:
                    assert config.get(symbol) in ('y', 'm'), (flag, symbol, config.get(symbol))
                else:
                    expect(symbol, 'n')
    if 'clang-polly' in enabled:
        expect('POLLY_CLANG', 'y')
        assert 'CONFIG_POLLY_CLANG' in (tree / 'Makefile').read_text()
    if enabled & {'handheld', 'deckify'}:
        for symbol in ['MFD_STEAMDECK', 'HID_LENOVO_GO', 'ZOTAC_ZONE_HID']:
            expect(symbol, 'm')
        expect('HID_MSI_CLAW' if '-6.18.' in ebuild.name else 'HID_MSI', 'm')
        exists('drivers/mfd/steamdeck.c')
    if 'adios-default' in enabled:
        expect('MQ_IOSCHED_DEFAULT_ADIOS', 'y')
    if enabled & {'amd-private-color', 'deckify', 'handheld'}:
        expect('AMD_PRIVATE_COLOR', 'y')
    for flag, symbol, default in [
        ('anon-min-protection', 'ANON_MIN_RATIO', '1'),
        ('clean-low-protection', 'CLEAN_LOW_RATIO', '15'),
        ('clean-min-protection', 'CLEAN_MIN_RATIO', '4'),
    ]:
        if flag in available:
            expect(symbol, default if flag in enabled else '0')
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
