# z-value robustness audit — z-value as the JS value unifier

*Date: 2026-10-05. Audited revision: z-value `master` at `c8bd276` (ownership fix `2546893` merged in `fa2ddc4`). Read-only: no code, test or repository was changed; this file is not committed.*

**Definition used.** z-value is the type that unifies every JavaScript value into one, so that the z-* containers can hold anything. It must:

1. represent all 21 variants without exception;
2. keep ownership correct on every path (success, error, out-of-memory, cycles);
3. compare and hash every variant correctly;
4. construct and destroy robustly;
5. stay sound even when a backing library is not 100% correct.

**Scope.** This audit covers z-value's robustness as a type. Services z-value could offer consumers (a property bag, classification predicates, `===` inside generic containers) are listed separately in §1.3 and are not evaluated further.

**Evidence conventions.**
- **[measured]**: a test or program was run; the number is its output.
- **[inspection]**: read from source, not executed.
- `file:line` refers to z-value `master` unless another repo is named. Sibling repos were read at these commits: z-string `ee08516`, z-array `9e13105`, z-object `6e9a613`, z-map `13de45a`, z-set `3390e97`, z-error `9376e97`, z-date `852ff28`, z-promise `d7dd80d`, z-bigint `3bff510`, z-buffer `af2196d`, z-symbol `b1f14b8`, z-regex `eb56447`, z-temporal `b13885b`, z-equality `6c70f6c`, z-number `a80dc65`, z-interpreter `0d0e0d4`.

**How the evidence was produced.**
- Zig 0.16.0 was used throughout.
- z-value's own suite: **114/114 tests pass** [measured].
- A separate robustness harness, kept outside every repository, holds 13 in-process tests (13/13 pass) plus 31 crash-candidate scenarios. Each crash scenario runs in its own process so that a crash cannot hide other results.
- 7 end-to-end JavaScript snippets were run through a z-run binary built from z-interpreter.

---

## 1. Consolidation of the previous audit

The previous audit (`docs/plans/ZVALUE_AUDIT.md`, written in Spanish and not committed) confirmed 18 bugs, R01–R18, each with a reproducer. Here is their current status.

### 1.1 Fixed — 12

All of these were fixed in commit `2546893` (merged to `master` in `fa2ddc4`). Each one is now covered by an out-of-memory test that sweeps every allocation point.

| ID | Bug | Status |
|---|---|---|
| R01 | `newString` leaked the string bytes when `Rc.create` failed | Fixed |
| R02 | `newSymbol` leaked the description | Fixed |
| R03 | `newError` leaked the message | Fixed |
| R04 | `newBigInt` leaked the limbs | Fixed |
| R05 | `newArrayBuffer` leaked the bytes (`newSharedArrayBuffer` had the same bug) | Fixed |
| R06 | `newAggregateError` leaked its own copies and the handed-over `errs` | Fixed: inputs are now consumed on failure |
| R07 | `newProxy` leaked the handed-over `target`/`handler` | Fixed: inputs are now consumed on failure |
| R08 | `cloneArray` over-retained children on failure | Fixed |
| R09 | `cloneObject` leaked on a failure mid-copy | Fixed |
| R10 | `cloneMap` leaked on a failure mid-copy | Fixed |
| R11 | `cloneSet` leaked on a failure mid-copy | Fixed |
| R12 | `cloneError` leaked on failure | Fixed |

The same commit also fixed `fromRegex`, `newBigIntFromValue` and `newFunction`, which consume their inputs and now release them on failure too. Those three were not among R01–R18.

### 1.2 z-value robustness — 5 (still open)

| ID | Bug | Status in this audit |
|---|---|---|
| R14 | `cloneObject` is not a faithful clone: it drops non-enumerable properties, accessors, flags and the prototype (4 of 4 attributes) | Open → **A4** |
| R15 | `ZObject.set` over an accessor drops the getter/setter without releasing them | Open → **C1** |
| R16 | `ZObject.set` over an existing key drops the old value without releasing it | Open → **C1** |
| R17 | `ZMap.set` with a key equal to an existing one leaks the new key and the old value | Open → **C1** |
| R18 | `ZSet.add` of a value already present leaks the new value | Open → **C1** |

