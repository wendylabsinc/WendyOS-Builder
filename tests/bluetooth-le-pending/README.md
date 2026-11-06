# Pending LE connection regression

Run `python3 tests/bluetooth-le-pending/run.py` (Python 3, a C compiler and `patch`).
The test downloads only `hci_sync.c` at the shipped Raspberry Pi, NVIDIA and
Qualcomm revisions, applies the backport with zero fuzz to the Pi and NVIDIA
sources, and compiles the actual callback with mocked kernel primitives. The
unpatched Pi and NVIDIA callbacks must fail the two-pending-dial cases, and all
seven patched paths must pass. The Qualcomm kernel (Dragonwing and Arduino
Uno Q) already carries the fix, so its shipped callback must pass unpatched;
its reference release is asserted on every path, and the test checks that the
Qualcomm append no longer applies the backport. `--sources DIR` accepts cached
`pi.c`, `jetson.c` and `qcom.c` files for offline testing.

Update the source URLs with the corresponding vendor recipe pins when kernels
are upgraded. This checks callback behavior, not radio or full-kernel behavior;
image builds and hardware BLE validation remain required.

Jetson scan-interruption ordering
--------------------------------

`python3 tests/bluetooth-le-pending/run-scan-order.py` applies the Jetson-only
backport to checksum-pinned NVIDIA source and executes its actual create,
scan-disable, and scan-completion functions. The mock controller delivers
completion during the synchronous call. Twelve cases cover discovery state,
no redundant advertising work, one existing advertising-resume call,
legacy/extended creation,
no-scan/suspend no-op, disable errors/cancellation, and real create timeout.
The original source must fail and the patched source must pass.

The no-premature-cancel assertion covers the direct create function only;
downstream pending-connection teardown remains governed by the existing
callback. Hardware HCI capture still verifies actual advertising and traffic.

Upstream ordering fix: Linux `2cabe7ff1001b7a197009cf50ba71701f9cbd354`.
Pi and Qualcomm pins already have that ordering; this backport targets Jetson.
The local adaptation clears an unconsumed interruption flag on failed/skipped
disable and exits through advertising restoration below create cancellation.
