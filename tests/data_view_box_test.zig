const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const FailingAllocator = std.testing.FailingAllocator;
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
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.refCount());

    const dv = try JSValue.newDataView(testing.allocator, buf.retain(), 0, null);
    try testing.expectEqual(@as(usize, 2), buf.array_buffer.refCount());

    dv.deinit();
    try testing.expectEqual(@as(usize, 1), buf.array_buffer.refCount());
    buf.deinit();
}

test "a DataView with an out-of-range window is a real error, not a crash" {
    const buf = try JSValue.newArrayBuffer(testing.allocator, 4);
    defer buf.deinit();
    try testing.expectError(error.OutOfBounds, JSValue.newDataView(testing.allocator, buf.retain(), 2, 4));
}

test "newArrayBuffer: OOM at any allocation leaks nothing" {
    // Payload (byte storage) first, then the Rc box.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newArrayBuffer(a, 64) catch |err| {
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

test "newSharedArrayBuffer: OOM at any allocation leaks nothing" {
    // Same shape as newArrayBuffer.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newSharedArrayBuffer(a, 64) catch |err| {
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