### 1.3 Consumer services — out of scope here (1 bug + 2 design items)

| ID | Item |
|---|---|
| R13 | `===` acts as SameValueZero inside generic containers: `ZArray(JSValue).indexOf(NaN)` finds `NaN` (in JS, `[NaN].indexOf(NaN)` is `-1`) [measured, both directly and end-to-end in z-run]. The root cause is the z-value ↔ z-equality hook contract: one `eql` method serves both `strictEquals` and `sameValueZero`. `equality.strictEquals()` itself is correct (re-verified in T5 below). |
| — | No property bag: 8 of the 11 object kinds tested reject `x.p = v` in z-interpreter. |
| — | No classification predicates: z-toml and z-yaml hit `unreachable` on some newer variants. |

Smaller items from the previous audit that are still open are folded into this audit's numbering:
- the `owner` tag that is never checked → **A3**;
- `setGcHook` overwriting silently → **A6**;
- outdated documentation → **A7**;
- `ZObject.prototype` not being reference-counted → **C3**.

**Result:** 12 fixed, 5 z-value robustness, 1 consumer service.

---

## 2. Per-variant audit

Columns:
- **Backing**: the library that backs the variant.
- **Contract z-value relies on**: the functions and fields z-value actually calls or reads.
- **Verified?**: whether z-value checks that contract or relies on it unchecked.
- **Where an abnormal answer breaks z-value**: the paths where a misbehaving library breaks z-value.

