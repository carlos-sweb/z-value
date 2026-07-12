const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;

test "string value: single owner, deinit frees" {
    const s = try JSValue.newString(testing.allocator, "hello");
    s.deinit();
}

test "string value: retain twice, deinit twice, no leak" {
    const s = try JSValue.newString(testing.allocator, "hello");
    const s2 = s.retain();
    try testing.expect(s.string == s2.string);
    try testing.expectEqual(@as(usize, 2), s.string.count);

    s.deinit();
    try testing.expectEqual(@as(usize, 1), s2.string.count);
    s2.deinit();
}

test "string value: content is preserved" {
    const s = try JSValue.newString(testing.allocator, "hola mundo");
    defer s.deinit();
    try testing.expectEqualStrings("hola mundo", s.string.value.bytes);
}

test "retain on value types is a no-op (no box to touch)" {
    const n = JSValue.fromNumber(1.0);
    const n2 = n.retain();
    n.deinit();
    n2.deinit();
    try testing.expect(n2.number == 1.0);
}

// An unbalanced deinit() (releasing more times than retained) trips the
// std.debug.assert(count > 0) inside Rc.decref() — this only panics in
// Debug/ReleaseSafe builds; in ReleaseFast the assert compiles out and the
// underflow is undefined behavior. We don't (and can't portably) test the
// panic itself here, but this is documented in the README as a hard
// requirement: retain()/deinit() calls must always balance.
