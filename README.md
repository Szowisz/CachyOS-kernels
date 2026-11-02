# CachyOS-kernels
Overlay containing ebuilds of CachyOS kernels and some other things

## Adding the overlay
``` sh
eselect repository enable CachyOS-kernels
```

## Sync overlay
``` sh
emaint sync -r CachyOS-kernels
```

## CI
Pull requests and pushes reuse each matrix case's installed `cachyos-sources`
tree and compile `kernel/sched/`. LLVM-required configurations use clang;
other configurations use gcc when available, or the LLVM-only stage3 toolchain.
This is a C-only fast check, not a full kernel/Rust build. It adds no Rust
toolchain downloads to the fast matrix and reports any Rust config loss.

The manual **Manual Kernel Build** dispatch accepts one retained version and USE
case, provisions build dependencies once, then builds `bzImage` and `modules`.
It preserves requested configuration, requires a working Rust toolchain when
enabled, limits full-build parallelism and ccache (2 GB), and saves failure
config/log/tool/timing evidence. Compilation is capped at four hours inside the
hosted job's six-hour ceiling; setup, cache and upload steps are bounded too.
Neither mode installs or boots a kernel.

Shared configuration and changed-path checks live in
`tests/ci_kernel_expected.py`; behavioral regressions are in
`tests/test-ci-kernel-kbuild.py`.