| Variant | Backing | Contract z-value relies on | Verified? | Where an abnormal answer breaks z-value |
|---|---|---|---|---|
| `undefined`, `null`, `boolean`, `number` | inline | `number` is compared and hashed through z-array's re-export of z-equality: `NaN !== NaN`, `+0 === -0`, NaN payloads and ±0 hash identically. | Verified by T5 (2 NaN payloads, ±0) [measured] | None found |
| `string` | z-string | `ZString.initOwned` (one `dupe`), `deinit`, and the `.data` bytes, which equality and hashing compare | Unverified: `initOwned` does not validate UTF-8 | None in z-value. Invalid UTF-8 compares and hashes consistently and clones cleanly (L1) [measured]. z-string's own methods do not crash on it but return unspecified results (`length()` = 7 for a 9-byte invalid string) [measured] → **C5** |
| `array` | z-array | `init`, `clone` (shallow), `toSliceMut`, `push`, `deinit` (frees storage, never releases `T`) | Unverified; behaves as relied upon [measured, T4/T6] | Recursive teardown overflows the stack at depth ≈12.5k (Debug) → **A1** |
| `object` | z-object | `init`, `set`, `get`, `keys`, `properties` (value + getter/setter), `deinit` (frees keys only) | Unverified | `set`/`defineAccessor` over existing slots drop values unreleased → **C1**. Error paths do not say who owns the value → **C2**. Raw `prototype` pointer can dangle → **C3**. Clone is not faithful → **A4**. Deep teardown → **A1** |
| `map` | z-map (+ z-equality via `JSValue.eql`/`hash`) | `init`, `set`, `keys`, `values`, `entries`, `deinit`. Key comparison goes through `JSValue.eql` (SameValueZero) and `JSValue.hash`. | Hash/eql consistency verified over 54 samples (T5) [measured] | Duplicate-key `set` keeps the old key and silently drops the new key and the old value → **C1**. Deep teardown → **A1** |
| `set` | z-set (wraps z-map) | `init`, `add`, `values`, `deinit` | Same as `map` | Duplicate `add` drops the new value → **C1**. Deep teardown → **A1** |
| `error` | z-error | `init`, `initAggregate` (copies the slice, not the elements), `errors`, `message`, `kind`, `deinit` | Unverified; behaves as relied upon [measured, T6] | Deep AggregateError chains → **A1** |
| `date` | z-date | `ZDate.fromTimestamp` (pure 8-byte value; out-of-range input becomes INVALID_TIME) | `maxInt(i64)`/`minInt(i64)` produce no crash (L5) [measured] | None found |
| `promise` | z-promise | `init`, `deinit(allocator)` (frees the reaction list only), `result`, `reactions`, `settle`, `subscribe` | Unverified | `settle` under OOM returns an error after it has already committed the state and the value → **B2**. Settling an already-settled promise, or subscribing to one, drops the value or reaction without stating ownership → **C2**. Deep result chains → **A1** |
| `bigint` | z-bigint | `fromDigitText`, `deinit`, `eql`, `hash` | eql/hash consistency verified across 9 construction routes: `0`, `-0`, `x-x`, `-(x-x)`, `1`, `0x1`, `2^64-(2^64-1)`, `2^64` in decimal and hex, and `1<<64` (T5) [measured] | Text parsing accepts invalid input: `"--1"` → `1n`, `"_"` → `0n` → **B3**. Separator grammar is not specified → **C4** |
| `array_buffer` | z-buffer | `ArrayBuffer.init`, `deinit`, `is_shared` | A `maxInt/2` size returns `OutOfMemory` with no crash (L5) [measured] | None found |
| `data_view` | z-buffer + native `DataViewBox` | `DataView.init(&buffer, offset, len)`, which validates bounds; owner kept alive by refcount | Bounds delegated to z-buffer, unverified. The `owner` tag is not checked. | `DataView.init` overflows on `offset + len` → **B1**. A non-`array_buffer` owner → **A3** |
| `typed_array` | z-buffer + native `TypedArrayBox` | `TypedArrayView(T).init`, used only to validate and resolve the length | Out-of-bounds, misaligned and `maxInt` length all return errors (L5) [measured] | A non-`array_buffer` owner → **A3** |
| `symbol` | z-symbol | `ZSymbol.init` (copies the description), `deinit` | Unverified; behaves as relied upon | None found |
| `regex` | z-regex | A `Regex` value moved into the box (must be relocatable); `deinit` takes it by value | Relocation verified: the boxed copy still matches (L3) [measured] | Two different z-regex versions are compiled into the build → **C6** |
| `temporal` | z-temporal | Pure values: no allocator, no slices (`ZonedDateTime` keeps its zone in an inline buffer) | By inspection, every type is relocatable with nothing to free | None found |
| `function` | native (`Callable`) | `prototype`/`statics` owned and released by `Callable.deinit` | Verified (T6, consumed on failure) [measured] | The doc comment contradicts the code → **A7**. Deep prototype chains → **A1** |
| `proxy` | native (`Proxy`) | `target`/`handler` owned and released | Verified (T6) [measured] | `typeOf` recurses through the target: a chain of 10⁶ crashes, a self-target recurses forever → **A2**. Deep chains → **A1** |

**Requirement 1 (all 21 variants):** met. The test samples cover 21/21 variants, and every variant constructs, compares, hashes, nests, clones (where applicable) and releases correctly [measured, T5/T6].

---

## 3. Weaknesses by origin

There are 16 weaknesses in total: **A = 7** (z-value), **B = 3** (libraries: 1 each in z-buffer, z-promise and z-bigint), **C = 6** (unwritten contracts).

Severity scale: **High** = crash or undefined behavior reachable with valid inputs. **Medium** = leak or wrong result on a reachable path. **Low** = hard to reach, or documentation only.

### A. z-value weaknesses (fix in z-value)

**A1 — Recursive `deinit` overflows the stack on deep nesting. Severity: High.**
- `JSValue.deinit` (`zvalue.zig:417`) releases children by calling itself: arrays at `:434`, and similarly for every other container.
- Every nesting container crashes once the depth passes the stack. On an 8 MiB stack [measured]:
  - Debug: depth 12 109 works, depth 12 812 crashes (segfault inside `deinit`). The same threshold was measured for `array`, `object` and `map`; `set`, `error`, `promise`, `proxy` and `function` were all fine at 10 000 and crashed at 100 000.
  - ReleaseFast (`array`): depth 40 429 works, depth 41 171 crashes.
