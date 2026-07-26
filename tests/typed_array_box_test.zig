const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "typeof a typed array is object" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    const ta = try JSValue.newTypedArray(testing.allocator, buf.retain(), 0, 4, .u8);
    defer ta.deinit();
    try testing.expectEqualStrings("object", ta.typeOf());
}

test "TypedKind.elemSize / isBigInt" {
    try testing.expectEqual(@as(usize, 1), zvalue.TypedKind.u8.elemSize());
    try testing.expectEqual(@as(usize, 1), zvalue.TypedKind.u8_clamped.elemSize());
    try testing.expectEqual(@as(usize, 4), zvalue.TypedKind.f32.elemSize());
    try testing.expectEqual(@as(usize, 8), zvalue.TypedKind.i64.elemSize());
    try testing.expect(zvalue.TypedKind.i64.isBigInt());
    try testing.expect(zvalue.TypedKind.u64.isBigInt());
    try testing.expect(!zvalue.TypedKind.f64.isBigInt());
}

test "typed arrays compare by identity, not by content" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    const a = try JSValue.newTypedArray(testing.allocator, buf.retain(), 0, 4, .u8);
    defer a.deinit();
    const b = try JSValue.newTypedArray(testing.allocator, buf.retain(), 0, 4, .u8);
    defer b.deinit();
    try testing.expect(!zvalue.equality.strictEquals(a, b));
    try testing.expect(zvalue.equality.strictEquals(a, a));
}

test "deinit releases the owning ArrayBuffer reference (refcount, not a leak/crash)" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.count);
    const ta = try JSValue.newTypedArray(testing.allocator, buf.retain(), 0, 4, .u8);
    try testing.expectEqual(@as(usize, 2), buf.array_buffer.count);
    ta.deinit();
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.count);
    buf.deinit();
}

test "newTypedArray validates alignment and bounds, doesn't just trust its args" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    // byte_offset 1 isn't a multiple of i32's element size (4).
    try testing.expectError(error.Misaligned, JSValue.newTypedArray(testing.allocator, buf.retain(), 1, 1, .i32));
    // 2 elements of i32 (8 bytes) doesn't fit in a 4-byte buffer.
    try testing.expectError(error.OutOfBounds, JSValue.newTypedArray(testing.allocator, buf.retain(), 0, 2, .i32));
}

test "an out-of-bounds constructor attempt doesn't leak the owner reference" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.count);
    _ = JSValue.newTypedArray(testing.allocator, buf.retain(), 0, 99, .i32) catch {};
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.count); // the extra retain() was released
}
