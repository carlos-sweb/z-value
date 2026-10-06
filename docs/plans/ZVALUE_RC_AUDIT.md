# z-value `Rc(T)` audit

*Date: 2026-10-06. Audited revision: z-value `master` at `15a153b`; z-interpreter `0d0e0d4`. Read-only: no code or test was changed; this file is not committed.*

`Rc(T)` (`src/rc.zig`, 76 lines) is the reference-counted box behind all 17 heap variants of `JSValue`. This audit asks three things:
- Is it sound?
- What can be hardened at an acceptable cost?
- What cannot be fixed without changing the model?

**Evidence conventions**
- **[measured]**: a program or test was run, and the number is its output.
- **[inspection]**: read from source, not executed.

Benchmarks were built with Zig 0.16.0 on this session's Linux VM. They are microbenchmarks: use them for the relative cost between variants, not as whole-program figures.

---

## 1. Inventory

### 1.1 `rc.zig`

The box is laid out as `Rc(T) = { count: usize, allocator: Allocator, value: T, gc_hook_ctx: ?*anyopaque, gc_hook: ?*const fn }`. The header is **40 bytes** on 64-bit [measured, earlier audit]: 8 for `count`, 16 for `allocator`, 16 for the two hook pointers. For a `date` box that is 40 of its 48 bytes.

| Function | Line | What it does |
|---|---|---|
| `create(allocator, value)` | `rc.zig:33-37` | Allocates the box and copies `value` into it (the payload moves, so it must be relocatable). `count = 1`. Fails only with `OutOfMemory`; `value` is untouched if it fails. |
| `setGcHook(ctx, hook)` | `:41-45` | Sets the hook. Silently overwrites a hook that was already set. |
| `retain()` | `:48-51` | `count += 1`. No overflow check (it would need 2⁶⁴ live references). |
| `decref()` | `:61-65` | `assert(count > 0)`, then `count -= 1`, returns `count == 0`. The assert exists only in Debug/ReleaseSafe. |
| `destroy()` | `:71-74` | Calls the hook (if set), then `allocator.destroy(self)`. Does **not** tear down `value`: the caller does that first. |

What `Rc` guarantees:
- The count starts at 1 and changes by exactly ±1 per call.
- Debug/ReleaseSafe abort if `decref` *reads* a count of 0.
- The hook runs before the memory is freed.

