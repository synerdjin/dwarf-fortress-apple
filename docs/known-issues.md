# Known Issues

## KI-001 — Release-only crash in the render path, not root-caused

**Status**: worked around, not understood. **Opened**: 2026-07-26.

### Symptom

`dfsim shot` traps (SIGTRAP, exit 133) in release builds while passing in debug.
Crash reports point at `swift_getErrorValue` → `_swift_getClass`, i.e. the
error-catching machinery reading a value that is not a valid error box. With one
arrangement of `TilemapRenderer.uploadInstances` it failed on every run; with
another it passes on every run.

### What the timeboxed investigation established

- **Reliably reproducible** in the failing arrangement — not intermittent.
- **AddressSanitizer reports no error, and the crash does not occur under it.**
  Instrumentation perturbs whatever the fault is.
- **Metal API and GPU validation are silent.** Adding `MTL_DEBUG_LAYER=1` and
  `MTL_SHADER_VALIDATION=1` produced no diagnostics, so this is not Metal misuse.
- **`device.makeBuffer` is not returning nil.** Replacing that throw with a
  `fatalError` carrying a marker string produced no marker, so the visible throw
  site never fires.
- **`withUnsafeBytes` vs `withUnsafeBufferPointer` is irrelevant.** Changing only
  that still crashed.
- **Hoisting `buffer.contents()` out of the copy closure makes it pass** — 15/15
  release captures and full `ci.sh` green.

### The hypothesis that was disproved

The obvious reading was a lifetime bug: `MTLBuffer.contents()` returns a raw
pointer that does not keep the buffer alive, so calling it inside the closure
would let the optimizer release the buffer before the copy ran.

That theory is **wrong**, or at least incomplete. Wrapping the same code in
`withExtendedLifetime(buffer) { … }` — which is strictly stronger than hoisting,
and is the documented fix for exactly that hazard — **fails on every run**. A
lifetime fix cannot make a lifetime bug worse. Whatever this is, it is sensitive
to code arrangement in a way a genuine `contents()` lifetime bug would not be.

### What this most likely means

The symptom moves with optimizer decisions (inlining, layout), which is the
signature of undefined behaviour somewhere else in the program surfacing at
whatever code the optimizer happens to arrange badly. The render path is where
it manifests, not necessarily where it lives.

### Eliminated: the uninitialized-memory lead (2026-07-26)

`ComponentStorage`, `ListStorage` and `MapStore` did write to memory from
`UnsafeMutableBufferPointer.allocate` via subscript assignment rather than
`initialize`, which is formally undefined. That has now been fixed throughout:
first writes use `initialize`, buffer growth uses `moveInitialize` instead of
`update`, removal deinitializes the slots that leave the live region, and
`MapStore.materialize` distinguishes a recycled run (already initialized) from a
freshly bumped one (not).

**It was not this bug.** With every one of those fixes in place, restoring the
crashing arrangement of `uploadInstances` still fails 15 out of 15 release
captures. The UB was real and worth fixing on its own merits, but it is not the
cause of KI-001, and the leading hypothesis is now eliminated rather than
merely untested.

### Remaining leads

Nothing strong remains. What is known: the fault is sensitive to code
arrangement in `uploadInstances` specifically; it survives correct memory
initialization everywhere else; ASan, Metal validation, and the visible throw
sites all come up empty; and `withExtendedLifetime` — strictly safer — makes it
worse rather than better, which no ordinary lifetime bug would do.

Suggested next steps for whoever picks this up, roughly in order of cost:
1. Reduce to a standalone file outside the package that reproduces it, so the
   surrounding code volume stops being a variable.
2. Inspect the optimized SIL/IR for the two arrangements and diff them, rather
   than reasoning about what the optimizer *should* do.
3. If a minimal reproducer exists, it is worth reporting upstream — the
   evidence is now more consistent with a compiler defect than with a misuse.

### Guard rails added

- `Scripts/ci.sh` runs the test suite in **release as well as debug**. Debug and
  release are demonstrably different programs in this project, and this bug hid
  for two milestones because only debug was routinely exercised.
- `ci.sh` no longer converts a capture crash into "no GPU reachable — skipped".
  The earlier version reported *all gates passed* while `shot` was broken.

### Do not

Re-apply `withExtendedLifetime` around this copy assuming it is safer. It is
correct in principle and reproduces the crash in practice; until the real cause
is found, the arrangement that passes is the one in the repository.
