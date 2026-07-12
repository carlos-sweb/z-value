# Z-Value

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Z-Value** is a reference-counted, tagged-union `JSValue` type for the [z-*](https://github.com/carlos-sweb) micro-library ecosystem written in Zig 0.16. It is the piece that connects the independent, statically-typed ECMAScript primitives — [z-array](https://github.com/carlos-sweb/z-array), [z-object](https://github.com/carlos-sweb/z-object), [z-string](https://github.com/carlos-sweb/z-string), [zregexp](https://github.com/carlos-sweb/zregexp), [z-symbol](https://github.com/carlos-sweb/z-symbol), [z-map](https://github.com/carlos-sweb/z-map), [z-set](https://github.com/carlos-sweb/z-set) — into something that can actually represent a heterogeneous JS value: a variable, an array element, or an object property that can be a number today and a string tomorrow.

[🇪🇸 Versión en Español](README.es.md)

## Why this exists

`ZArray(T)` and `ZObject(T)` are generic but **monomorphic** — one fixed `T` per instance, like any generic container in a statically typed language. A real JS array (`[1, "a", true]`) is heterogeneous, which `ZArray(T)` alone cannot represent. `JSValue` is the `T` that makes `ZArray(JSValue)` / `ZObject(JSValue)` behave like real JS arrays/objects — this mirrors how V8 and QuickJS internally share one unified value representation (`Tagged<Object>` / `JSValue` respectively) across `Array`, `Object`, `Number`, etc., instead of keeping each type fully independent.

## Design

- **Tagged union, not NaN-boxing**: `undefined`/`null`/`boolean`/`number` are inline (trivially copyable bits); `string`/`array`/`object`/`regex`/`symbol`/`map`/`set` are heap-owning and live behind a pointer to a reference-counted box.
- **Reference counting** (QuickJS-style), not a tracing GC: predictable, no pauses, but does **not** collect reference cycles — see [Known Limitations](#known-limitations).
- **Non-invasive**: z-array/z-object/z-string/zregexp/z-symbol/z-map/z-set know nothing about z-value. The `Rc(T)` box in `src/rc.zig` wraps them from the outside; none of those projects had to change their own design for this (z-symbol did gain one small, self-contained addition — see [Variant support](#variant-support) — but nothing z-value-specific leaked into it).
- **`JSValue` supports the same generic-equality duck-typing as any other struct/union**: it exposes `eql(a, b) bool` (SameValueZero) and `hash(self) u64`, picked up automatically by [z-equality](https://github.com/carlos-sweb/z-equality)'s generic machinery — this is what lets `ZMap(JSValue, JSValue)`/`ZSet(JSValue)` work at all. (z-equality gained generic tagged-union support for this; see its own README.)

## Ownership Rules

Zig has no copy constructors or destructors, so this is a **convention**, not something the compiler enforces:

- Copying a `JSValue` by assignment does **not** touch the refcount.
- Call `.retain()` explicitly whenever a copy needs to outlive the original binding (e.g. storing the same value into two containers).
- Call `.deinit()` exactly once per retained/owned reference. `deinit()` decrements the refcount and only tears down the underlying value when it reaches zero — the same `defer value.deinit()` habit already used across the z-* family, just now meaning "release *my* reference."
- **Never call `ZArray(JSValue).clone()` or `ZObject(JSValue)`'s property-copy helpers directly.** Both are shallow byte-copies that do not retain their elements, so two "clones" would end up sharing boxes with an under-incremented refcount → double-free or premature release. Use `JSValue.cloneArray()` / `JSValue.cloneObject()` / `JSValue.cloneMap()` / `JSValue.cloneSet()` instead, which retain every child correctly. (`ZMap`/`ZSet` don't currently expose their own shallow `clone()`, so there's no equivalent landmine to avoid there today — the `cloneMap()`/`cloneSet()` helpers exist purely for API symmetry and because you'll need retain-aware duplication either way.)

```zig
var arr = try JSValue.newArray(allocator);
const child = try JSValue.newString(allocator, "shared");
try arr.array.value.items.append(allocator, child.retain()); // retain: arr now shares ownership
child.deinit();  // release the original binding's reference
arr.deinit();    // releases arr's own reference to child, recursively
```

## Variant support

| Variant | Status | Notes |
|---|---|---|
| `undefined` / `null` / `boolean` / `number` | ✅ Complete | Inline, no allocation |
| `string` | ✅ Complete | `*Rc(ZString)` from [z-string](https://github.com/carlos-sweb/z-string) — full UTF-16-indexed ECMAScript String semantics. `JSValue.newString()` always constructs an *owned* `ZString` (`initOwned`, never the borrowed-mode `init`), since a borrowed `ZString`'s `deinit()` is a no-op and would silently break the Rc refcounting contract. |
| `array` | ✅ Complete | `*Rc(ZArray(JSValue))`, recursive release, `cloneArray()` |
| `object` | ✅ Complete | `*Rc(ZObject(JSValue))`, recursive release, `cloneObject()`. See prototype gap below. |
| `regex` | ✅ Complete | `*Rc(Regex)` from zregexp, no nested JSValues to recurse into |
| `symbol` | ✅ Complete | `*Rc(ZSymbol)` from [z-symbol](https://github.com/carlos-sweb/z-symbol). `JSValue.newSymbol()` uses `ZSymbol.init()` (a value, not `create()`'s own heap allocation) so the Rc box is the symbol's one true allocation; z-symbol gained a matching `ZSymbol.deinit()` (frees the description only, not `self`) for this — `destroy()` remains `deinit()` + freeing self, for standalone (non-Rc-boxed) use. `typeOf()` is `"symbol"`, its own distinct result (not `"object"`). |
| `map` | ✅ Complete | `*Rc(ZMap(JSValue, JSValue))` from [z-map](https://github.com/carlos-sweb/z-map). Recursive release of *both* keys and values (unlike `object`, whose keys are plain strings, `Map` keys are arbitrary `JSValue`s too). `cloneMap()`. |
| `set` | ✅ Complete | `*Rc(ZSet(JSValue))` from [z-set](https://github.com/carlos-sweb/z-set). Recursive release of values. `cloneSet()`. |

## Known Limitations

- **`ZObject.prototype` is not reference-counted.** It's a raw `?*Self` inherited from z-object with no lifetime management of its own — z-value does not retain or release it. If a prototype object is freed while another object still points to it, that pointer dangles. Fixing this would require z-object to become Rc-aware (or expose a generic retain/release hook); out of scope here.
- **Reference cycles leak.** An array/object that (directly or indirectly) contains a `JSValue` pointing back to itself never reaches refcount zero. There is no cycle collector in this version — breaking cycles is the caller's responsibility.
- **Single-threaded assumed.** `Rc(T).count` is a plain `usize`, not atomic. A multi-threaded consumer would need atomics here.
- **Unbalanced `retain()`/`deinit()` is only caught in Debug/ReleaseSafe.** `Rc.decref()` asserts the count never underflows; in `ReleaseFast` that assert compiles out and the underflow is undefined behavior. Always exercise new refcounting code paths under `std.testing.allocator` in a Debug build first.

## Installation

Sibling repos are resolved as local paths in `build.zig.zon` (swap for `zig fetch --save git+...` once tagged releases exist):
```zig
.dependencies = .{
    .zarray = .{ .path = "../z-array" },
    .zobject = .{ .path = "../z-object" },
    .zregexp = .{ .path = "../zregexp" },
    .zstring = .{ .path = "../z-string" },
    .zsymbol = .{ .path = "../z-symbol" },
    .zmap = .{ .path = "../z-map" },
    .zset = .{ .path = "../z-set" },
},
```

## Project Structure

```
z-value/
├── src/
│   ├── zvalue.zig      # JSValue union, constructors, retain()/deinit(), cloneArray()/cloneObject()/cloneMap()/cloneSet()
│   ├── rc.zig            # Rc(T) generic refcounting box
│   ├── equality.zig      # strictEquals/sameValueZero/hash/JSValueHashContext
│   └── errors.zig
├── tests/
│   ├── value_types_test.zig
│   ├── rc_test.zig
│   ├── array_test.zig
│   ├── object_test.zig
│   ├── regex_test.zig
│   ├── symbol_test.zig
│   ├── map_test.zig
│   ├── set_test.zig
│   └── equality_test.zig
├── build.zig
└── build.zig.zon
```

## Running Tests

```bash
zig build test
```

## License

MIT