- Nested arrays like these are legal in JavaScript (`a = [a]` in a loop).
- z-interpreter is **not** affected. Its GC frees nodes one by one, so dropping a 100 000-deep array in z-run exits cleanly [measured]. Every direct z-value user (z-json, z-toml, z-yaml, embedders) is exposed. For example, parsing deeply nested JSON and then releasing it would crash; this was not run.

**A2 — `typeOf` recurses through proxy targets. Severity: Low.**
- `zvalue.zig:326`.
- Chain lengths [measured]: 10 000 and 100 000 work; 1 000 000 crashes (Debug).
- A proxy whose target is itself recurses until the stack overflows [measured]. That shape cannot be created from JavaScript, because a proxy's target is fixed when it is created; it needs the `target` field to be mutated directly.
- z-run handles a chain of 100 000 [measured].

**A3 — `newDataView`/`newTypedArray` never check the owner's tag. Severity: Medium.**
- `zvalue.zig:274` and `:291` read `owner.array_buffer` directly.
- Passing a non-`array_buffer` owner panics on an inactive union field in Debug and is undefined behavior in ReleaseFast. The doc comment says "asserts", but there is no assert.

**A4 — `cloneObject` is not a faithful clone (R14). Severity: Medium.**
- `zvalue.zig:581`. It copies only enumerable data values: accessors, non-enumerable properties, attributes, frozen/sealed state and the prototype are lost.
- Since `c8bd276` the README states this. The function's own doc comment still does not.

**A5 — Reference cycles leak. Severity: Medium; known, by design.**
- Leak per cycle [measured, T2]:

| Cycle | Bytes leaked |
|---|---:|
| array contains itself | 224 |
| object contains itself | 348 |
| map uses itself as key | 384 |
| map contains itself as value | 384 |
| set contains itself | 240 |
| promise resolved with itself | 96 |
| function ↔ `prototype.constructor` | 491 |
| two arrays referencing each other | 448 |
| cycle broken by hand before release | 0 |

- No cycle crashed or looped forever. Equality and hashing are by identity, so they never traverse a cycle.
- `setGcHook` lets an embedder run its own collector; z-interpreter does so.

**A6 — `Rc` safety depends on the build mode. Severity: Low.**
- `rc.zig:62`: the underflow assertion disappears in ReleaseFast.
- `setGcHook` silently overwrites an existing hook.

**A7 — Internal documentation contradicts the code. Severity: Low.**
- `callable.zig:20-24` and `:33` say `prototype`/`statics` are "never released here", but `Callable.deinit` releases them, and since `2546893` `newFunction` also consumes them on failure.
- `zvalue.zig:48-50` and `rc.zig:4-7` still describe a 4-variant union.
- `zvalue.zig:331-337` claims Map/Set is the only user of `eql` (see R13).

### B. Library weaknesses (report to the library's agent)

**B1 — z-buffer: integer overflow in `DataView.init`. Severity: High in ReleaseFast.**
- `z-buffer/src/data_view.zig:31` computes `byte_offset + len > avail` without overflow protection.
- `newDataView(buf16, 1, maxInt(usize))` [measured]:
  - Debug: **panics with "integer overflow"**.
  - ReleaseFast: the sum wraps and the check passes, so it **returns a view** whose `byte_length` is `maxInt(usize)` on a 16-byte buffer, an out-of-bounds window.
- `DataView.window` (`:36`) uses the same `offset + n` pattern [inspection].
- Not reachable from JavaScript through z-interpreter, which validates first and throws `RangeError` [measured]. Reachable through z-value's public API.

**B2 — z-promise: `settle` is not atomic under OOM. Severity: Medium.**
- `z-promise/src/zpromise.zig:72-75` sets `state` and `result` and only then calls `reactions.toOwnedSlice`, which can fail.
- Under OOM [measured, L4]: `settle` returns `OutOfMemory`, **but the state is already `fulfilled`, the value is already stored, and both pending reactions are stranded** in the list (never delivered, released only at teardown).
- A caller that treats the error as "value not consumed" and releases it causes a double free when the promise is torn down.

