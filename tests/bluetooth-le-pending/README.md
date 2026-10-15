# Pending LE connection regression

Run `python3 tests/bluetooth-le-pending/run.py` (Python 3, a C compiler and `patch`).
The test downloads only `hci_sync.c` at the shipped Raspberry Pi, NVIDIA and
Qualcomm revisions, applies the recipe-selected backport with zero fuzz, and
compiles the actual callback with mocked kernel primitives. The Qualcomm
callback is shared by Dragonwing and Arduino Uno Q; its reference release is
asserted on every path. The unpatched callbacks must fail the two-pending-dial
cases, and all seven patched paths must pass. `--sources DIR` accepts cached
`pi.c`, `jetson.c` and `qcom.c` files for offline testing.

Update the source URLs with the corresponding vendor recipe pins when kernels
are upgraded. This checks callback behavior, not radio or full-kernel behavior;
image builds and hardware BLE validation remain required.
