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
/// with identical content.
pub fn strictEquals(a: JSValue, b: JSValue) bool {
    if (@as(std.meta.Tag(JSValue), a) != @as(std.meta.Tag(JSValue), b)) return false;
    return switch (a) {
        .@"undefined", .@"null" => true,
        .boolean => a.boolean == b.boolean,
        .number => zarray.equality.strictEquals(f64, a.number, b.number),
        .string => zarray.equality.strictEquals([]const u8, a.string.value.data, b.string.value.data),
        .array => a.array == b.array,
        .object => a.object == b.object,
        .regex => a.regex == b.regex,
        .symbol => a.symbol == b.symbol,
        .map => a.map == b.map,
        .set => a.set == b.set,
        .@"error" => a.@"error" == b.@"error",
        .function => a.function == b.function,
        .date => a.date == b.date,
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
    if (@as(std.meta.Tag(JSValue), a) != @as(std.meta.Tag(JSValue), b)) return false;
    return switch (a) {
        .number => zarray.equality.sameValueZero(f64, a.number, b.number),
        .string => zarray.equality.sameValueZero([]const u8, a.string.value.data, b.string.value.data),
        else => strictEquals(a, b),
    };
}

/// Content hash consistent with sameValueZero, for use as a Map/Set/HashMap
/// key. array/object/regex/symbol/map/set hash their box's pointer identity,
/// matching their identity-based equality.
pub fn hash(v: JSValue) u64 {
    return switch (v) {
        .@"undefined" => 0x1,
        .@"null" => 0x2,
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
