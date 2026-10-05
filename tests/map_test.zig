const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const FailingAllocator = std.testing.FailingAllocator;

test "map: set/get value types, deinit frees the map" {
    var map = try JSValue.newMap(testing.allocator);
    try map.map.value.set(JSValue.fromNumber(1.0), JSValue.fromBool(true));
    map.deinit();
}

test "map: nested JSValue keys AND values are released recursively" {
    var map = try JSValue.newMap(testing.allocator);
    const key = try JSValue.newString(testing.allocator, "key");
    const value = try JSValue.newString(testing.allocator, "value");
    try map.map.value.set(key, value);
    // map now owns the only reference to both key and value; deinit() must
    // release both, or the leak detector catches it.
    map.deinit();
}

test "map: shared child value is released once per retain" {
    var inner = try JSValue.newString(testing.allocator, "shared");

    var outer = try JSValue.newMap(testing.allocator);
    try outer.map.value.set(JSValue.fromNumber(1.0), inner.retain());
    try outer.map.value.set(JSValue.fromNumber(2.0), inner.retain());

    // count: 1 (test's own `inner`) + 2 (two retained sets) = 3
    try testing.expectEqual(@as(usize, 3), inner.string.count);

    outer.deinit(); // releases both stored references: count 3 -> 1
    try testing.expectEqual(@as(usize, 1), inner.string.count);

    inner.deinit();
}

test "cloneMap retains every key and value" {
    var original = try JSValue.newMap(testing.allocator);
    const key = try JSValue.newString(testing.allocator, "k");
    const value = try JSValue.newString(testing.allocator, "v");
    try original.map.value.set(key, value);
    try testing.expectEqual(@as(usize, 1), key.string.count);
    try testing.expectEqual(@as(usize, 1), value.string.count);

    var copy = try original.cloneMap();

    try testing.expectEqual(@as(usize, 2), key.string.count);
    try testing.expectEqual(@as(usize, 2), value.string.count);

    original.deinit();
    try testing.expectEqual(@as(usize, 1), key.string.count);
    try testing.expectEqual(@as(usize, 1), value.string.count);

    copy.deinit();
}

test "map: JSValue keys use SameValueZero (NaN key equals itself)" {
    var map = try JSValue.newMap(testing.allocator);
    defer map.deinit();

    const nan_key = JSValue.fromNumber(std.math.nan(f64));
    try map.map.value.set(nan_key, JSValue.fromNumber(1.0));
    try testing.expect(map.map.value.has(JSValue.fromNumber(std.math.nan(f64))));
}

test "typeof a map is \"object\"" {
    var map = try JSValue.newMap(testing.allocator);
    defer map.deinit();
    try testing.expectEqualStrings("object", map.typeOf());
}

test "cloneMap: OOM mid-copy leaks nothing and leaves the source intact" {
    // Keys and values already copied are released when a later set() fails.
    // Same k-sweep as the constructor OOM tests, but only the clone's own
    // allocations fail: the source must come out untouched (its deinit
    // below must free everything, with no over- or under-retained child).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const src = try JSValue.newMap(a);
        try src.map.value.set(try JSValue.newString(a, "ka"), try JSValue.newString(a, "va"));
        try src.map.value.set(try JSValue.newString(a, "kb"), try JSValue.newString(a, "vb"));
        try src.map.value.set(try JSValue.newString(a, "kc"), try JSValue.newString(a, "vc"));
        try src.map.value.set(try JSValue.newString(a, "kd"), try JSValue.newString(a, "vd"));
        try src.map.value.set(try JSValue.newString(a, "ke"), try JSValue.newString(a, "ve"));
        fa.fail_index = fa.alloc_index + k;
        const c = src.cloneMap() catch |err| {
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
