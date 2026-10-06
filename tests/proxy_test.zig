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
    try testing.expectEqual(@as(usize, 2), p.proxy.refCount());
    p.deinit();
    try testing.expectEqual(@as(usize, 1), p2.proxy.refCount());
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
    try testing.expectEqual(@as(usize, 1), target.object.refCount());
    try testing.expectEqual(@as(usize, 1), handler.object.refCount());
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

test "proxy: releasing a 100 000-deep proxy chain does not overflow the stack" {
    var cur = try JSValue.newObject(testing.allocator);
    for (0..100_000) |i| {
        cur = if (i % 2 == 0)
            try JSValue.newProxy(testing.allocator, cur, JSValue.UNDEFINED)
        else
            try JSValue.newProxy(testing.allocator, JSValue.UNDEFINED, cur);
    }
    cur.deinit();
}

fn proxyChain(a: std.mem.Allocator, target: JSValue, depth: usize) !JSValue {
    var cur = target;
    for (0..depth) |_| cur = try JSValue.newProxy(a, cur, JSValue.UNDEFINED);
    return cur;
}

test "typeof through a 100 000-deep proxy chain reports the final target's type" {
    var dummy_ctx: u8 = 0;
    const over_object = try proxyChain(testing.allocator, try JSValue.newObject(testing.allocator), 100_000);
    defer over_object.deinit();
    try testing.expectEqualStrings("object", over_object.typeOf());

    const f = try JSValue.newFunction(testing.allocator, .{ .ctx = &dummy_ctx, .call = dummyCall });
    const over_function = try proxyChain(testing.allocator, f, 100_000);
    defer over_function.deinit();
    try testing.expectEqualStrings("function", over_function.typeOf());
}

test "typeof through a 1 000 000-deep proxy chain (the depth that overflowed the recursive typeOf)" {
    const a = std.heap.smp_allocator;
    const chain = try proxyChain(a, try JSValue.newObject(a), 1_000_000);
    defer chain.deinit();
    try testing.expectEqualStrings("object", chain.typeOf());
}

test "typeof of a short proxy chain equals typeof of its final target, for every target kind" {
    const a = testing.allocator;
    var dummy_ctx: u8 = 0;
    const targets = [_]JSValue{
        JSValue.UNDEFINED,
        JSValue.NULL,
        JSValue.fromBool(true),
        JSValue.fromNumber(1),
        try JSValue.newString(a, "s"),
        try JSValue.newSymbol(a, "sym"),
        try JSValue.newBigInt(a, "1"),
        try JSValue.newFunction(a, .{ .ctx = &dummy_ctx, .call = dummyCall }),
        try JSValue.newObject(a),
        try JSValue.newArray(a),
        try JSValue.newMap(a),
        try JSValue.newDate(a, 0),
    };
    defer for (targets) |t| t.deinit();
    for (targets) |t| {
        for ([_]usize{ 1, 2, 3 }) |depth| {
            const chain = try proxyChain(a, t.retain(), depth);
            defer chain.deinit();
            try testing.expectEqualStrings(t.typeOf(), chain.typeOf());
        }
    }
}
