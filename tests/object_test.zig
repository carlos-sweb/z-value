const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const FailingAllocator = std.testing.FailingAllocator;

test "object: set value types, deinit frees the object" {
    var obj = try JSValue.newObject(testing.allocator);
    try obj.object.value.set("age", JSValue.fromNumber(25.0));
    try obj.object.value.set("active", JSValue.fromBool(true));
    obj.deinit();
}

test "object: nested string property value is released recursively" {
    var obj = try JSValue.newObject(testing.allocator);
    const name = try JSValue.newString(testing.allocator, "carlos");
    try obj.object.value.set("name", name);
    obj.deinit(); // must release `name` too, or the leak detector catches it.
}

test "object: shared child value is released once per retain" {
    var shared = try JSValue.newObject(testing.allocator);
    try shared.object.value.set("k", JSValue.fromNumber(1.0));

    var container = try JSValue.newObject(testing.allocator);
    try container.object.value.set("a", shared.retain());
    try container.object.value.set("b", shared.retain());

    try testing.expectEqual(@as(usize, 3), shared.object.count); // test's own + 2 retains

    container.deinit();
    try testing.expectEqual(@as(usize, 1), shared.object.count);

    shared.deinit();
}

test "cloneObject retains every property value" {
    var original = try JSValue.newObject(testing.allocator);
    const child = try JSValue.newString(testing.allocator, "shared");
    try original.object.value.set("k", child);
    try testing.expectEqual(@as(usize, 1), child.string.count);

    var copy = try original.cloneObject();
    try testing.expectEqual(@as(usize, 2), child.string.count);

    original.deinit();
    try testing.expectEqual(@as(usize, 1), child.string.count);

    copy.deinit();
}

test "known gap: prototype is not reference-counted (documented, not asserted safe)" {
    var proto = try JSValue.newObject(testing.allocator);
    var child = try JSValue.newObject(testing.allocator);
    try child.object.value.setPrototype(&proto.object.value);

    // z-value does not retain/release `prototype` — it is a raw pointer
    // inherited from z-object with no lifetime management. The caller must
    // keep `proto` alive for at least as long as `child` references it as a
    // prototype. This test only demonstrates the *documented* ownership
    // contract, not a safety guarantee.
    child.deinit();
    proto.deinit();
}

test "cloneObject: OOM mid-copy leaks nothing and leaves the source intact" {
    // Values already copied are released when a later set() fails.
    // Same k-sweep as the constructor OOM tests, but only the clone's own
    // allocations fail: the source must come out untouched (its deinit
    // below must free everything, with no over- or under-retained child).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const src = try JSValue.newObject(a);
        try src.object.value.set("a", try JSValue.newString(a, "a"));
        try src.object.value.set("b", try JSValue.newString(a, "b"));
        try src.object.value.set("c", try JSValue.newString(a, "c"));
        try src.object.value.set("d", try JSValue.newString(a, "d"));
        try src.object.value.set("e", try JSValue.newString(a, "e"));
        fa.fail_index = fa.alloc_index + k;
        const c = src.cloneObject() catch |err| {
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
