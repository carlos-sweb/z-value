const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const ErrorKind = zvalue.ErrorKind;

test "error: newError constructs and deinit frees the box" {
    var err = try JSValue.newError(testing.allocator, .type_error, "bad type");
    err.deinit();
}

test "error: each ErrorKind round-trips through toString via the wrapper" {
    const kinds = [_]ErrorKind{
        .generic,         .type_error, .range_error, .syntax_error,
        .reference_error, .eval_error, .uri_error,
    };
    for (kinds) |kind| {
        var err = try JSValue.newError(testing.allocator, kind, "x");
        defer err.deinit();

        const s = try err.@"error".value.toString(testing.allocator);
        defer testing.allocator.free(s);

        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "{s}: x", .{kind.name()});
        try testing.expectEqualStrings(expected, s);
    }
}

test "error: shared box is released once per retain" {
    var err = try JSValue.newError(testing.allocator, .range_error, "shared");
    _ = err.retain();
    try testing.expectEqual(@as(usize, 2), err.@"error".count);

    err.deinit();
    try testing.expectEqual(@as(usize, 1), err.@"error".count);

    err.deinit();
}

test "error: AggregateError releases every nested JSValue recursively" {
    const a = try JSValue.newString(testing.allocator, "err a");
    const b = try JSValue.newString(testing.allocator, "err b");

    var agg = try JSValue.newAggregateError(testing.allocator, "batch failed", &.{ a, b });
    agg.deinit(); // must release `a` and `b` too, or the leak detector catches it.
}

test "error: AggregateError with no errors has null errors slice" {
    var err = try JSValue.newError(testing.allocator, .generic, "plain");
    defer err.deinit();
    try testing.expect(err.@"error".value.errors == null);
}

test "cloneError duplicates a plain error independently" {
    var original = try JSValue.newError(testing.allocator, .syntax_error, "oops");
    var copy = try original.cloneError();

    original.deinit();

    const s = try copy.@"error".value.toString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("SyntaxError: oops", s);

    copy.deinit();
}

test "cloneError retains every nested value of an AggregateError" {
    const child = try JSValue.newString(testing.allocator, "shared");
    var original = try JSValue.newAggregateError(testing.allocator, "batch", &.{child});
    try testing.expectEqual(@as(usize, 1), child.string.count);

    var copy = try original.cloneError();
    try testing.expectEqual(@as(usize, 2), child.string.count);

    original.deinit();
    try testing.expectEqual(@as(usize, 1), child.string.count);

    copy.deinit();
}

test "typeof an error is \"object\"" {
    var err = try JSValue.newError(testing.allocator, .type_error, "x");
    defer err.deinit();
    try testing.expectEqualStrings("object", err.typeOf());
}

test "error: strict equality compares by box identity, not content" {
    var a = try JSValue.newError(testing.allocator, .type_error, "same message");
    defer a.deinit();
    var b = try JSValue.newError(testing.allocator, .type_error, "same message");
    defer b.deinit();

    try testing.expect(!zvalue.equality.strictEquals(a, b));
    try testing.expect(zvalue.equality.strictEquals(a, a));
}
