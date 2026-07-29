const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const ztemporal = @import("ztemporal");

test "newTemporal wraps a PlainDate, typeof is \"object\"" {
    const pd = try ztemporal.PlainDate.create(2024, 6, 15, .constrain);
    const v = try JSValue.newTemporal(testing.allocator, .{ .plain_date = pd });
    defer v.deinit();
    try testing.expectEqualStrings("object", v.typeOf());
    try testing.expectEqual(@as(i32, 2024), v.temporal.value.plain_date.year());
}

test "temporal value: retain twice, deinit twice, no leak" {
    const inst = try ztemporal.Instant.fromEpochMilliseconds(0);
    const v = try JSValue.newTemporal(testing.allocator, .{ .instant = inst });
    const v2 = v.retain();
    try testing.expect(v.temporal == v2.temporal);
    try testing.expectEqual(@as(usize, 2), v.temporal.count);
    v.deinit();
    try testing.expectEqual(@as(usize, 1), v2.temporal.count);
    v2.deinit();
}

test "two Temporal instances with the same value are never strictly equal (identity semantics)" {
    const a_val = try ztemporal.PlainDate.create(2024, 1, 1, .constrain);
    const a = try JSValue.newTemporal(testing.allocator, .{ .plain_date = a_val });
    defer a.deinit();
    const b_val = try ztemporal.PlainDate.create(2024, 1, 1, .constrain);
    const b = try JSValue.newTemporal(testing.allocator, .{ .plain_date = b_val });
    defer b.deinit();
    try testing.expect(!zvalue.equality.strictEquals(a, b));
    try testing.expect(zvalue.equality.strictEquals(a, a));
    // Value equality goes through the wrapped type's own .equals(), not ===.
    try testing.expect(ztemporal.PlainDate.equals(a.temporal.value.plain_date, b.temporal.value.plain_date));
}

test "kindName distinguishes all 8 wrapped types" {
    try testing.expectEqualStrings("Temporal.PlainDate", (TemporalValue{ .plain_date = undefined }).kindName());
    try testing.expectEqualStrings("Temporal.Duration", (TemporalValue{ .duration = undefined }).kindName());
}
const TemporalValue = zvalue.TemporalValue;
