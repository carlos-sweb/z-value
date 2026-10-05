const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const zregex = @import("zregex");
const FailingAllocator = std.testing.FailingAllocator;

test "regex: fromRegex takes ownership, deinit frees" {
    const re = try zregex.Regex.compile(testing.allocator, "a+");
    const v = try JSValue.fromRegex(testing.allocator, re);
    try testing.expectEqualStrings("object", v.typeOf());
    v.deinit();
}

test "regex: retain/deinit balance (Rc works with Regex.deinit's by-value receiver)" {
    const re = try zregex.Regex.compile(testing.allocator, "b*");
    const v = try JSValue.fromRegex(testing.allocator, re);
    const v2 = v.retain();

    try testing.expectEqual(@as(usize, 2), v.regex.count);
    v.deinit();
    try testing.expectEqual(@as(usize, 1), v2.regex.count);
    v2.deinit();
}

test "regex: has no nested JSValues, so deinit doesn't need to recurse" {
    const re = try zregex.Regex.compile(testing.allocator, "c?");
    const v = try JSValue.fromRegex(testing.allocator, re);
    defer v.deinit();
    try testing.expect(v.regex.value.pattern.len > 0);
}

test "fromRegex: OOM releases the handed-over Regex" {
    // `re` is owned by the call even when the box allocation fails.
    // Fails z-value's k-th allocation for k = 0, 1, ... until the call
    // succeeds; every failure must return OutOfMemory with nothing leaked
    // (testing.allocator also catches double frees, Rc's decref asserts
    // against underflow).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const re = try zregex.Regex.compile(a, "a+b");
        fa.fail_index = fa.alloc_index + k;
        const v = JSValue.fromRegex(a, re) catch |err| {
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
