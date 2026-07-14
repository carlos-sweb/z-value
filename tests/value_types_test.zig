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
            .@"undefined" => "undefined",
            .@"null" => "null",
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
        };
        try testing.expect(label.len > 0);
    }
}
