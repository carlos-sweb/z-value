const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const FailingAllocator = std.testing.FailingAllocator;

test "set: add value types, deinit frees the set" {
    var set = try JSValue.newSet(testing.allocator);
    try set.set.value.add(JSValue.fromNumber(1.0));
    set.deinit();
}

test "set: nested string values are released recursively" {
    var set = try JSValue.newSet(testing.allocator);
    const s = try JSValue.newString(testing.allocator, "nested");
    try set.set.value.add(s);
    set.deinit(); // must release `s` too, or the leak detector catches it.
}

test "set: shared value is released once per retain" {
    var inner = try JSValue.newArray(testing.allocator);

    var outer = try JSValue.newSet(testing.allocator);
    try outer.set.value.add(inner.retain());

    try testing.expectEqual(@as(usize, 2), inner.array.refCount()); // test's own + 1 retained add

    outer.deinit();
    try testing.expectEqual(@as(usize, 1), inner.array.refCount());

    inner.deinit();
}

test "cloneSet retains every value" {
    var original = try JSValue.newSet(testing.allocator);
    const child = try JSValue.newString(testing.allocator, "shared");
    try original.set.value.add(child);
    try testing.expectEqual(@as(usize, 1), child.string.refCount());

    var copy = try original.cloneSet();
    try testing.expectEqual(@as(usize, 2), child.string.refCount());

    original.deinit();
    try testing.expectEqual(@as(usize, 1), child.string.refCount());

    copy.deinit();
}

test "set: JSValue values use SameValueZero (adding NaN twice is a no-op)" {
    var set = try JSValue.newSet(testing.allocator);
    defer set.deinit();

    try set.set.value.add(JSValue.fromNumber(std.math.nan(f64)));
    try set.set.value.add(JSValue.fromNumber(std.math.nan(f64)));
    try testing.expectEqual(@as(usize, 1), set.set.value.size());
}

test "typeof a set is \"object\"" {
    var set = try JSValue.newSet(testing.allocator);
    defer set.deinit();
    try testing.expectEqualStrings("object", set.typeOf());
}

test "cloneSet: OOM mid-copy leaks nothing and leaves the source intact" {
    // Values already copied are released when a later add() fails.
    // Same k-sweep as the constructor OOM tests, but only the clone's own
    // allocations fail: the source must come out untouched (its deinit
    // below must free everything, with no over- or under-retained child).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const src = try JSValue.newSet(a);
        try src.set.value.add(try JSValue.newString(a, "a"));
        try src.set.value.add(try JSValue.newString(a, "b"));
        try src.set.value.add(try JSValue.newString(a, "c"));
        try src.set.value.add(try JSValue.newString(a, "d"));
        try src.set.value.add(try JSValue.newString(a, "e"));
        fa.fail_index = fa.alloc_index + k;
        const c = src.cloneSet() catch |err| {
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

test "set: releasing a 100 000-deep nested set does not overflow the stack" {
    var cur = JSValue.NULL;
    for (0..100_000) |_| {
        const outer = try JSValue.newSet(testing.allocator);
        try outer.set.value.add(cur);
        cur = outer;
    }
    cur.deinit();
}

// ---- Rc-aware mutation wrappers -----------------------------------------

test "setAdd: a new value is stored; an equal value in another box is released" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const s = try JSValue.newSet(a);
    try s.setAdd(try JSValue.newString(a, "x"));
    const stored = s.set.value.values()[0];
    try s.setAdd(try JSValue.newString(a, "x")); // equal, different box: released
    try testing.expectEqual(@as(usize, 1), s.set.value.size());
    try testing.expect(s.set.value.values()[0].string == stored.string);
    s.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "setAdd: the same box keeps its count balanced" {
    const a = testing.allocator;
    const s = try JSValue.newSet(a);
    defer s.deinit();
    const v = try JSValue.newString(a, "x");
    try s.setAdd(v);
    try s.setAdd(v.retain());
    try testing.expectEqual(@as(usize, 1), v.string.refCount());
    try testing.expectEqual(@as(usize, 1), s.set.value.size());
}

test "setAdd: out of memory consumes the value, nothing leaks" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const s = try JSValue.newSet(a);
    const v = try JSValue.newString(a, "x");
    fa.fail_index = fa.alloc_index;
    try testing.expectError(error.OutOfMemory, s.setAdd(v));
    fa.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(@as(usize, 0), s.set.value.size());
    s.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "setDelete: releases the STORED element; the lookup value is not consumed" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const s = try JSValue.newSet(a);
    try s.setAdd(try JSValue.newString(a, "x"));
    const lookup = try JSValue.newString(a, "x");
    try testing.expect(s.setDelete(lookup));
    try testing.expect(!s.setDelete(lookup));
    try testing.expectEqual(@as(usize, 1), lookup.string.refCount());
    lookup.deinit();
    s.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "setClear: releases every element" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const s = try JSValue.newSet(a);
    try s.setAdd(try JSValue.newString(a, "a"));
    try s.setAdd(try JSValue.newArray(a));
    try s.setAdd(JSValue.fromNumber(1));
    s.setClear();
    try testing.expectEqual(@as(usize, 0), s.set.value.size());
    s.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}
