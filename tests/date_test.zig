const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "newDate wraps a millisecond timestamp, typeof is \"object\"" {
    const d = try JSValue.newDate(testing.allocator, 86400000);
    defer d.deinit();
    try testing.expectEqualStrings("object", d.typeOf());
    try testing.expectEqual(@as(i64, 86400000), d.asDate().value.getTime());
}

test "date value: retain twice, deinit twice, no leak" {
    const d = try JSValue.newDate(testing.allocator, 0);
    const d2 = d.retain();
    try testing.expect(d.asDate() == d2.asDate());
    try testing.expectEqual(@as(usize, 2), d.asDate().refCount());
    d.deinit();
    try testing.expectEqual(@as(usize, 1), d2.asDate().refCount());
    d2.deinit();
}

test "two dates with the same timestamp are never strictly equal (identity semantics)" {
    const a = try JSValue.newDate(testing.allocator, 1000);
    defer a.deinit();
    const b = try JSValue.newDate(testing.allocator, 1000);
    defer b.deinit();
    try testing.expect(!zvalue.equality.strictEquals(a, b));
    try testing.expect(zvalue.equality.strictEquals(a, a));
}

test "out-of-range timestamps become Invalid Date (getters yield null)" {
    const d = try JSValue.newDate(testing.allocator, std.math.maxInt(i64));
    defer d.deinit();
    try testing.expect(d.asDate().value.getFullYear() == null);
}
