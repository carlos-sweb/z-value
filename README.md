# Z-Value

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

**Z-Value** is a reference-counted, tagged-union `JSValue` type for the [z-*](https://github.com/carlos-sweb) micro-library ecosystem written in Zig 0.16. It is the piece that connects the independent, statically-typed ECMAScript primitives — [z-array](https://github.com/carlos-sweb/z-array), [z-object](https://github.com/carlos-sweb/z-object), [z-string](https://github.com/carlos-sweb/z-string), [zregex](https://github.com/carlos-sweb/z-regex), [z-symbol](https://github.com/carlos-sweb/z-symbol), [z-map](https://github.com/carlos-sweb/z-map), [z-set](https://github.com/carlos-sweb/z-set), [z-error](https://github.com/carlos-sweb/z-error), [z-date](https://github.com/carlos-sweb/z-date), [z-promise](https://github.com/carlos-sweb/z-promise), [z-bigint](https://github.com/carlos-sweb/z-bigint), [z-buffer](https://github.com/carlos-sweb/z-buffer), [z-temporal](https://github.com/carlos-sweb/z-temporal) — into something that can actually represent a heterogeneous JS value: a variable, an array element, or an object property that can be a number today and a string tomorrow.

[Spanish version (may lag behind this file)](README.es.md)

## Current Status

*As of 2026-10-06, `master` at commit `a509591` (version `0.1.0` in `build.zig.zon`).*

- **21 variants**, all functional: 4 inline (`undefined`, `null`, `boolean`, `number`) and 17 reference-counted (see [Variant support](#variant-support)).
- **Test suite:** 148 tests and 69 build steps, all passing (`zig build test`). The build steps include separate processes that check the panics described below.
- **Fixed since the previous version:** allocation failures no longer leak memory. Every constructor and every `clone*()` helper now releases what it already built when an allocation fails, and constructors that take ownership of their inputs now consume them on failure too (see [Constructors: Ownership Contract](#constructors-ownership-contract)). This closes the long-standing leak in `newString()` and the same defect in 10 other constructors and all 5 clone helpers. 17 new out-of-memory tests cover every allocation point (97 → 114 tests).
- **Changed since commit `2546893`:**
  - `deinit()` and `typeOf()` are iterative: nesting depth costs no native stack.
  - Constructors and `clone*()` helpers given a `JSValue` of the wrong variant abort with a clear panic, in every build mode.
  - Rc-aware mutation wrappers: `objectSet`, `objectDefine`, `objectDelete`, `objectClear`, `mapSet`, `mapDelete`, `mapClear`, `setAdd`, `setDelete`, `setClear`. They release the values they replace or remove, and the ones that store a value consume it, also on error.
  - Releasing a box whose count is already 0 aborts with a panic in every build mode, ReleaseFast included.
  - `setGcHook` aborts if a hook is already installed; `clearGcHook()` removes one.
  - `Rc(T).refCount()` reads the reference count; the field itself is now the internal `_count`.
- **Still pending:** see [Known Limitations](#known-limitations). The largest is the missing property bag for non-plain objects (`Map`, `Set`, `Error`, …).

## Why this exists

`ZArray(T)` and `ZObject(T)` are generic but **monomorphic** — one fixed `T` per instance, like any generic container in a statically typed language. A real JS array (`[1, "a", true]`) is heterogeneous, which `ZArray(T)` alone cannot represent. `JSValue` is the `T` that makes `ZArray(JSValue)` / `ZObject(JSValue)` behave like real JS arrays/objects — this mirrors how V8 and QuickJS internally share one unified value representation (`Tagged<Object>` / `JSValue` respectively) across `Array`, `Object`, `Number`, etc., instead of keeping each type fully independent.

## Design

- **Tagged union, not NaN-boxing**: `undefined`/`null`/`boolean`/`number` are inline (trivially copyable bits, no allocation). Every other variant is heap-owning and lives behind a pointer to a reference-counted box `*Rc(T)`. `@sizeOf(JSValue)` is 16 bytes.
- **Reference counting** (QuickJS-style), not a tracing GC: predictable, no pauses, but does **not** collect reference cycles — see [Known Limitations](#known-limitations).
- **Non-invasive**: the wrapped z-* libraries know nothing about z-value. The `Rc(T)` box in `src/rc.zig` wraps them from the outside; none of those projects had to change their own design for this (z-symbol did gain one small, self-contained addition — see [Variant support](#variant-support) — but nothing z-value-specific leaked into it). Four payload types have no upstream sibling repo and are defined directly in this repo because they only make sense inside a `JSValue` graph: `Callable` (`src/callable.zig`), `Proxy` (`src/proxy.zig`), `DataViewBox` (`src/data_view_box.zig`) and `TypedArrayBox` (`src/typed_array_box.zig`). `TemporalValue` (`src/temporal_value.zig`) groups z-temporal's 8 types under one variant.
- **`JSValue` supports the same generic-equality duck-typing as any other struct/union**: it exposes `eql(a, b) bool` (SameValueZero) and `hash(self) u64`, picked up automatically by [z-equality](https://github.com/carlos-sweb/z-equality)'s generic machinery — this is what lets `ZMap(JSValue, JSValue)`/`ZSet(JSValue)` work at all. See the `===` caveat in [Known Limitations](#known-limitations).

## Ownership Rules

Zig has no copy constructors or destructors, so ownership is a **convention**, not something the compiler enforces. Every heap-backed `JSValue` points to an `Rc` box with a reference count; whoever holds a counted reference is an *owner*.

1. **Copying a `JSValue` does NOT increment the refcount.** `const b = a;` copies the pointer to the same box. `b` is not a new owner.
2. **Call `.retain()` explicitly when a copy must outlive the original binding** — for example, when storing the same value in a second container, or keeping it after handing the original to a function that consumes it. `retain()` returns the value itself, so it chains: `arr.push(v.retain())`.
3. **Call `.deinit()` exactly once per owned or retained reference.** `deinit()` decrements the count and only tears the value down (iteratively releasing any nested `JSValue`s; the observable effect is the same as a recursive release, without using native stack per nesting level) when the count reaches zero.

Inline variants (`undefined`, `null`, `boolean`, `number`) have no box: `retain()` and `deinit()` are no-ops on them, so the same code works for every variant.

### What happens if you get it wrong

| Mistake | Consequence |
|---|---|
| Forgetting a `deinit()` | Memory leak. `std.testing.allocator` reports it at the end of the test. |
| Forgetting a `retain()` before storing a second copy | Two holders share one counted reference: the first `deinit()` frees the value while the other holder still points to it → use-after-free, then a double free. |
| Calling `deinit()` twice on the same reference | Release of a box that was already freed. `Rc` checks for a release at count 0 in every build mode, but that check is reliable only while the box has not been freed: after the first `deinit()` frees it, the second may abort, crash, or silently corrupt another box if the memory was reused. |

### Complete example: create, copy, retain, release

```zig
const name = try JSValue.newString(allocator, "Ada"); // count = 1 (owned by `name`)
const alias = name; // plain copy: same box, count still 1 -- `alias` is NOT an owner

const list = try JSValue.newArray(allocator); // count = 1 (owned by `list`)
_ = try list.array.value.push(name.retain()); // count = 2: the array owns its own reference

std.debug.assert(alias.string == name.string); // reading through a copy is fine while an owner is alive

name.deinit(); // count = 1: our reference is gone; only the array's remains
list.deinit(); // releases the array, which releases its reference: count = 0, string freed
```

### What NOT to do

```zig
// 1. Do NOT call the underlying containers' shallow clone/copy helpers on JSValue
//    contents. They byte-copy elements without retaining them.
var shallow = try arr.array.value.clone(); // WRONG: children now have two holders, one count
const copy = try arr.cloneArray();         // RIGHT: retains every child

// 2. Do NOT deinit the same reference twice.
v.deinit();
v.deinit(); // WRONG: refcount underflow

// 3. Do NOT store a value in a container and then release your only reference
//    without having retained it first.
_ = try arr.array.value.push(child); // the array takes over `child`'s reference...
child.deinit();                      // WRONG: ...and this releases it again
// RIGHT: either push(child.retain()) and keep child.deinit(), or push(child) and drop the deinit.
```

`ZMap`, `ZSet` and `ZError` expose no shallow `clone()` of their own; use `cloneMap()`, `cloneSet()` and `cloneError()` for retain-aware duplication. `ZObject`'s own copy helpers (`assign`, etc.) are shallow: use `cloneObject()`.

## Constructors: Ownership Contract

Every constructor either succeeds and returns a value you own (count = 1), or fails and leaves **nothing behind for you to release**. There are three groups.

### 1. Constructors that build their own payload

`newString`, `newSymbol`, `newError`, `newBigInt`, `newArrayBuffer`, `newSharedArrayBuffer` build the payload (string bytes, description, message, digits, byte storage) and then wrap it in an `Rc` box. If allocating the box fails, the payload is released before the error is returned. No leak.

```zig
const s = try JSValue.newString(allocator, "hello"); // on error: nothing to clean up
defer s.deinit();
```

The constructors whose payload needs no allocation (`newArray`, `newObject`, `newMap`, `newSet`, `newDate`, `newTemporal`, `newPromise`) allocate only the box, so they cannot leak either.

### 2. Constructors that take ownership of their inputs

`newProxy` (`target`, `handler`), `newAggregateError` (`errs`), `fromRegex` (`re`), `newBigIntFromValue` (`v`) and `newFunction` (the `Callable`, including its `prototype`/`statics` if set) take over the references you pass in. They **consume their inputs even when they fail**: after a call returns an error, the inputs have already been released, and **the caller must not release them again**. `newDataView` and `newTypedArray` (`owner`) already followed this contract.

None of these constructors retain their inputs for you. If you still need your own reference afterwards, pass `x.retain()`.

```zig
// Hand over both references. Release only what was never handed over.
const target = try JSValue.newObject(allocator);
const handler = JSValue.newObject(allocator) catch |err| {
    target.deinit(); // still ours: newProxy hasn't been called yet
    return err;
};
const proxy = try JSValue.newProxy(allocator, target, handler); // consumes both, even on error
defer proxy.deinit();

// Keep your own references: retain what you pass in.
const proxy2 = try JSValue.newProxy(allocator, target2.retain(), handler2.retain());
```

```zig
const agg = try JSValue.newAggregateError(allocator, "all failed", &.{ e1, e2 }); // e1, e2 consumed

const re = try zregex.Regex.compile(allocator, "a+b");
const rv = try JSValue.fromRegex(allocator, re); // `re` consumed

const sum = try ZBigInt.add(allocator, a.bigint.value, b.bigint.value);
const big = try JSValue.newBigIntFromValue(allocator, sum); // `sum` consumed

const f = try JSValue.newFunction(allocator, .{ .ctx = &ctx, .name = "f", .call = myCall });

const view = try JSValue.newDataView(allocator, buf.retain(), 0, null); // keep `buf`, hand over a retained copy
const ints = try JSValue.newTypedArray(allocator, buf.retain(), 0, null, .i32);
```

**Pitfall:** do not guard a consumed input with an `errdefer x.deinit()` whose scope includes the consuming call. If that call fails, the input is released twice. Release inputs manually only on the paths that fail *before* handing them over, as in the `newProxy` example above.

### 3. Clones

`cloneArray`, `cloneObject`, `cloneMap`, `cloneSet` and `cloneError` return an independent copy that retains every nested `JSValue`. If an allocation fails partway through, the clone releases everything it had already copied, and the source value is left exactly as it was.

```zig
const copy = try original.cloneArray(); // on error: nothing to release, `original` unchanged
defer copy.deinit();
```

`cloneObject()` copies enumerable own data properties only. It does not copy non-enumerable properties, accessors, property attributes, frozen/sealed state or the prototype.

## Tests with FailingAllocator

Besides the regular functional tests, every constructor and clone helper listed above has an **out-of-memory test**. Each one uses `std.testing.FailingAllocator` to make the 1st, 2nd, 3rd, … allocation of the call fail, one at a time, until the call succeeds. For every forced failure it checks that:

- the call returns `error.OutOfMemory`;
- `allocated_bytes == freed_bytes`, so nothing leaked, including the inputs a consuming constructor took over;
- for clones, the source value can still be released normally afterwards (no child was over- or under-retained).

`std.testing.allocator` additionally aborts the test on any double free. `Rc`'s zero-count check catches an extra release while the box is still allocated; an extra `deinit()` on a box that was already freed is not reliably caught by it.

Run the whole suite (148 tests) with:

```bash
zig build test
```

The sibling repositories listed in [Installation](#installation) must be checked out next to this one (`../z-array`, `../z-object`, …).

## Variant support

| Variant | Status | Notes |
|---|---|---|
| `undefined` / `null` / `boolean` / `number` | ✅ Complete | Inline, no allocation |
| `string` | ✅ Complete | `*Rc(ZString)` from [z-string](https://github.com/carlos-sweb/z-string) — full UTF-16-indexed ECMAScript String semantics. `JSValue.newString()` always constructs an *owned* `ZString` (`initOwned`, never the borrowed-mode `init`), since a borrowed `ZString`'s `deinit()` is a no-op and would silently break the Rc refcounting contract. Compared and hashed by content. |
| `array` | ✅ Complete | `*Rc(ZArray(JSValue))`, recursive release, `cloneArray()` |
| `object` | ✅ Complete | `*Rc(ZObject(JSValue))`, recursive release (including accessor getters/setters), `cloneObject()`. See the prototype limitation below. |
| `regex` | ✅ Complete | `*Rc(Regex)` from zregex, no nested JSValues to recurse into. `fromRegex()`. |
| `symbol` | ✅ Complete | `*Rc(ZSymbol)` from [z-symbol](https://github.com/carlos-sweb/z-symbol). `JSValue.newSymbol()` uses `ZSymbol.init()` (a value, not `create()`'s own heap allocation) so the Rc box is the symbol's one true allocation; z-symbol gained a matching `ZSymbol.deinit()` (frees the description only, not `self`) for this — `destroy()` remains `deinit()` + freeing self, for standalone (non-Rc-boxed) use. `typeOf()` is `"symbol"`, its own distinct result (not `"object"`). |
| `map` | ✅ Complete | `*Rc(ZMap(JSValue, JSValue))` from [z-map](https://github.com/carlos-sweb/z-map). Recursive release of *both* keys and values (unlike `object`, whose keys are plain strings, `Map` keys are arbitrary `JSValue`s too). `cloneMap()`. |
| `set` | ✅ Complete | `*Rc(ZSet(JSValue))` from [z-set](https://github.com/carlos-sweb/z-set). Recursive release of values. `cloneSet()`. |
| `error` | ✅ Complete | `*Rc(ZError(JSValue))` from [z-error](https://github.com/carlos-sweb/z-error). `newError()`/`newAggregateError()`. Recursive release of `AggregateError`'s nested `JSValue`s. `cloneError()`. `typeOf()` is `"object"` (errors are objects in JS: `typeof new TypeError() === "object"`). Compared by box identity, same as `array`/`object`/etc. |
| `function` | ✅ Complete | `*Rc(Callable)` — defined in this repo (`src/callable.zig`), no upstream sibling. `ctx: *anyopaque` + `call: *const fn(...) anyerror!JSValue`, deliberately opaque so this repo stays independent of any parser/interpreter family; the concrete `ctx` type (native function, user closure, ...) is entirely the consumer's choice. Optional `prototype` and `statics` (property bag for the function itself) are owned by the `Callable` and released with it. `newFunction()`. `typeOf()` is `"function"`, its own distinct result (not `"object"`). |
| `date` | ✅ Complete | `*Rc(ZDate)` from [z-date](https://github.com/carlos-sweb/z-date), a pure 8-byte value (a millisecond timestamp) — no nested `JSValue`s to recurse into. `newDate(ms)`. |
| `promise` | ✅ Complete | `*Rc(ZPromise(JSValue))` from [z-promise](https://github.com/carlos-sweb/z-promise) — stores/transitions state only, never invokes callbacks itself (that's the consumer's job, e.g. an interpreter's job queue). `newPromise()`. |
| `bigint` | ✅ Complete | `*Rc(ZBigInt)` from [z-bigint](https://github.com/carlos-sweb/z-bigint), arbitrary-precision integers. `newBigInt(rawDigitText)` (parses) / `newBigIntFromValue(v)`. **Compared and hashed by VALUE, not by Rc box identity** (`1n === 1n` is `true` across two independently-parsed instances) — see [`equality.zig`](src/equality.zig)'s doc comments. |
| `proxy` | ✅ Complete | `*Rc(Proxy)` — defined in this repo (`src/proxy.zig`), no upstream sibling. A `target`/`handler` pair with no data or algorithm of its own; pure trap-dispatch indirection interpreted entirely by whoever reads the fields back out. `newProxy(target, handler)`. `typeOf()` recurses into `target.typeOf()` (a proxy wrapping a callable reports `"function"`), but equality/hashing are by the Proxy's OWN box identity (two proxies over the same target are never `===`). Revocation is not modeled. |
| `array_buffer` | ✅ Complete | `*Rc(ArrayBuffer)` from [z-buffer](https://github.com/carlos-sweb/z-buffer). Fixed-length, zero-initialized byte storage; a leaf for GC purposes (no nested `JSValue`s). `newArrayBuffer(byteLength)`; `newSharedArrayBuffer(byteLength)` uses the same storage with `is_shared` set (same variant). |
| `data_view` | ✅ Complete | `*Rc(DataViewBox)` — defined in this repo (`src/data_view_box.zig`), wrapping a `zbuffer.DataView` (explicit per-call endianness) plus the owning `.array_buffer` `JSValue` it reads/writes through. `owner` is consumed by the constructor (see [Constructors: Ownership Contract](#constructors-ownership-contract)). `newDataView(owner, byteOffset, byteLength)`. |
| `typed_array` | ✅ Complete | `*Rc(TypedArrayBox)` — defined in this repo (`src/typed_array_box.zig`): a byte-offset/element-count window into an owning `.array_buffer` `JSValue`, plus a `TypedKind` tag for the 11 JS-visible element kinds (`i8`/`u8`/`u8_clamped`/`i16`/`u16`/`i32`/`u32`/`f32`/`f64`/`i64`/`u64` — `u8`/`u8_clamped` share the same underlying storage, differing only in write-coercion and JS identity). `TypedKind` deliberately lives HERE rather than in z-buffer: the "clamped" framing is JS-TypedArray-specific, not a general buffer concept. `owner` is consumed by the constructor. `newTypedArray(owner, byteOffset, len, kind)`. |
| `temporal` | ✅ Complete | `*Rc(TemporalValue)` — a union (`src/temporal_value.zig`) over the 8 [z-temporal](https://github.com/carlos-sweb/z-temporal) instance types (`PlainDate`, `PlainTime`, `PlainDateTime`, `PlainYearMonth`, `PlainMonthDay`, `Instant`, `ZonedDateTime`, `Duration`), all pure values with nothing to release. One variant instead of eight keeps every exhaustive `switch` over `JSValue` small. `newTemporal(value)`. Compared by box identity (JS code compares Temporal objects with `.equals()`). |

## Known Limitations

Each item is marked **pending** (known, no fix scheduled yet) or **will be addressed** (planned).

- **Ownership on allocation failure — fixed.** z-value's constructors and clone helpers no longer leak when an allocation fails (see [Current Status](#current-status)). The historical leak in `newString()` is closed. This covers z-value's own functions only: mutating a container in place through the wrapped libraries' raw APIs (for example `ZObject.set()` over an existing key, or `ZMap.set()` with a key that is already present) does not release the value being replaced; the caller must release it, per the [Ownership Rules](#ownership-rules).
- **No property bag for non-plain objects — will be addressed.** This is the largest known limitation. In JavaScript every object can carry its own properties (`m.x = 1` works on a `Map`). In z-value, only `object` (whose payload *is* a property bag) and `function` (via `Callable.statics`) have somewhere to store them. `array`, `map`, `set`, `error`, `regex`, `date`, `promise`, `array_buffer`, `data_view`, `typed_array` and `temporal` have no storage for own properties, so consumers must keep side tables or reject the assignment.
- **`===` behaves as SameValueZero inside generic containers — will be addressed.** `equality.strictEquals()` is correct (`NaN !== NaN`). But `JSValue.eql()` implements SameValueZero (needed for `Map`/`Set` keys), and z-equality uses that same method for *its* generic strict-equality comparisons. As a result, generic container operations that should use `===` use SameValueZero instead. Visible symptom: `ZArray(JSValue).indexOf(NaN)` finds a `NaN` element (in JS, `[NaN].indexOf(NaN)` is `-1`); the same applies to `lastIndexOf`. `includes` (which is specified as SameValueZero) is correct.
- **No classification predicates; consumers can crash on new variants — will be addressed.** z-value offers no `isObjectLike()` / `isPrimitive()` / `isCallable()` helpers, so each consumer hand-maintains its own list of variants. Lists written before a variant existed silently miss it: z-toml and z-yaml currently reach an `unreachable` (a panic in Debug, undefined behavior in ReleaseFast) when stringifying some newer variants (for example a `bigint` in z-toml, or a `Map` in z-yaml). Consumers that `switch` exhaustively (no `else`) are not affected, because the compiler flags new variants.
- **Reference cycles leak — pending.** An array/object that (directly or indirectly) contains a `JSValue` pointing back to itself never reaches refcount zero. There is no cycle collector in z-value; `Rc(T)` exposes an optional GC hook (`setGcHook`) so an embedder can run its own.
- **`ZObject.prototype` is not reference-counted — pending.** It's a raw `?*Self` inherited from z-object with no lifetime management of its own — z-value does not retain or release it. If a prototype object is freed while another object still points to it, that pointer dangles. Fixing this would require z-object to become Rc-aware (or expose a generic retain/release hook).
- **Single-threaded assumed — pending.** The internal refcount `Rc(T)._count` (read it with `refCount()`) is a plain `usize`, not atomic. A multi-threaded consumer would need a separate, atomic box type.
- **Unbalanced `retain()`/`deinit()` is only partly caught — pending.** `Rc.decref()` aborts with a panic on a release at count 0, in every build mode (ReleaseFast included since `0c8525f`). That is reliable only while the box is still allocated: a release of a box that was already freed reads freed memory and may go unnoticed. Always exercise new refcounting code paths under `std.testing.allocator` in a Debug build first.

## Installation

Sibling repos are resolved as local paths in `build.zig.zon` (swap for `zig fetch --save git+...` once tagged releases exist):
```zig
.dependencies = .{
    .zarray = .{ .path = "../z-array" },
    .zobject = .{ .path = "../z-object" },
    .zregex = .{ .path = "../z-regex" },
    .zstring = .{ .path = "../z-string" },
    .zsymbol = .{ .path = "../z-symbol" },
    .zmap = .{ .path = "../z-map" },
    .zset = .{ .path = "../z-set" },
    .zerror = .{ .path = "../z-error" },
    .zdate = .{ .path = "../z-date" },
    .zpromise = .{ .path = "../z-promise" },
    .zbigint = .{ .path = "../z-bigint" },
    .zbuffer = .{ .path = "../z-buffer" },
    .ztemporal = .{ .path = "../z-temporal" },
},
```

Two more repos are needed transitively and must also be checked out next to this one: [z-equality](https://github.com/carlos-sweb/z-equality) (used by z-array and z-map) and [z-number](https://github.com/carlos-sweb/z-number) (used by z-string).

## Project Structure

```
z-value/
├── src/
│   ├── zvalue.zig           # JSValue union, constructors, retain()/deinit(), cloneArray()/cloneObject()/cloneMap()/cloneSet()/cloneError()
│   ├── rc.zig               # Rc(T) generic refcounting box (+ optional GC hook)
│   ├── equality.zig         # strictEquals/sameValueZero/hash/JSValueHashContext
│   ├── errors.zig           # ZValueError
│   ├── callable.zig         # Callable (the `function` variant's payload) -- no upstream sibling repo
│   ├── proxy.zig            # Proxy (the `proxy` variant's payload) -- no upstream sibling repo
│   ├── data_view_box.zig    # DataViewBox (the `data_view` variant's payload)
│   ├── typed_array_box.zig  # TypedArrayBox + TypedKind (the `typed_array` variant's payload)
│   └── temporal_value.zig   # TemporalValue (the `temporal` variant's payload)
├── tests/
│   ├── value_types_test.zig
│   ├── rc_test.zig
│   ├── array_test.zig
│   ├── object_test.zig
│   ├── regex_test.zig
│   ├── symbol_test.zig
│   ├── map_test.zig
│   ├── set_test.zig
│   ├── error_test.zig
│   ├── equality_test.zig
│   ├── callable_test.zig
│   ├── date_test.zig
│   ├── bigint_test.zig
│   ├── proxy_test.zig
│   ├── data_view_box_test.zig
│   ├── typed_array_box_test.zig
│   └── temporal_test.zig
├── build.zig
└── build.zig.zon
```

## Running Tests

```bash
zig build test
```

See [Tests with FailingAllocator](#tests-with-failingallocator) for what the out-of-memory tests guarantee.

## License

MIT