**B3 — z-bigint: digit-text parsing accepts invalid input. Severity: Medium.**
- `fromDigitText` (`z-bigint/src/zbigint.zig:51-87`) strips one sign and then hands the rest to `setString`, which accepts a second sign and accepts digit runs made only of separators [measured, L2]:
  - `"--1"` → `1n`
  - `"_"` → `0n`
  - `"+-1"` gives `-1n` by the same mechanism [inspection].
- Reachable from JavaScript: in z-run, `BigInt("--1")` returns `1n` and `BigInt("_")` returns `0n`; both must throw `SyntaxError` [measured].
- The path goes through z-interpreter's coercion straight to z-bigint, but `JSValue.newBigInt` forwards the same text to the same function.
- 21 edge inputs were tested. Everything else behaves (errors or correct values), including 100 000-digit literals.

### C. Contract weaknesses (document and decide)

**C1 — Who releases a `T` that a container replaces? (R15–R18)**
- z-array, z-map, z-set, z-object, z-error and z-promise store `T` by value and never release it. That much is documented in each library.
- What happens on **replacement** is not documented for reference-counted `T`:
  - `ZObject.set` over an existing key or accessor (`zobject.zig:123-125`);
  - `ZObject.defineAccessor` over existing slots;
  - `ZMap.set` with a key that is already present (keeps the old key);
  - `ZSet.add` of a value already present.
- In each case a value is silently dropped, so the caller has to know to release it beforehand.
- z-value exposes these payloads directly and has no Rc-aware wrappers.

**C2 — Who owns a value when a library call refuses or fails?**
- These calls do not store the value and do not say the caller keeps it:
  - `ZObject.set` errors (`ObjectIsFrozen`, `PropertyNotWritable`, `ObjectNotExtensible`, `OutOfMemory`);
  - `ZMap.set` and `ZSet.add` on OOM;
  - `ZPromise.settle` on an already-settled promise (value not stored [measured, L4]);
  - `ZPromise.subscribe` on a settled promise (reaction not stored).
- z-value's README says nothing about any of them.

**C3 — `ZObject.prototype` is a raw `?*Self` with no lifetime.**
- z-value cannot retain it, so a freed prototype leaves a dangling pointer. This is documented as a known limitation and is unchanged.

**C4 — z-bigint's digit-text grammar is not specified against JavaScript's.**
- `_` is accepted anywhere (`"1__2"`, `"_1"`, `"1_"`, `"0x_1"` all parse) [measured].
- JavaScript forbids leading, trailing, doubled or post-prefix separators in literals, and forbids all separators in `BigInt(string)`.
- z-value's `newBigInt` doc says it takes the "exact raw digit text a BigInt literal hands in", which implies someone validated the text first, but nobody says who.

**C5 — Is valid UTF-8 a precondition of `ZString`?**
- `initOwned` copies any bytes. z-value's own operations are byte-exact and stay sound.
- z-string's methods do not crash but return unspecified results [measured].
- Neither side states a precondition.

**C6 — Two copies of z-regex in the build graph.**
- z-value depends on `../z-regex` (currently `eb56447`). z-string pins z-regex `85afd1f` by URL and hash (`z-string/build.zig.zon:35-37`).
- Every build compiles both, as two distinct modules (visible in the compiler command line as `zregex` and `zregex0`). That gives two incompatible `Regex` types and a larger binary.
- Not a runtime fault today, because no API passes a `Regex` between them.

---

## 4. Robustness test results

All in-process tests use `std.testing.allocator`, which aborts the test on any leak or double free.

