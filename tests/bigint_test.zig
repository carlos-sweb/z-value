const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "newBigInt parses digit text, typeof is \"bigint\" (its own arm, not folded into \"object\")" {
    const v = try JSValue.newBigInt(testing.allocator, "123456789012345678901234567890");
    defer v.deinit();
    try testing.expectEqualStrings("bigint", v.typeOf());
}

test "bigint value: retain twice, deinit twice, no leak" {
    const v = try JSValue.newBigInt(testing.allocator, "42");
    const v2 = v.retain();
    try testing.expect(v.bigint == v2.bigint);
    try testing.expectEqual(@as(usize, 2), v.bigint.count);
    v.deinit();
    try testing.expectEqual(@as(usize, 1), v2.bigint.count);
    v2.deinit();
}

test "unlike Date/Symbol, two independently-parsed equal bigints ARE strictly equal (value semantics)" {
    const a = try JSValue.newBigInt(testing.allocator, "123456789012345678901234567890");
    defer a.deinit();
    const b = try JSValue.newBigInt(testing.allocator, "123456789012345678901234567890");
    defer b.deinit();
    try testing.expect(zvalue.equality.strictEquals(a, b));

    const c = try JSValue.newBigInt(testing.allocator, "0xFF");
    defer c.deinit();
    const d = try JSValue.newBigInt(testing.allocator, "255");
    defer d.deinit();
    try testing.expect(zvalue.equality.strictEquals(c, d));
}

test "bigints of different value are not strictly equal, including across sign" {
    const a = try JSValue.newBigInt(testing.allocator, "5");
    defer a.deinit();
    const b = try JSValue.newBigInt(testing.allocator, "-5");
    defer b.deinit();
    try testing.expect(!zvalue.equality.strictEquals(a, b));
}

test "hash agrees with equality: equal-valued bigints hash equal" {
    const a = try JSValue.newBigInt(testing.allocator, "999999999999999999999999999999");
    defer a.deinit();
    const b = try JSValue.newBigInt(testing.allocator, "999999999999999999999999999999");
    defer b.deinit();
    try testing.expect(zvalue.equality.hash(a) == zvalue.equality.hash(b));
}

test "sameValueZero matches strictEquals for bigint (no NaN/+0/-0 concept)" {
    const a = try JSValue.newBigInt(testing.allocator, "7");
    defer a.deinit();
    const b = try JSValue.newBigInt(testing.allocator, "7");
    defer b.deinit();
    try testing.expect(zvalue.equality.sameValueZero(a, b));
}

test "a bigint is never strictly equal to a number of the same mathematical value (different types)" {
    const bi = try JSValue.newBigInt(testing.allocator, "1");
    defer bi.deinit();
    const num = JSValue.fromNumber(1);
    try testing.expect(!zvalue.equality.strictEquals(bi, num));
}

test "invalid digit text surfaces as a real error, not a crash" {
    try testing.expectError(zvalue.BigIntError.InvalidDigits, JSValue.newBigInt(testing.allocator, "not-a-number"));
}
