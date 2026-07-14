const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

fn dummyCall(ctx: *anyopaque, allocator: std.mem.Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    _ = args;
    return JSValue.fromNumber(42);
}

test "typeof a function value is \"function\"" {
    var dummy_ctx: u8 = 0;
    const f = try JSValue.newFunction(testing.allocator, .{ .ctx = &dummy_ctx, .call = dummyCall });
    defer f.deinit();
    try testing.expectEqualStrings("function", f.typeOf());
}

test "calling a function value invokes its native call, name/arity round-trip" {
    var dummy_ctx: u8 = 0;
    const f = try JSValue.newFunction(testing.allocator, .{ .ctx = &dummy_ctx, .name = "answer", .arity = 2, .call = dummyCall });
    defer f.deinit();
    const result = try f.function.value.call(f.function.value.ctx, testing.allocator, JSValue.UNDEFINED, &.{});
    try testing.expect(result.number == 42);
    try testing.expectEqualStrings("answer", f.function.value.name);
    try testing.expectEqual(@as(usize, 2), f.function.value.arity);
}

test "function value: retain twice, deinit twice, no leak" {
    var dummy_ctx: u8 = 0;
    const f = try JSValue.newFunction(testing.allocator, .{ .ctx = &dummy_ctx, .call = dummyCall });
    const f2 = f.retain();
    try testing.expect(f.function == f2.function);
    try testing.expectEqual(@as(usize, 2), f.function.count);

    f.deinit();
    try testing.expectEqual(@as(usize, 1), f2.function.count);
    f2.deinit();
}

test "two distinct function values are never strictly equal, even with identical fields" {
    var ctx1: u8 = 0;
    var ctx2: u8 = 0;
    const f1 = try JSValue.newFunction(testing.allocator, .{ .ctx = &ctx1, .call = dummyCall });
    defer f1.deinit();
    const f2 = try JSValue.newFunction(testing.allocator, .{ .ctx = &ctx2, .call = dummyCall });
    defer f2.deinit();
    try testing.expect(!zvalue.equality.strictEquals(f1, f2));
    try testing.expect(zvalue.equality.strictEquals(f1, f1));
}
