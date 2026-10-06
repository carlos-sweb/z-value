const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const FailingAllocator = std.testing.FailingAllocator;

test "newSymbol: single owner, deinit frees" {
    const s = try JSValue.newSymbol(testing.allocator, "id");
    s.deinit();
}

test "newSymbol: retain twice, deinit twice, no leak" {
    const s = try JSValue.newSymbol(testing.allocator, "id");
    const s2 = s.retain();
    try testing.expect(s.symbol == s2.symbol);
    try testing.expectEqual(@as(usize, 2), s.symbol.refCount());

    s.deinit();
    try testing.expectEqual(@as(usize, 1), s2.symbol.refCount());
    s2.deinit();
}

test "every newSymbol() call is unique, even with the same description" {
    const a = try JSValue.newSymbol(testing.allocator, "dup");
    defer a.deinit();
    const b = try JSValue.newSymbol(testing.allocator, "dup");
    defer b.deinit();

    try testing.expect(a.symbol != b.symbol);
    try testing.expect(!@import("zvalue").equality.strictEquals(a, b));
}

test "typeof a symbol is \"symbol\", not \"object\"" {
    const s = try JSValue.newSymbol(testing.allocator, null);
    defer s.deinit();
    try testing.expectEqualStrings("symbol", s.typeOf());
}

test "description is accessible on the underlying ZSymbol" {
    const s = try JSValue.newSymbol(testing.allocator, "hello");
    defer s.deinit();
    try testing.expectEqualStrings("hello", s.symbol.value.description.?);
}

test "symbol with null description" {
    const s = try JSValue.newSymbol(testing.allocator, null);
    defer s.deinit();
    try testing.expect(s.symbol.value.description == null);
}

test "newSymbol: OOM at any allocation leaks nothing" {
    // Payload (description copy) first, then the Rc box.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.newSymbol(a, "desc") catch |err| {
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
