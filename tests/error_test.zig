const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const FailingAllocator = std.testing.FailingAllocator;
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

test "newError: OOM at any allocation leaks nothing" {
    // Payload (message copy) first, then the Rc box.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newError(a, .type_error, "boom") catch |err| {
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

test "newAggregateError: OOM releases the handed-over errs too" {
    // errs' ownership is taken even on failure (same as newDataView's owner).
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const e1 = try JSValue.newString(a, "e1");
        const e2 = try JSValue.newString(a, "e2");
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newAggregateError(a, "agg", &.{ e1, e2 }) catch |err| {
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

test "cloneError: OOM on a plain error leaks nothing" {
    // Message copy, then the Rc box.
    // Same k-sweep as the constructor OOM tests, but only the clone's own
    // allocations fail: the source must come out untouched (its deinit
    // below must free everything, with no over- or under-retained child).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const src = try JSValue.newError(a, .range_error, "bad");
        fa.fail_index = fa.alloc_index + k;
        const c = src.cloneError() catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            src.deinit();
            try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
            continue;
        };
        c.deinit();
        src.deinit();
        try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
        try testing.expect(k > 0);
        break;
    }
}

test "cloneError: OOM on an AggregateError leaks nothing and leaves the source intact" {
    // Message + errors slice copies, then the Rc box; nested values retained only on success.
    // Same k-sweep as the constructor OOM tests, but only the clone's own
    // allocations fail: the source must come out untouched (its deinit
    // below must free everything, with no over- or under-retained child).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const src = try JSValue.newAggregateError(a, "agg", &.{ try JSValue.newString(a, "e1"), try JSValue.newString(a, "e2") });
        fa.fail_index = fa.alloc_index + k;
        const c = src.cloneError() catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            src.deinit();
            try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
            continue;
        };
        c.deinit();
        src.deinit();
        try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
        try testing.expect(k > 0);
        break;
    }
}

test "error: releasing a 100 000-deep AggregateError chain does not overflow the stack" {
    var cur = JSValue.NULL;
    for (0..100_000) |_| {
        cur = try JSValue.newAggregateError(testing.allocator, "e", &.{cur});
    }
    cur.deinit();
}
