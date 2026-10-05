const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const FailingAllocator = std.testing.FailingAllocator;
const JSValue = zvalue.JSValue;

fn dummyCall(ctx: *anyopaque, allocator: std.mem.Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    _ = args;
    return JSValue.fromNumber(42);
}

test "typeof a proxy over a plain object is \"object\"" {
    const target = try JSValue.newObject(testing.allocator);
    const handler = try JSValue.newObject(testing.allocator);
    const p = try JSValue.newProxy(testing.allocator, target, handler);
    defer p.deinit();
    try testing.expectEqualStrings("object", p.typeOf());
}

test "typeof a proxy over a callable target is \"function\" (reports the target's type)" {
    var dummy_ctx: u8 = 0;
    const target = try JSValue.newFunction(testing.allocator, .{ .ctx = &dummy_ctx, .call = dummyCall });
    const handler = try JSValue.newObject(testing.allocator);
    const p = try JSValue.newProxy(testing.allocator, target, handler);
    defer p.deinit();
    try testing.expectEqualStrings("function", p.typeOf());
}

test "typeof unwraps through a proxy-over-a-proxy over a callable target" {
    var dummy_ctx: u8 = 0;
    const target = try JSValue.newFunction(testing.allocator, .{ .ctx = &dummy_ctx, .call = dummyCall });
    const inner_handler = try JSValue.newObject(testing.allocator);
    const inner = try JSValue.newProxy(testing.allocator, target, inner_handler);
    const outer_handler = try JSValue.newObject(testing.allocator);
    const outer = try JSValue.newProxy(testing.allocator, inner, outer_handler);
    defer outer.deinit();
    try testing.expectEqualStrings("function", outer.typeOf());
}

test "proxy value: retain twice, deinit twice, no leak" {
    const target = try JSValue.newObject(testing.allocator);
    const handler = try JSValue.newObject(testing.allocator);
    const p = try JSValue.newProxy(testing.allocator, target, handler);
    const p2 = p.retain();
    try testing.expect(p.proxy == p2.proxy);
    try testing.expectEqual(@as(usize, 2), p.proxy.count);
    p.deinit();
    try testing.expectEqual(@as(usize, 1), p2.proxy.count);
    p2.deinit();
}

test "two proxies over the same target/handler are never strictly equal (identity semantics, like Date/Symbol)" {
    const target1 = try JSValue.newObject(testing.allocator);
    const handler1 = try JSValue.newObject(testing.allocator);
    const a = try JSValue.newProxy(testing.allocator, target1, handler1);
    defer a.deinit();

    const target2 = try JSValue.newObject(testing.allocator);
    const handler2 = try JSValue.newObject(testing.allocator);
    const b = try JSValue.newProxy(testing.allocator, target2, handler2);
    defer b.deinit();

    try testing.expect(!zvalue.equality.strictEquals(a, b));
    try testing.expect(zvalue.equality.strictEquals(a, a));
}

test "deinit releases both target and handler" {
    const target = try JSValue.newObject(testing.allocator);
    const handler = try JSValue.newObject(testing.allocator);
    try testing.expectEqual(@as(usize, 1), target.object.count);
    try testing.expectEqual(@as(usize, 1), handler.object.count);
    const p = try JSValue.newProxy(testing.allocator, target, handler);
    p.deinit();
    // Nothing further to assert directly (the boxes are freed) -- this
    // test's real value is running clean under testing.allocator's leak
    // detector, proving deinit() actually released both fields.
}

test "newProxy: OOM releases the handed-over target and handler" {
    // target/handler are owned by the call even on failure (same as newDataView's owner).
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const target = try JSValue.newObject(a);
        const handler = try JSValue.newObject(a);
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newProxy(a, target, handler) catch |err| {
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