| # | Test | Result |
|---|---|---|
| 1 | **Deep nesting, in-process:** depth 100 and 1 000 for 8 nesting containers (array, object, map value, set, AggregateError, promise result, proxy target, function prototype); build, `typeOf`, `hash`, `deinit` | Pass, no leak [measured] |
| 1 | **Deep nesting, separate processes:** depth 10⁴ / 10⁵ / 10⁶ for the same 8 containers | Every container: 10⁴ works; 10⁵ and 10⁶ crash in `deinit` (Debug). Exact threshold ≈12.5k (Debug) and ≈41k (ReleaseFast) → **A1** [measured] |
| 1 | `typeOf` on proxy chains of 10⁴ / 10⁵ / 10⁶ | Works / works / crashes → **A2** [measured] |
| 2 | **Cycles:** 9 shapes (table in A5) | No crash, no infinite loop. Each leaks 96–491 bytes; breaking the cycle by hand leaks 0 [measured] |
| 3 | **OOM on every path:** a nested structure with 188 allocation points; each point failed in turn | 188 forced failures, every one returns `OutOfMemory`, 0 bytes leaked [measured] |
| 3 | `deinit` with every allocation forced to fail | Teardown allocates nothing, so OOM cannot break it [measured] |
| 3 | Constructors and clones under OOM | Covered by z-value's own 17 out-of-memory tests (all pass) |
| 4 | **Combinations:** array of maps of arrays of AggregateErrors holding typed arrays and bigints; clone at every level; release | Pass, no leak, identity preserved (`v === v`, `v !== clone`) [measured] |
| 5 | **Equality and hashing, every combination:** 54 samples covering 21/21 variants (including two NaN payloads, ±0, invalid UTF-8, and bigints built 9 different ways); 2 916 ordered pairs; checks `sameValueZero` and `strictEquals` against an ECMAScript oracle, symmetry, hash consistency, and agreement between `JSValue.eql`/`hash` and `equality.zig`; then a Map keyed by all 54 samples | **0 mismatches**; Map size 44 = 44 SameValueZero classes [measured] |
| 6 | **`deinit` of every container with every content:** 54 samples × 16 slots = **864 combinations** (array element, object value, accessor getter and setter, map key, map value, set element, AggregateError element, promise result, promise reaction slots, proxy target and handler, function prototype and statics, and every `clone*`) | No leak, no double free, no underflow [measured] |
| L1–L5 | **Library edges:** invalid UTF-8; 21 bigint texts plus a 100 000-digit literal; regex relocated into its box; promise double settle and settle under OOM; extreme sizes and timestamps | Findings B2, B3, C2, C4 and C5; everything else sound [measured] |

---

## 5. Recommendations

### 5.1 Fix in z-value (in priority order)

1. **A1 — Make `deinit` iterative.** When a box's count reaches zero, push its children onto an explicit worklist instead of recursing. This removes the depth limit for every container at once.
2. **A3 — Check the owner tag** in `newDataView`/`newTypedArray`. Either return an error (for example `error.NotAnArrayBuffer`, which changes the error set) or add an explicit `std.debug.assert` and document it as a precondition.
3. **C1 and C2 mitigation — Add Rc-aware mutators.** For example: `objectSetOwned` (releases the replaced value and accessor), `mapSetOwned` (releases the duplicate key and the old value), `setAddOwned` (releases the duplicate). Document that the raw payload APIs follow the library contracts in C1 and C2.
4. **A2 — Make `typeOf` a loop** over proxy targets, with a bound or a cycle check.
5. **A4 — Decide what `cloneObject` is.** Either document it as "enumerable data properties only" in its doc comment, or add a full clone that also copies accessors, attributes, flags and prototype.
6. **A7 / A6 — Documentation and `Rc`.** Fix the stale doc comments. Make `setGcHook` refuse, or at least assert, when a hook is already set.
7. **A5 — Cycles.** No change needed; keep them documented, and keep the GC hook as the supported route.

### 5.2 Report to each library's agent

