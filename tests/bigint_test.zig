const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const FailingAllocator = std.testing.FailingAllocator;
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

test "newBigInt: OOM at any allocation leaks nothing" {
    // Payload (digit limbs) first, then the Rc box.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newBigInt(a, "123456789012345678901234567890123456789") catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
            continue;
        };
        v.deinit();
        try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
        try testing.expect(k > 0); // at least one failure point was exercised
        break;
    }
}

test "newBigIntFromValue: OOM releases the handed-over ZBigInt" {
    // `v` is owned by the call even when the box allocation fails.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const parsed = try JSValue.newBigInt(a, "-98765432109876543210");
        const sum = try zvalue.ZBigInt.add(a, parsed.bigint.value, parsed.bigint.value);
        parsed.deinit();
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newBigIntFromValue(a, sum) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
            continue;
        };
        v.deinit();
        try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
        try testing.expect(k > 0); // at least one failure point was exercised
        break;
    }
}
