const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;

test "newSymbol: single owner, deinit frees" {
    const s = try JSValue.newSymbol(testing.allocator, "id");
    s.deinit();
}

test "newSymbol: retain twice, deinit twice, no leak" {
    const s = try JSValue.newSymbol(testing.allocator, "id");
    const s2 = s.retain();
    try testing.expect(s.symbol == s2.symbol);
    try testing.expectEqual(@as(usize, 2), s.symbol.count);

    s.deinit();
    try testing.expectEqual(@as(usize, 1), s2.symbol.count);
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