| Library | Report |
|---|---|
| **z-buffer** | **B1:** `DataView.init` (`data_view.zig:31`) and `DataView.window` (`:36`) add `offset + len` without overflow checking. Use `len > avail - offset` (after `offset <= avail`) or checked arithmetic. Repro: `DataView.init(&buf16, 1, maxInt(usize))` panics in Debug and returns an out-of-bounds view in ReleaseFast. |
| **z-promise** | **B2:** make `settle` atomic. Allocate the returned slice before changing `state`/`result`, or roll back on failure. Repro: two pending reactions, OOM during `settle` → error returned, but state is `fulfilled`, the value is stored and the reactions are stranded. **C2:** document that `settle` on a settled promise and `subscribe` on a settled promise do not take ownership of the value or reaction. |
| **z-bigint** | **B3:** reject a second sign and separator-only digit runs. Repro: `fromDigitText("--1")` = 1, `fromDigitText("_")` = 0, `fromDigitText("+-1")` = -1 [inspection]; `BigInt("--1")` and `BigInt("_")` in z-run. **C4:** specify the separator grammar (JS literal rules vs. permissive), or provide a strict mode for `BigInt(string)`. |
| **z-object** | **C1:** `set` and `defineAccessor` overwrite `value`/`getter`/`setter` without handing back what they replaced. Return the previous entry, or document that the caller must read and release it first. **C2:** document that on every error return the value was not stored. **C3:** the `prototype` lifetime is unmanaged; consider a retain/release hook. |
| **z-map** | **C1:** `set` with a key that is already present keeps the old key and silently drops the new key and the old value. Expose a "put and return previous entry" variant, or document the behavior. **C2:** document that on `OutOfMemory` neither key nor value was stored. |
| **z-set** | **C1:** `add` of a value already present drops the new value. Return whether it was inserted, or document. **C2:** same as z-map. |
| **z-string** | **C5:** state whether valid UTF-8 is a precondition of `init`/`initOwned`, or validate. **C6:** the pinned z-regex (`85afd1f`) differs from the one z-value uses (`../z-regex`); align them. |
| **z-regex** | **C6:** coordinate with z-string so only one version is in the build graph. |
| **z-equality** | Consumer-services item R13, for completeness: a single `eql` hook serves both `strictEquals` and `sameValueZero` for types that define it. Needs a separate strict hook, or a documented rule. |
| z-array, z-error, z-date, z-symbol, z-temporal | Nothing to report. They behave as z-value relies on them to [measured / inspection]. |

### 5.3 Contracts to write down (in z-value's documentation)

1. **Payload requirements:** every payload is moved by value into its `Rc` box, so it must be relocatable (no self-pointers); its `deinit` must not release nested `T`s, because z-value does that.
2. **Replacement and error ownership,** for each container API z-value exposes (C1, C2): who releases what on overwrite, on a duplicate key, on refusal and on OOM.
3. **Input preconditions:** UTF-8 for strings (C5), the digit-text grammar for `newBigInt` (C4), the owner tag for views (A3).
4. **Equality hook:** `JSValue.eql` is SameValueZero by design; what generic containers may assume (R13).
5. **Depth limits:** until A1 is fixed, the maximum nesting depth that is safe to release (≈12k in Debug on an 8 MiB stack).

---

## 6. What could not be determined without a prototype or more information

- **Real exposure of A1 in each consumer.** z-interpreter is safe [measured]. z-json, z-toml and z-yaml were not tested with deep documents; whether their parsers already limit depth before z-value's teardown runs was not checked.
- **Stack thresholds elsewhere.** These were measured on an 8 MiB main-thread stack only. Threads and fibers with smaller stacks, and ReleaseSafe or ReleaseSmall builds, will differ.
- **Cost of an iterative `deinit` (A1).** It needs a worklist allocation, or reuse of child storage, during teardown, while today teardown allocates nothing (T3b). Whether the fix can stay allocation-free needs a prototype.
- **Whether `DataViewBox`'s cached view stays valid** if z-buffer ever adds detach or resize. Not applicable today, because buffers are fixed-length.
- **Whether `cloneObject`'s narrow semantics are intended** (A4). That is a decision, not a measurement.
- **Whether z-interpreter's `BigInt(string)` path** should validate before calling z-bigint (B3/C4). That depends on how the two agents split responsibility.
