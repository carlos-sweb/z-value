const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const equality = @import("zvalue").equality;

test "strictEquals: undefined and null are each equal only to themselves" {
    try testing.expect(equality.strictEquals(JSValue.UNDEFINED, JSValue.UNDEFINED));
    try testing.expect(equality.strictEquals(JSValue.NULL, JSValue.NULL));
    try testing.expect(!equality.strictEquals(JSValue.UNDEFINED, JSValue.NULL));
}

test "strictEquals: NaN is never equal, sameValueZero says NaN equals NaN" {
    const nan1 = JSValue.fromNumber(std.math.nan(f64));
    const nan2 = JSValue.fromNumber(std.math.nan(f64));

    try testing.expect(!equality.strictEquals(nan1, nan2));
    try testing.expect(equality.sameValueZero(nan1, nan2));
}

test "strictEquals and sameValueZero: +0 equals -0" {
    const pos_zero = JSValue.fromNumber(0.0);
    const neg_zero = JSValue.fromNumber(-0.0);

    try testing.expect(equality.strictEquals(pos_zero, neg_zero));
    try testing.expect(equality.sameValueZero(pos_zero, neg_zero));
}

test "arrays/objects/regexes compare by identity, not content" {
    var a = try JSValue.newArray(testing.allocator);
    defer a.deinit();
    var b = try JSValue.newArray(testing.allocator);
    defer b.deinit();

    // Same (empty) content, different boxes -> not ===.
    try testing.expect(!equality.strictEquals(a, b));

    // The same box, retained -> ===.
    const a2 = a.retain();
    defer a2.deinit();
    try testing.expect(equality.strictEquals(a, a2));
}

test "strings compare by content, unlike the other heap-boxed variants" {
    const s1 = try JSValue.newString(testing.allocator, "hello");
    defer s1.deinit();
    const s2 = try JSValue.newString(testing.allocator, "hello");
    defer s2.deinit();

    // Different boxes, same content -> still === (strings are primitives).
    try testing.expect(equality.strictEquals(s1, s2));
}

test "different types are never equal" {
    try testing.expect(!equality.strictEquals(JSValue.fromNumber(0.0), JSValue.fromBool(false)));
    try testing.expect(!equality.strictEquals(JSValue.NULL, JSValue.UNDEFINED));
}

test "hash: sameValueZero-equal values hash identically" {
    const nan1 = JSValue.fromNumber(std.math.nan(f64));
    const nan2 = JSValue.fromNumber(std.math.nan(f64));
    try testing.expectEqual(equality.hash(nan1), equality.hash(nan2));

    const s1 = try JSValue.newString(testing.allocator, "abc");
    defer s1.deinit();
    const s2 = try JSValue.newString(testing.allocator, "abc");
    defer s2.deinit();
    try testing.expectEqual(equality.hash(s1), equality.hash(s2));
}

test "JSValueHashContext works as a std.HashMap context" {
    var map = std.HashMap(JSValue, i32, equality.JSValueHashContext, std.hash_map.default_max_load_percentage).init(testing.allocator);
    defer map.deinit();

    try map.put(JSValue.fromNumber(1.0), 100);
    try map.put(JSValue.fromNumber(2.0), 200);

    try testing.expectEqual(@as(?i32, 100), map.get(JSValue.fromNumber(1.0)));
    try testing.expectEqual(@as(?i32, null), map.get(JSValue.fromNumber(3.0)));
}
