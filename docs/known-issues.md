# Known Issues

## KI-001 — Release-only crash in the render path: **root-caused 2026-07-27**

**Status**: root cause identified and mitigated. Upstream compiler bug, not
misuse. **Opened**: 2026-07-26. **Root-caused**: 2026-07-27.

### Root cause

Swift 6.3.3 miscompiles `TilemapRenderer.uploadInstances` in release builds: it
leaves the value of `MTLBuffer.contents()` in **`x21`, the arm64 `swifterror`
register**, on a control-flow path that never throws.

The Swift arm64 calling convention uses `x21` to carry a thrown error out of a
`throws` function: the caller zeroes it before the call and tests it after, and
a non-null value means "an error was thrown". Because the callee left a Metal
buffer pointer there, the caller concludes a throw occurred, passes that pointer
to `swift_getErrorValue`, and `_swift_getClass` traps reading a Metal-mapped
page as if it were a Swift error box.

The crash therefore has nothing to do with object lifetime. It is a corrupted
error-return register, which is why the symptom was `swift_getErrorValue` with
no throw site firing, and why `withExtendedLifetime` — which changes register
allocation — made it *worse* rather than better.

### The evidence

Measured on Apple M4, macOS 26.5.2, Swift 6.3.3 (swiftlang-6.3.3.1.3),
Xcode 26.6 (17F113), release build, `dfsim shot --scenario small-dig`.

**Direct register observation.** Breaking on the caller's two error checks in
`dfsimCLI_main`:

| checkpoint | `x21` | outcome |
|---|---|---|
| after `TilemapRenderer.init` — compiler emits `mov x21, #0x0` first | `0x0000000000000000` | correct, no error |
| after `capture` — no clear emitted, callee assumed to preserve | `0x0000000104b90000` | `cbnz x21` → catch → trap |

The caller's catch block is literally `mov x0, x21` / `bl swift_getErrorValue`,
so the trapping value is the swifterror register verbatim. At entry to
`swift_getErrorValue`, `x0 == x21 == 0x104c3c000`.

**The bogus "error" is the instance buffer.** The pointer's mapped region scales
exactly with the instance buffer, confirming identity:

| capture size | instance bytes | region at trap | pages |
|---|---|---|---|
| 40×24 | 34,560 | `0xC000` (49,152) | 3 |
| 80×48 | ~138,240 | `0x24000` (147,456) | 9 |

**Controlled experiments**, 15 release captures each, everything else held
identical:

| # | arrangement | result |
|---|---|---|
| A | `throws` + `withUnsafeBytes` closure + `instanceBuffer!` re-derived inside | **15/15 trapped** |
| B | **no `throws`**, closure and force-unwrap unchanged | **0/15** |
| C | `throws`, `rethrows` closure boundary removed entirely | **15/15 trapped** |
| D | `throws` + hoisted `destination` (the shipped arrangement) | 0/15 |

C is the informative one: the `rethrows` boundary is **not** the trigger — it
was the leading hypothesis and it is wrong. The trigger is `throws` on
`uploadInstances` combined with a register assignment that puts `contents()`
in `x21`. B shows that removing the error-return convention from that frame
fixes it even under the worst arrangement.

Adding a `FileHandle.standardError.write` of the pointer made the crash vanish,
which is why the original timeboxed investigation found instrumentation
"perturbed" the fault and had to resort to bisection.

### Mitigation in the tree

`uploadInstances` is **non-throwing**, and the destination pointer is resolved
before entering the copy closure. Two independent mitigations, because each was
separately measured to suppress the trap. The doc comment on the function says
not to re-add `throws` and why.

This is a workaround, not a cure. `draw` and `capture` remain `throws`, so the
same miscompile could in principle surface elsewhere in that chain. What would
catch it is unchanged and proven: `Scripts/ci.sh` runs a release capture, and
this bug is exactly what that gate exists to see.

### Guard proof

Per the constitution's "a guard that has never failed is unproven": the release
capture gate was observed firing during this investigation. Restoring
arrangement A produced 15 consecutive `Trace/BPT trap: 5`, exit 133, and
`ci.sh` fails on it rather than reporting a skip.

### Upstream

Worth reporting to the Swift project: an optimized `throws` function leaving a
live value in the `swifterror` register is a miscompile, and the reproducer is
small (a `throws` method that calls an ObjC method returning a pointer and
force-unwraps a stored optional property). Not yet filed — reducing to a
standalone file outside the package is the remaining work.

### Superseded hypotheses

Recorded so they are not re-investigated:

- **`MTLBuffer.contents()` lifetime.** Disproved: `withExtendedLifetime`, which
  is strictly stronger, reproduced the crash on every run.
- **Uninitialized memory in `ComponentStorage`/`ListStorage`/`MapStore`.** Real
  UB, fixed on its own merits 2026-07-26, and *not* this bug — arrangement A
  still failed 15/15 with every one of those fixes in place.
- **`withUnsafeBytes` vs `withUnsafeBufferPointer`.** Irrelevant; see C.
- **Metal misuse.** `MTL_DEBUG_LAYER=1` and `MTL_SHADER_VALIDATION=1` are silent,
  and `makeBuffer` never returns nil (a `fatalError` in that branch never fired).
