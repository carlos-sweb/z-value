const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;

test "UNDEFINED and NULL constants" {
    try testing.expectEqualStrings("undefined", JSValue.UNDEFINED.typeOf());
    try testing.expectEqualStrings("object", JSValue.NULL.typeOf());
}

test "typeof matches ECMAScript typeof operator" {
    try testing.expectEqualStrings("boolean", JSValue.fromBool(true).typeOf());
    try testing.expectEqualStrings("number", JSValue.fromNumber(42.0).typeOf());
}

test "fromBool / fromNumber round-trip" {
    const t = JSValue.fromBool(true);
    try testing.expect(t.boolean == true);

    const n = JSValue.fromNumber(3.14);
    try testing.expect(n.number == 3.14);
}

test "value types are trivially copyable (no deinit needed)" {
    const a = JSValue.fromNumber(5.0);
    const b = a; // plain copy
    a.deinit();
    b.deinit();
    try testing.expect(b.number == 5.0);
}

test "JSValue size is small (value types stay inline)" {
    // Tag (smallest int that fits all variants) + largest payload (f64/pointer,
    // both 8 bytes) plus alignment padding. This is a sanity bound, not an
    // exact-size assertion tied to a specific Zig ABI layout decision.
    try testing.expect(@sizeOf(JSValue) <= 24);
}

test "switch over JSValue is exhaustive" {
    const values = [_]JSValue{
        JSValue.UNDEFINED,
        JSValue.NULL,
        JSValue.fromBool(false),
        JSValue.fromNumber(0.0),
    };
    for (values) |v| {
        const label: []const u8 = switch (v) {
            .undefined => "undefined",
            .null => "null",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .array => "array",
            .object => "object",
            .regex => "regex",
            .symbol => "symbol",
            .map => "map",
            .set => "set",
            .@"error" => "error",
            .function => "function",
            .date => "date",
            .promise => "promise",
            .bigint => "bigint",
            .proxy => "proxy",
            .array_buffer => "array_buffer",
            .data_view => "data_view",
            .typed_array => "typed_array",
            .temporal => "temporal",
        };
        try testing.expect(label.len > 0);
    }
}

const FailingAllocator = std.testing.FailingAllocator;

fn noopCall(ctx: *anyopaque, a: std.mem.Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = a;
    _ = this_value;
    _ = args;
    return JSValue.UNDEFINED;
}
var noop_ctx: u8 = 0;

/// One level of every container kind in turn, each also holding a leaf or
/// a view, so a single chain exercises every release path of deinit().
fn buildMixedChain(a: std.mem.Allocator, depth: usize) !JSValue {
    var cur = JSValue.NULL;
    errdefer cur.deinit();
    for (0..depth) |i| {
        const next: JSValue = switch (i % 8) {
            0 => blk: {
                const v = try JSValue.newArray(a);
                errdefer v.deinit();
                _ = try v.array.value.push(cur);
                cur = JSValue.NULL;
                _ = try v.array.value.push(try JSValue.newString(a, "leaf"));
                break :blk v;
            },
            1 => blk: {
                const v = try JSValue.newObject(a);
                errdefer v.deinit();
                try v.object.value.set("next", cur);
                cur = JSValue.NULL;
                const getter = try JSValue.newBigInt(a, "123456789012345678901234567890");
                v.object.value.defineAccessor("acc", getter, null, JSValue.UNDEFINED) catch |e| {
                    getter.deinit();
                    return e;
                };
                break :blk v;
            },
            2 => blk: {
                const v = try JSValue.newMap(a);
                errdefer v.deinit();
                try v.map.value.set(cur, try JSValue.newDate(a, 0));
                cur = JSValue.NULL;
                break :blk v;
            },
            3 => blk: {
                const v = try JSValue.newSet(a);
                errdefer v.deinit();
                try v.set.value.add(cur);
                cur = JSValue.NULL;
                const buf = try JSValue.newArrayBuffer(a, 8);
                const view = try JSValue.newTypedArray(a, buf, 0, null, .u8);
                v.set.value.add(view) catch |e| {
                    view.deinit();
                    return e;
                };
                break :blk v;
            },
            4 => blk: {
                const sym = try JSValue.newSymbol(a, "s");
                const prev = cur;
                cur = JSValue.NULL; // consumed by the call even on failure
                break :blk try JSValue.newAggregateError(a, "agg", &.{ prev, sym });
            },
            5 => blk: {
                const prev = cur;
                cur = JSValue.NULL; // consumed by the call even on failure
                break :blk try JSValue.newFunction(a, .{ .ctx = &noop_ctx, .call = noopCall, .prototype = prev });
            },
            6 => blk: {
                // A still-pending promise: the chain continues through a
                // stored reaction (the settled-result path has its own test).
                const v = try JSValue.newPromise(a);
                errdefer v.deinit();
                const buf = try JSValue.newArrayBuffer(a, 8);
                const view = try JSValue.newDataView(a, buf, 0, null);
                _ = v.promise.value.subscribe(a, .{ .on_fulfilled = view, .derived = cur }) catch |e| {
                    view.deinit();
                    return e;
                };
                cur = JSValue.NULL;
                break :blk v;
            },
            else => blk: {
                const handler = try JSValue.newTemporal(a, .{ .duration = .{ .days = 1 } });
                const prev = cur;
                cur = JSValue.NULL; // consumed by the call even on failure
                break :blk try JSValue.newProxy(a, prev, handler);
            },
        };
        cur = next;
    }
    return cur;
}

test "deinit: a 100 000-deep chain mixing every container kind releases cleanly" {
    const v = try buildMixedChain(testing.allocator, 100_000);
    v.deinit();
}

test "deinit: a 100 000-deep promise-result chain does not overflow the stack" {
    var cur = JSValue.NULL;
    for (0..100_000) |_| {
        const p = try JSValue.newPromise(testing.allocator);
        testing.allocator.free(try p.promise.value.settle(testing.allocator, .fulfilled, cur));
        cur = p;
    }
    cur.deinit();
}

test "deinit never allocates: it completes with every allocation failing" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const v = try buildMixedChain(fa.allocator(), 1_000);
    const allocations_before = fa.allocations;
    // From here on, every allocation and every in-place resize fails.
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = 0;
    v.deinit();
    try testing.expect(!fa.has_induced_failure);
    try testing.expectEqual(allocations_before, fa.allocations);
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "deinit releases a shared child exactly once, whatever the release order" {
    const shared = try JSValue.newArray(testing.allocator);
    defer shared.deinit();
    const left = try JSValue.newArray(testing.allocator);
    _ = try left.array.value.push(shared.retain());
    const right = try JSValue.newMap(testing.allocator);
    try right.map.value.set(shared.retain(), shared.retain());
    const root = try JSValue.newArray(testing.allocator);
    _ = try root.array.value.push(left);
    _ = try root.array.value.push(right);
    try testing.expectEqual(@as(usize, 4), shared.array.count);
    root.deinit();
    try testing.expectEqual(@as(usize, 1), shared.array.count);
}
