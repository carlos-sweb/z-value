const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const zregexp = @import("zregexp");

test "regex: fromRegex takes ownership, deinit frees" {
    const re = try zregexp.Regex.compile(testing.allocator, "a+");
    const v = try JSValue.fromRegex(testing.allocator, re);
    try testing.expectEqualStrings("object", v.typeOf());
    v.deinit();
}

test "regex: retain/deinit balance (Rc works with Regex.deinit's by-value receiver)" {
    const re = try zregexp.Regex.compile(testing.allocator, "b*");
    const v = try JSValue.fromRegex(testing.allocator, re);
    const v2 = v.retain();

    try testing.expectEqual(@as(usize, 2), v.regex.count);
    v.deinit();
    try testing.expectEqual(@as(usize, 1), v2.regex.count);
    v2.deinit();
}

test "regex: has no nested JSValues, so deinit doesn't need to recurse" {
    const re = try zregexp.Regex.compile(testing.allocator, "c?");
    const v = try JSValue.fromRegex(testing.allocator, re);
    defer v.deinit();
    try testing.expect(v.regex.value.pattern.len > 0);
}
