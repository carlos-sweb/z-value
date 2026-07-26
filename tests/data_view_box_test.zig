const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "typeof ArrayBuffer/DataView is object" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 8);
    defer buf.deinit();
    try testing.expectEqualStrings("object", buf.typeOf());

    const dv = try JSValue.newDataView(testing.allocator, buf.retain(), 0, null);
    defer dv.deinit();
    try testing.expectEqualStrings("object", dv.typeOf());
}

test "ArrayBuffer/DataView compare by identity, not by content" {
    const a = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer a.deinit();
    const b = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer b.deinit();
    try testing.expect(!zvalue.equality.strictEquals(a, b));
    try testing.expect(zvalue.equality.strictEquals(a, a));

    const dv_a = try JSValue.newDataView(testing.allocator, a.retain(), 0, null);
    defer dv_a.deinit();
    const dv_b = try JSValue.newDataView(testing.allocator, b.retain(), 0, null);
    defer dv_b.deinit();
    try testing.expect(!zvalue.equality.strictEquals(dv_a, dv_b));
}

test "DataView reads/writes through to its owning ArrayBuffer" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    const dv = try JSValue.newDataView(testing.allocator, buf.retain(), 0, null);
    defer dv.deinit();

    try dv.data_view.value.view.setInt32(0, -1, false);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, buf.array_buffer.value.bytes);
}

test "deinit releases the owning ArrayBuffer reference (refcount, not a leak/crash)" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.count);

    const dv = try JSValue.newDataView(testing.allocator, buf.retain(), 0, null);
    try testing.expectEqual(@as(usize, 2), buf.array_buffer.count);

    dv.deinit();
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.count);
    buf.deinit();
}

test "a DataView with an out-of-range window is a real error, not a crash" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    try testing.expectError(error.OutOfBounds, JSValue.newDataView(testing.allocator, buf.retain(), 2, 4));
}
