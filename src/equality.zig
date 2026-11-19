const std = @import("std");
const zarray = @import("zarray");

// zvalue.zig imports this file, so JSValue can't be imported at the top
// level here without a cycle; it's only needed by name in signatures below,
// which Zig resolves lazily.
const JSValue = @import("zvalue.zig").JSValue;

/// ECMA262 Strict Equality Comparison (`===`) over the full JSValue union.
/// number/string delegate to zarray.equality (content comparison, NaN never
/// equal). array/object/regex/symbol/map/set compare by reference identity
/// (the Rc box pointer) — correct per spec: two distinct objects (and two
/// distinct symbols, even with the same description) are never `===`, even
/// with identical content. bigint is the odd one out among the heap-boxed
/// variants (alongside string): `1n === 1n` is `true` even across two
/// independently-parsed/allocated instances, so it compares by VALUE, not
/// by Rc box identity — see z-bigint's `ZBigInt.eql`.
pub fn strictEquals(a: JSValue, b: JSValue) bool {
    if (a.bits == b.bits) {
        if (a.isNumber()) return !std.math.isNan(a.asNumber());
        return true;
    }
    if (a.tag() != b.tag()) return false;
    return switch (a.unpack()) {
        .undefined, .null => true,
        .boolean => a.asBool() == b.asBool(),
        .number => zarray.equality.strictEquals(f64, a.asNumber(), b.asNumber()),
        .string => zarray.equality.strictEquals([]const u8, a.asString().value.data, b.asString().value.data),
        .array => a.asArray() == b.asArray(),
        .object => a.asObject() == b.asObject(),
        .regex => a.asRegex() == b.asRegex(),
        .symbol => a.asSymbol() == b.asSymbol(),
        .map => a.asMap() == b.asMap(),
        .set => a.asSet() == b.asSet(),
        .@"error" => a.asError() == b.asError(),
        .function => a.asFunction() == b.asFunction(),
        .date => a.asDate() == b.asDate(),
        .promise => a.asPromise() == b.asPromise(),
        .bigint => a.asBigInt().value.eql(b.asBigInt().value),
        .proxy => a.asProxy() == b.asProxy(),
        .array_buffer => a.asArrayBuffer() == b.asArrayBuffer(),
        .data_view => a.asDataView() == b.asDataView(),
        .typed_array => a.asTypedArray() == b.asTypedArray(),
        .temporal => a.asTemporal() == b.asTemporal(),
    };
}

/// ECMA262 SameValueZero over the full JSValue union (NaN equals NaN, +0
/// equals -0 for numbers). Everything else matches strictEquals.
///
/// NOTE the asymmetry: `string` is the only heap-boxed variant compared by
/// *content* rather than reference identity, because strings are primitive
/// values in JS even though this implementation boxes them behind an Rc for
/// cheap JSValue copies. Do not "simplify" this to identity comparison for
/// all heap variants — that would silently break string equality.
pub fn sameValueZero(a: JSValue, b: JSValue) bool {
    if (a.bits == b.bits) {
        return true;
    }
    if (a.tag() != b.tag()) return false;
    if (a.isNumber()) return zarray.equality.sameValueZero(f64, a.asNumber(), b.asNumber());
    if (a.isString()) return zarray.equality.sameValueZero([]const u8, a.asString().value.data, b.asString().value.data);
    return strictEquals(a, b);
}

/// Content hash consistent with sameValueZero, for use as a Map/Set/HashMap
/// key. array/object/regex/symbol/map/set hash their box's pointer identity,
/// matching their identity-based equality. bigint hashes by VALUE (see
/// strictEquals' doc comment above) so it stays consistent with `eql`.
pub fn hash(v: JSValue) u64 {
    if (v.isNumber()) return zarray.equality.hash(f64, v.asNumber());
    return switch (v.unpack()) {
        .undefined => 0x1,
        .null => 0x2,
        .boolean => |b| if (b) @as(u64, 0x3) else @as(u64, 0x4),
        .number => |n| zarray.equality.hash(f64, n),
        .string => |box| zarray.equality.hash([]const u8, box.value.data),
        .array => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .object => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .regex => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .symbol => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .map => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .set => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .@"error" => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .function => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .date => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .promise => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .bigint => |box| zarray.equality.hash(u64, box.value.hash()),
        .proxy => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .array_buffer => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .data_view => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .typed_array => |box| zarray.equality.hash(usize, @intFromPtr(box)),
        .temporal => |box| zarray.equality.hash(usize, @intFromPtr(box)),
    };
}

pub const JSValueHashContext = struct {
    pub fn hash(self: @This(), v: JSValue) u64 {
        _ = self;
        return @import("equality.zig").hash(v);
    }
    pub fn eql(self: @This(), a: JSValue, b: JSValue) bool {
        _ = self;
        return sameValueZero(a, b);
    }
};
