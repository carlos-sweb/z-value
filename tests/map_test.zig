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
    try testing.expectEqual(@as(usize, 3), inner.string.refCount());

    outer.deinit(); // releases both stored references: count 3 -> 1
    try testing.expectEqual(@as(usize, 1), inner.string.refCount());

    inner.deinit();
}

test "cloneMap retains every key and value" {
    var original = try JSValue.newMap(testing.allocator);
    const key = try JSValue.newString(testing.allocator, "k");
    const value = try JSValue.newString(testing.allocator, "v");
    try original.map.value.set(key, value);
    try testing.expectEqual(@as(usize, 1), key.string.refCount());
    try testing.expectEqual(@as(usize, 1), value.string.refCount());

    var copy = try original.cloneMap();

    try testing.expectEqual(@as(usize, 2), key.string.refCount());
    try testing.expectEqual(@as(usize, 2), value.string.refCount());

    original.deinit();
    try testing.expectEqual(@as(usize, 1), key.string.refCount());
    try testing.expectEqual(@as(usize, 1), value.string.refCount());

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

test "map: releasing a 100 000-deep chain (map as key and as value) does not overflow the stack" {
    var cur = JSValue.NULL;
    for (0..100_000) |i| {
        const outer = try JSValue.newMap(testing.allocator);
        if (i % 2 == 0) {
            try outer.map.value.set(cur, JSValue.UNDEFINED);
        } else {
            try outer.map.value.set(JSValue.fromNumber(0), cur);
        }
        cur = outer;
    }
    cur.deinit();
}

// ---- Rc-aware mutation wrappers -----------------------------------------

test "mapSet: new key, replacement keeps the stored key and position, releases old value and incoming key" {
    const a = testing.allocator;
    const m = try JSValue.newMap(a);
    defer m.deinit();

    try m.mapSet(try JSValue.newString(a, "k1"), try JSValue.newString(a, "v1"));
    try m.mapSet(try JSValue.newString(a, "k2"), try JSValue.newString(a, "v2"));
    const stored_k1 = m.map.value.keys()[0];
    // An equal key in a different box: stored key kept, incoming key and
    // old value released (the testing allocator reports any leak).
    try m.mapSet(try JSValue.newString(a, "k1"), try JSValue.newString(a, "v1b"));
    try testing.expectEqual(@as(usize, 2), m.map.value.size());
    try testing.expect(m.map.value.keys()[0].string == stored_k1.string); // same box, same position
    try testing.expectEqualStrings("v1b", m.map.value.values()[0].string.value.data);
}

test "mapSet: the same key box and the same value box keep counts balanced" {
    const a = testing.allocator;
    const m = try JSValue.newMap(a);
    defer m.deinit();
    const k = try JSValue.newString(a, "k");
    const v = try JSValue.newString(a, "v");
    try m.mapSet(k, v); // map owns both now (count 1 each)
    try m.mapSet(k.retain(), v.retain());
    try testing.expectEqual(@as(usize, 1), k.string.refCount());
    try testing.expectEqual(@as(usize, 1), v.string.refCount());
    try testing.expectEqual(@as(usize, 1), m.map.value.size());
}

test "mapSet: out of memory consumes key and value, nothing leaks" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const m = try JSValue.newMap(a);
    const k = try JSValue.newString(a, "k");
    const v = try JSValue.newString(a, "v");
    fa.fail_index = fa.alloc_index; // the map's first storage allocation fails
    try testing.expectError(error.OutOfMemory, m.mapSet(k, v));
    fa.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(@as(usize, 0), m.map.value.size());
    m.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "mapDelete: releases the STORED key (an equal key in another box) and the value" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const m = try JSValue.newMap(a);
    try m.mapSet(try JSValue.newString(a, "k"), try JSValue.newString(a, "v"));
    const lookup = try JSValue.newString(a, "k"); // equal, different box
    try testing.expect(m.mapDelete(lookup));
    try testing.expect(!m.mapDelete(lookup));
    try testing.expectEqual(@as(usize, 1), lookup.string.refCount()); // not consumed
    lookup.deinit();
    m.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "mapClear: releases every key and value" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const m = try JSValue.newMap(a);
    for (0..5) |i| try m.mapSet(JSValue.fromNumber(@floatFromInt(i)), try JSValue.newString(a, "v"));
    try m.mapSet(try JSValue.newArray(a), try JSValue.newObject(a));
    m.mapClear();
    try testing.expectEqual(@as(usize, 0), m.map.value.size());
    m.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}
