# Z-Value

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Z-Value** is a reference-counted, tagged-union `JSValue` type for the [z-*](https://github.com/carlos-sweb) micro-library ecosystem written in Zig 0.16. It is the piece that connects the independent, statically-typed ECMAScript primitives — [z-array](https://github.com/carlos-sweb/z-array), [z-object](https://github.com/carlos-sweb/z-object), [zregexp](https://github.com/carlos-sweb/zregexp) — into something that can actually represent a heterogeneous JS value: a variable, an array element, or an object property that can be a number today and a string tomorrow.

[🇪🇸 Versión en Español](README.es.md)

## Why this exists

`ZArray(T)` and `ZObject(T)` are generic but **monomorphic** — one fixed `T` per instance, like any generic container in a statically typed language. A real JS array (`[1, "a", true]`) is heterogeneous, which `ZArray(T)` alone cannot represent. `JSValue` is the `T` that makes `ZArray(JSValue)` / `ZObject(JSValue)` behave like real JS arrays/objects — this mirrors how V8 and QuickJS internally share one unified value representation (`Tagged<Object>` / `JSValue` respectively) across `Array`, `Object`, `Number`, etc., instead of keeping each type fully independent.

## Design

- **Tagged union, not NaN-boxing**: `undefined`/`null`/`boolean`/`number` are inline (trivially copyable bits); `string`/`array`/`object`/`regex` are heap-owning and live behind a pointer to a reference-counted box.
- **Reference counting** (QuickJS-style), not a tracing GC: predictable, no pauses, but does **not** collect reference cycles — see [Known Limitations](#known-limitations).
- **Non-invasive**: z-array/z-object/zregexp know nothing about z-value. The `Rc(T)` box in `src/rc.zig` wraps them from the outside; none of those projects had to change.

## Ownership Rules

Zig has no copy constructors or destructors, so this is a **convention**, not something the compiler enforces:

- Copying a `JSValue` by assignment does **not** touch the refcount.
- Call `.retain()` explicitly whenever a copy needs to outlive the original binding (e.g. storing the same value into two containers).
- Call `.deinit()` exactly once per retained/owned reference. `deinit()` decrements the refcount and only tears down the underlying value when it reaches zero — the same `defer value.deinit()` habit already used across the z-* family, just now meaning "release *my* reference."
- **Never call `ZArray(JSValue).clone()` or `ZObject(JSValue)`'s property-copy helpers directly.** Both are shallow byte-copies that do not retain their elements, so two "clones" would end up sharing boxes with an under-incremented refcount → double-free or premature release. Use `JSValue.cloneArray()` / `JSValue.cloneObject()` instead, which retain every child correctly.

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
| `string` | ⚠️ Placeholder (`RawString`) | UTF-8 byte buffer only — no rope/SSO/UTF-16 surrogates. Will swap to `*Rc(ZString)` once [z-string](https://github.com/carlos-sweb/z-string) ports from Zig 0.15.2 to 0.16; the union shape doesn't change, only the payload type inside the same box. |
| `array` | ✅ Complete | `*Rc(ZArray(JSValue))`, recursive release, `cloneArray()` |
| `object` | ✅ Complete | `*Rc(ZObject(JSValue))`, recursive release, `cloneObject()`. See prototype gap below. |
| `regex` | ✅ Complete | `*Rc(Regex)` from zregexp, no nested JSValues to recurse into |

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
},
```

## Project Structure

```
z-value/
├── src/
│   ├── zvalue.zig      # JSValue union, constructors, retain()/deinit(), cloneArray()/cloneObject()
│   ├── rc.zig            # Rc(T) generic refcounting box
│   ├── raw_string.zig    # RawString (string placeholder, see Variant support)
│   ├── equality.zig      # strictEquals/sameValueZero/hash/JSValueHashContext
│   └── errors.zig
├── tests/
│   ├── value_types_test.zig
│   ├── rc_test.zig
│   ├── array_test.zig
│   ├── object_test.zig
│   ├── regex_test.zig
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
