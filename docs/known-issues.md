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

### Top lead for whoever picks this up

`ComponentStorage`, `ListStorage` and `MapStore` all allocate with
`UnsafeMutableBufferPointer.allocate(capacity:)` — which returns **uninitialized**
memory — and then write through subscript assignment (`dense[count] = value`)
rather than `initialize(to:)`. For trivial types this works in practice and is
widely done, but it is formally undefined: assignment to uninitialized memory
assumes a value is already there to overwrite. That is real UB in our own code,
it is layout-sensitive, and it is worth fixing on its own merits regardless of
whether it is this bug.

Fix shape: use `initialize(repeating:count:)` when growing, and
`initialize(to:)` for first writes into a slot, keeping plain assignment only
for slots known to hold a value.

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
