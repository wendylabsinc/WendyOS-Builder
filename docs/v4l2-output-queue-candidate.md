# Candidate OUTPUT queue correction

This patch is an unreleased candidate. Disposable hosted Linux kernel and Wendy
consumer checks pass; physical hardware and broader module acceptance remain pending.
It must not be used only in CI while the image recipe remains unpatched. The
recipe keeps upstream source revision
`0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4` and applies the checked-in patch to every
image using this shared module. No public ioctl layout or version is changed.

The observed WendyOS media run `43364935455`, job `131687444104`, used that
unmodified revision. Its actual GStreamer log reported an OUTPUT buffer that
had not been queued, then stopped the producer. The capture-readiness failure
was a later symptom. The `producer-write` diagnostic does not supply a working
alternative: GStreamer's V4L2 OUTPUT `io-mode=rw` implementation logs
`implement write()` without writing frames.

Upstream [PR 656](https://github.com/v4l2loopback/v4l2loopback/pull/656) discusses
the same allocation/completion confusion; it was open and unmerged when this
candidate was prepared. This patch is a separate correction. It retains the
allocated-buffer list and existing capture-position mapping instead of replacing
that list with an OUTPUT completion queue.

The invariant is: an OUTPUT buffer is eligible for DQBUF only after its write
metadata and capture position have been finalized, and that completion can be
returned at most once until another write. A new `output_pending` field is
protected by `list_lock`. Publishing DONE metadata and this field happens under
the same lock; DQBUF consumes it under that lock. Allocation and STREAMOFF clear
OUTPUT completions. A CAPTURE allocation does not clear a producer's pending
completion. Empty nonblocking DQBUF returns EAGAIN; blocking DQBUF waits on the
existing event and STREAMOFF wakes it. MMAP OUTPUT poll readiness follows the
pending completions; write(2) polling and capture polling retain their behavior.

Wendy's existing H.264 producer intentionally reuses mapped OUTPUT buffers
without DQBUF. Repeated writes keep the latest completion of each index and move
that index to the existing list tail. This candidate does not introduce a
requirement that such writers dequeue. The existing Wendy consumer gates pass. Sustain-framerate, timeout-image and
simultaneous writer/reader restart observations remain pending below.

## Required disposable Linux proof

Use the existing WendyOS Linux media job, its owned module and bounded process
guardian. Do not load this candidate on a developer host or physical device.
Do not omit any currently required consumer gate, add another runner, or turn
an expected timeout into a passing negative control.

1. Compile the WendyOS services test binary with `-race -tags
   regression_camera_fixture`. With the original module loaded, run
   `TestIPCameraOutputQueueLifecycle` using
   `WENDY_IPCAM_DELIVERY_DIAGNOSTIC=output-queue-lifecycle` and the fixture's
   existing hosted/root guards. Require ordinary exit 1 and the named
   `OUTPUT_QUEUE_CONTRACT` failure, not a timeout, skip or unrelated setup error.
   The test refuses an existing `/dev/video200` and creates/removes its own node.
2. Drain all owned processes and nodes, unload only the job-owned module, and
   rebuild the identical pinned source with this exact recipe patch. Record
   source revision, patch SHA256, kernel release, module hash and vermagic.
   Do not change max_buffers, force a different GStreamer sink, or relax the
   normal camera assertions.
3. Run the same lifecycle test, now requiring exit 0, no skips/races and
   `OUTPUT_QUEUE_LIFECYCLE_VERIFIED`. It checks exact completions, duplicates,
   capture-allocation coexistence, the existing no-DQBUF producer convention,
   empty MMAP poll readiness, STREAMOFF cancellation, and same-fd restart. It
   observes the owned waiter in the exact DQBUF syscall before stopping it.
4. Run the unchanged authenticated RTSP/decoded-pixel IP-camera lifecycle gate,
   including its container-demand control. Run every existing Lite camera,
   shared camera, Go2, V4L2 sample-ledger and dual audio/video gate against this
   same patched module. They must demonstrate actual frames, identity joins,
   release/reacquisition and final node cleanup. Preserve full producer logs.
5. Add qualified sustain-framerate/timeout-image and simultaneous writer/reader
   restart observations before proposing release beyond the supported Wendy
   consumer paths. A source check or compile cannot replace these observations.

A failed or interrupted drain retains the owned scratch/node for the job's
existing final teardown. Any unproven module or consumer behavior remains pending.
The patch affects a kernel module shared by all virtual cameras, so it needs
review and runtime evidence before publication or release.

## Observed hosted execution

WendyOS head `2debcbb5aad06e78d332dee33a167cc632614931` ran the exact Builder
recipe and patch at `4828717a29aa3e7d3b183c6683155337957af39f` in the
[existing Linux media job](https://github.com/wendylabsinc/WendyOS/actions/runs/43378091991/job/131729254419).
The complete job passed. With two OUTPUT buffers allocated and only buffer0
queued, the original module returned buffer1 and failed `OUTPUT_QUEUE_CONTRACT`.
The candidate returned buffer0 once, then EAGAIN, and passed the completion,
poll, STREAMOFF and restart checks. Artifact14015471622 records exact source,
patch, recipe, module and kernel provenance.

The same loaded candidate passed authenticated Lite frames, H264 decoding,
shared SensorLink and app-owned capture, Go2 camera-entitled OCI delivery,
model sample-identity recording, and the authenticated IP-camera lifecycle.
The IP-camera run observed two RTSP sessions, retained viewer and container
demand through the idle grace period, reacquired capture, joined the writer
and removed its node. Removing container demand failed its named assertion.
Artifact14016307539 retains normal and control producer logs.

These observations satisfy items1–4 for the audited disposable runner. Item5
and broader target-kernel builds remain required before release. No physical
camera, target board or released-image execution is claimed.