What it does **not** guarantee:
- tearing down the payload (that is `JSValue.deinit`'s job);
- thread safety (the count is a plain `usize`);
- cycle collection;
- detection of a release on a box that is already freed (see §2.2);
- protection of `count` from other readers (Zig has no private fields).

### 1.2 Who touches `count`

| Reader/writer | Where | What |
|---|---|---|
| `Rc` itself | `rc.zig:35, 49, 62-64` | Normal counting |
| Iterative `deinit` (`b231f38`) | `zvalue.zig:485-493` (`PendingRelease.push`/`pop`) | **Reuses `count` as the link of an intrusive list** while a box whose count reached 0 waits for its children to be released. Restores it to 0 before `destroy`. |
| z-value tests | **66 reads in 16 test files** [measured] | Assertions on live boxes only |
| z-interpreter | **0 reads** [measured] | Its GC hook only removes the box address from its registry (`interpreter_gc.zig:301-317`) |
| z-json, z-toml, z-yaml, z-run | **0** `Rc(` and 0 `.count` [measured] | — |

### 1.3 Users of `Rc`

**In z-value: 25 `Rc(...).create` sites.**
- The 20 constructors.
- The 5 clones: `cloneArray`, `cloneObject`, `cloneMap`, `cloneSet`, `cloneError`.

Every one of them is correct today on the out-of-memory path:
- Constructors that build their payload use `errdefer payload.deinit()`.
- Constructors that receive ownership use `errdefer input.deinit()`.
- Clones retain only after the box exists, or release what they had already copied.
- The 9 constructors with an allocation-free payload need nothing.

This is verified by the 17 out-of-memory tests that sweep every allocation (148/148 tests pass) [measured].

**Destruction.**
- One iterative function, `JSValue.deinit` → `releaseInto`/`drain` (`zvalue.zig:455-579`).
- `Callable`, `Proxy`, `DataViewBox` and `TypedArrayBox` keep their own `deinit` (each releases its JSValue fields), but `drain` deliberately does **not** call them; it releases the same fields itself so that recursion cannot come back (`zvalue.zig:498-504`).

**Outside z-value (z-interpreter only).**
- 20 `*Rc(T)` type references (`interpreter_gc.zig:57-101`, `interpreter_support.zig:220`).
- **1 raw `Rc.create`** (`interpreter_gc.zig:532`, `gcNewArrayBufferFromValue`).
- **21 direct `destroy()` calls**: the cycle collector frees garbage boxes regardless of their count (`interpreter_gc.zig:692+`).

### 1.4 Rc tests today

- `tests/rc_test.zig` has 7 tests:
  - 4 are really about `string` values;
  - 1 checks that `retain`/`deinit` on inline values are no-ops;
  - 1 is the out-of-memory test for `newString`;
  - 1 checks that the GC hook fires exactly once per box during an iterative release (20 000 boxes).
- Across the suite, 66 `.count` assertions check retain/release balance per variant, and `std.testing.allocator` catches leaks.

**Not covered:**
- `Rc(T)` with a non-JSValue `T`;
- `setGcHook` overwriting a hook;
- the underflow assertion actually firing (it cannot be caught in-process; it would need a `tests/tag_panic.zig`-style process check);
- a release on a box that is already freed (§2.2).

---

## 2. Failure classes

### 2.1 Payload built before `Rc.create` and leaked if it fails

- **In z-value: closed.** All 25 sites handle it (§1.3).
- **Still open outside z-value (z-interpreter, [inspection]):**
  - `gcNewArrayBufferFromValue` (`interpreter_gc.zig:531-535`) calls `Rc(ArrayBuffer).create(gc_allocator, v)` with an already-built `v`. If the box allocation fails, `v`'s bytes leak. Its caller (`arraybuffer_builtins.zig:139-141`, `ArrayBuffer.prototype.slice`) does not release `copy` on error either.
  - **All 20 `gcNew*` wrappers** do `const v = try JSValue.new…(); try self.gcTrack(v); return v;` with no `errdefer v.deinit()`. `gcTrack` ends in `gc_registry.put(...)` (`interpreter_gc.zig:358-359`), which can fail with `OutOfMemory`; the freshly built value then leaks. Same class, one layer up.
- **Can the class be eliminated?** Partly (see P1). It has two shapes:
  - **(a) "build, then box"**, which a `createWith` that allocates the box first and builds the payload in place removes structurally;
  - **(b) "receive ownership, then box"** (`fromRegex`, `newProxy`, `gcNewArrayBufferFromValue`, …), where the value already exists. `createWith` does not help there; only a consuming `create` does, which needs to know how to release a `T` (P1b).

### 2.2 Counter underflow

**Underflow means releasing a box that is already freed.**
- `decref` brings the count to 0 exactly once, and `releaseInto` then frees the box immediately (leaves, views) or after its children (containers).
- So a `decref` that *reads* 0 is always a read of freed memory. In other words it is a use-after-free, not a reachable "count is 0" state.
- The assert can only catch it if the freed memory still holds 0 and has not been reused.

Measured behavior of the two mistakes [measured, in separate processes]:

| Mistake | Allocator | Debug | ReleaseSafe | ReleaseFast |
|---|---|---|---|---|
| `v.deinit(); v.deinit();` (only reference) | `std.testing.allocator` (DebugAllocator) | **segfault** inside `decref` (the freed page is unmapped); the allocator catches it, not `Rc` | segfault | **segfault** |
| Same | `std.heap.smp_allocator` | `panic: reached unreachable code`: the `count > 0` assert fires because the freed memory reads 0 | same | **silent**: the second `deinit` returns normally |
| Over-release while another holder lives (`retain` once, `deinit` twice, then the holder's `deinit`) | `smp_allocator` | the box is freed under the live holder; the holder then reads `count == 0` → assert fires | same | **silent**: the holder's `deinit` returns normally |

**Consequence.** An always-on check (`if (count == 0) @panic`) costs nothing measurable (§3, P2). It turns *some* ReleaseFast cases from silent into a deterministic abort: the ones where the freed memory still reads 0. But it is **inherently unreliable**: if the allocator has already reused that memory for another box, the stale `decref` decrements *that* box's count, a silent corruption no counter check can see. Reliable detection needs extra state per allocation (a Debug-only registry, P3).

### 2.3 Double free from ownership confusion

**Inside z-value the contract is now uniform and tested:**
- All 20 constructors consume their JSValue inputs, also on failure (17 out-of-memory tests).
- All 10 mutation wrappers consume their inputs, also on failure (19 tests).
- The clones never consume `self`.

**Remaining hazard: two conventions coexist.**
- The raw payload APIs (`box.value.set`, `ZMap.set`, `ZSet.add`, `ZObject.defineProperty`, …) do **not** consume their argument when they fail. After a refusal or OOM, the caller still owns the value.
- The wrappers **do** consume it.

A caller that writes `errdefer v.deinit()` around a wrapper call frees twice; a caller that forgets it around a raw call leaks. The rule is documented in the README (Constructors: Ownership Contract), but not in each wrapper's doc comment next to its raw counterpart [inspection].

### 2.4 Leaks from cycles

Documented and by design. Measured leak sizes per cycle shape are in `ZVALUE_ROBUSTNESS_AUDIT.md` §3 A5 (96–491 bytes each). z-interpreter's tracing collector reclaims unreachable **tracked containers** whatever their count. Untracked leaves (strings, bigints) caught in a cycle-leaked container are released when that container is swept. No fix is possible inside `Rc` without a collector.

### 2.5 `count` reused as the deinit list link

- **Who reads it today:** only `Rc` and `PendingRelease` (§1.2). No consumer reads `count`, and z-interpreter's hook does not.
- **Who could read it wrongly in future:**
  - **A GC hook that inspects another box mid-teardown.** While `drain` runs, boxes waiting in its lists hold a *pointer* in `count`, not 0. A hook (fired from `destroy`) that reads a different box's `count`, for example a debug print or a "live references" counter, would see a large number. Today's only hook does not do that.
  - **A hook that resurrects a dying box** (`retain` on a box whose count already reached 0). That is undefined behavior anyway; with the list link, `retain` would add 1 to a pointer and corrupt the list.
  - **New code that adds a public `refCount()`** and is called during teardown.
- **Mitigation without cost:** document on the field; optionally rename the field (P4).

### 2.6 Not atomic; single-threaded

- **Documented** in the README (Known Limitations: "Single-threaded assumed"). **Not documented** in `rc.zig` itself [inspection].
- A plain `usize` read-modify-write is not safe across threads, and neither are:
  - the iterative `deinit`'s intrusive lists;
  - the GC hook;
  - every payload library (z-array, z-object, z-map … are not thread-safe).

---

## 3. Measurements

**Counter variants in ReleaseFast** (1024 counters, 2·10⁹ retain+decref pairs in a data-dependent order, median of 3 runs) [measured]:

| Variant | Total | Per pair | vs. today |
|---|---:|---:|---:|
| Today: `assert(count > 0)` (compiled out in ReleaseFast) | 1.20 s | ~0.60 ns | 1.0× |
| Always-on check `if (count == 0) @panic(...)` | 1.16 s | ~0.58 ns | ≈1.0× (within noise) |
| Atomic (`@atomicRmw` add `.monotonic` / sub `.acq_rel`, with check) | 24.2 s | ~12 ns | **≈20×** |

The atomic cost is for *uncontended* lock-prefixed operations on this VM. Contended counters would cost more.

**Debug-only live-box registry** (`AutoHashMap(address, void)`: put on create, a lookup on every retain/decref, remove on destroy; 10⁷ short-lived boxes, each with one retain+decref) [measured]:

| Build | Without registry | With registry |
|---|---:|---:|
| Debug | 1.0 s (≈0.1 µs per box lifetime) | **10.4 s** (≈1 µs per box lifetime), **≈10×** |
| ReleaseFast | 0.20 s | 0.23 s. The lookups sit inside `std.debug.assert` and the compiler removes them, so this is the put+remove cost only. A real always-on registry in ReleaseFast would cost more. |

---

## 4. Proposals

Each proposal lists performance cost, API change and consumer risk.

| ID | Proposal | Fixes | Performance cost | API change | Consumer risk |
|---|---|---|---|---|---|
| **P0** | **Document** in `rc.zig`: single-threaded; `count` is internal and may hold a list link during `JSValue.deinit`; hooks must not inspect or retain other boxes; `setGcHook` overwrites. | 2.5, 2.6 | None | None | None |
| **P1** | **`Rc(T).createWith(allocator, initFn, args)`**: allocate the box first, then `box.value = try @call(.auto, initFn, args)`, with `errdefer allocator.destroy(box)`. The payload is built **in place** (no move). | 2.1 shape (a) | None (one allocation fewer to undo; same count) | **Additive**; `create` stays (needed for "receive ownership" values). | None |
| P1b | `Rc(T).createOwned(allocator, value)`: like `create`, but if the box allocation fails it releases `value` through a comptime-detected `deinit` (`value.deinit()`, or `deinit(allocator)` for `ZPromise`; no-op for pure values). | 2.1 shape (b) | None | Additive | None. Fiddly: four `deinit` shapes in use today (`*Self`, by value, `(allocator)`, none). |
| **P2** | **Always-on underflow check** in `decref`: replace `std.debug.assert(count > 0)` with `if (count == 0) @panic("Rc: release of a box whose count is already 0 (double release)")`. | 2.2, partly: turns *some* ReleaseFast silent corruptions into a deterministic abort | ≈0 [measured: within noise] | None | None. Behavior changes only for programs that already have undefined behavior. |
| **P3** | **Opt-in Debug registry of live boxes** (a build option, off by default). `create` registers the box, `destroy` unregisters it; `retain`/`decref` panic if the box is not registered (catches every release of a freed box, even when the memory was reused). Plus `dumpLive()`, which lists still-live boxes with their variant, for leak hunting beyond `std.testing.allocator`'s raw addresses. | 2.2 (reliably, in Debug), leak diagnosis | **≈10× per box lifetime in Debug** [measured]; zero when off (comptime-gated) | Additive (a build option and a function) | None when off. Needs a global or per-allocator registry, and it is not thread-safe either. |
| **P4** | **Encapsulate `count`**: rename the field to `_count` (or `ref_count_internal`) and add `pub fn refCount(self) usize` for tests and diagnostics. Zig has no private fields; the name is the fence. | 2.5 | None | **Changes a public field name**: 66 test reads in 16 files must switch to `refCount()`. No consumer reads it (0 in z-interpreter, z-json, z-toml, z-yaml, z-run). | Low |
| P5 | **Make `setGcHook` refuse silent overwrites**: `assert(gc_hook == null or (gc_hook == hook and ctx == old_ctx))`. | Robustness audit A6 | None | None (assertion only) | z-interpreter sets the hook once per box in `gcTrack` [inspection]; it is not known whether any path calls `gcTrack` twice on the same box. That needs checking before landing. |
| P6 | **Document the two ownership conventions** (raw payload APIs keep the value on error; wrappers and constructors consume it) in each wrapper's doc comment, next to the raw method it replaces. | 2.3 | None | None | None |
| P7 | **Report to z-interpreter's agent** (not z-value work): add `errdefer v.deinit()` before `try self.gcTrack(v)` in the 20 `gcNew*` wrappers, and release `v` / `copy` in `gcNewArrayBufferFromValue` and its caller on failure. Or have that function call `JSValue.newArrayBuffer`-style code that consumes on failure. | 2.1, outside z-value | None | None | Low (OOM-only paths) |
| — | **Multi-threading: do not do it now.** See §5. | 2.6 | Would be ≈20× per retain/decref [measured] | — | — |

### P1 in detail: `createWith` (proposal, not implemented)

**What it is.** A second constructor on `Rc(T)` that allocates the box first and then builds the payload directly inside it:

```zig
/// Proposal only, not implemented.
pub fn createWith(allocator: Allocator, buildFn: anytype, args: anytype) !*Self {
    const box = try allocator.create(Self);
    errdefer allocator.destroy(box);
    box.* = .{ .count = 1, .allocator = allocator, .value = undefined };
    try @call(.auto, buildFn, .{&box.value} ++ args);
    return box;
}
```

- `buildFn` receives `*T` (the payload slot inside the already-allocated box) followed by `args`, and fills it in. It returns an error union, typically `Allocator.Error!void`.
- `args` is a tuple carrying whatever the payload needs, for example the bytes for a string. Without `args`, the function could not build any of today's payloads, since all of them depend on caller input.
- If `buildFn` fails, the box is freed by the `errdefer`. `buildFn` itself must leave nothing allocated on failure, which is the ordinary Zig rule.

**What it removes.** The window between "payload built" and "box allocated". Today a constructor builds the payload, then calls `create`, and must `errdefer payload.deinit()` in case the box allocation fails. With `createWith`, the box exists before any payload memory is allocated, so there is nothing to undo when the box allocation fails.

**Why not now.** It fixes nothing today. All 25 `Rc.create` sites in z-value are already protected with `errdefer` and covered by out-of-memory tests (§1.3, §2.1). `create` would stay anyway: it is still needed for the "receive ownership, then box" shape (`fromRegex`, `newProxy`, …), where the payload already exists before the call (see P1b).

**When it would make sense.**
- When new constructors with multi-step payloads are added, so each one does not need its own `errdefer`.
- If the goal becomes removing the per-constructor `errdefer` pattern from z-value altogether, or giving embedders such as z-interpreter (`gcNewArrayBufferFromValue`, §2.1) a constructor that cannot leak in that window.

**Cost and risk.** Additive API, no change to existing callers, no runtime cost. The only subtlety is that `buildFn` sees an uninitialized `T` and must fully initialize it.

Suggested order, cheapest and safest first: **P0, P2, P6** (documentation and a free check), then **P1** (additive, removes a whole bug shape for future constructors), then **P3** (opt-in tooling), then **P4/P5** (tiny API or behavior surface, needs a consumer check). P7 belongs to z-interpreter's agent.

---

## 5. What cannot be done without changing the model

- **Reliable underflow/double-release detection in release builds.** A stale `decref` operates on freed, possibly reused memory. Only extra per-allocation state can catch it every time: a registry (P3), generation tags in handles, or quarantining freed boxes. That means a change to `JSValue`'s representation (handles instead of raw pointers) or an always-on registry with the cost measured in §3.
- **Cycle collection inside `Rc`.** Refcounting alone cannot reclaim cycles. A trial-deletion collector (Bacon–Rajan) would need a per-box color/buffered flag, a root buffer, and a traversal of each payload's children: a different memory model. Today the GC hook plus z-interpreter's tracing collector covers this outside `Rc`.
- **Multi-threading.** Atomic counts alone are not enough and cost ≈20× per operation [measured]:
  - the iterative `deinit` reuses `count` as a list link, which is incompatible with concurrent `decref` (it would need a separate link field or a different teardown);
  - the GC hook and every payload library are single-threaded;
  - z-interpreter is single-threaded (fibers, not threads).

  Making values shareable across threads would mean either a separate `Arc`-style box behind a comptime switch with a separate teardown, or keeping values thread-confined and copying across threads. **Recommendation: never inside `Rc` as it is; if needed, design it as a separate type.**
- **True field privacy for `count`.** Zig has no private fields; P4 only makes misuse obvious.
- **Removing the per-box header cost** (40 B: allocator 16 B, hook 16 B, count 8 B). Storing the allocator once per heap, or moving the hook into a side table, would shrink every box but would change `Rc`'s layout and how consumers name the boxes. Not a soundness issue; listed for completeness.

---

## Follow-up notes

- **README.md:46 is inaccurate (fix next time the README is touched).** It says calling `deinit()` twice on the same reference is "Caught by an assertion in Debug/ReleaseSafe". §2.2 measured that this is not guaranteed: with DebugAllocator it segfaults inside `decref`, and with `smp_allocator` the assert fires only if the freed memory happens to read 0. In ReleaseFast it is silent. Kept out of the Rc documentation commit on purpose.
- **P4 rename `count` → `_count` is pending.** `refCount()` was added (additive) and z-value's own tests already read through it. The field is still the public `count`. Correction to §1.2: one consumer does read it, `z-interpreter/tests/refcount_test.zig:21` (`result.value.object.count`); the "0 in consumers" figure only covered consumers' `src/`. z-interpreter builds against `../z-value` by path, so the rename would break that test immediately. Once z-interpreter changes that line to `.refCount()`, the rename is a ~30-second commit in z-value: `src/rc.zig` plus the list link in `src/zvalue.zig:485-493`.
