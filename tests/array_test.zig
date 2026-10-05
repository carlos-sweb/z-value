const std = @import("std");
const testing = std.testing;
const JSValue = @import("zvalue").JSValue;
const FailingAllocator = std.testing.FailingAllocator;

test "array: push value types, deinit frees the array" {
    var arr = try JSValue.newArray(testing.allocator);
    try arr.array.value.items.append(testing.allocator, JSValue.fromNumber(1.0));
    try arr.array.value.items.append(testing.allocator, JSValue.fromBool(true));
    arr.deinit();
}

test "array: shared child array is released once per retain, not once per container" {
    var inner = try JSValue.newArray(testing.allocator);
    // one external reference kept by the test, plus two pushes into outer
    // (each push must retain, since inner is used again after each push).
    try inner.array.value.items.append(testing.allocator, JSValue.fromNumber(99.0));

    var outer = try JSValue.newArray(testing.allocator);
    try outer.array.value.items.append(testing.allocator, inner.retain());
    try outer.array.value.items.append(testing.allocator, inner.retain());

    // count: 1 (test's own `inner`) + 2 (two retained pushes) = 3
    try testing.expectEqual(@as(usize, 3), inner.array.count);

    outer.deinit(); // releases both pushed references: count 3 -> 1
    try testing.expectEqual(@as(usize, 1), inner.array.count);

    inner.deinit(); // the test's own reference: count 1 -> 0, actually freed
}

test "array: nested string children are released recursively" {
    var arr = try JSValue.newArray(testing.allocator);
    const s = try JSValue.newString(testing.allocator, "nested");
    try arr.array.value.items.append(testing.allocator, s);
    // arr now owns the only reference to s; arr.deinit() must release it too,
    // or std.testing.allocator's leak detector catches it.
    arr.deinit();
}

test "cloneArray retains every child (regression: ZArray.clone() alone would not)" {
    var original = try JSValue.newArray(testing.allocator);
    const child = try JSValue.newString(testing.allocator, "shared");
    try original.array.value.items.append(testing.allocator, child);
    // original now holds the only reference; child.count == 1.
    try testing.expectEqual(@as(usize, 1), child.string.count);

    var copy = try original.cloneArray();

    // cloneArray must have retained the shared child, so its count is now 2.
    try testing.expectEqual(@as(usize, 2), child.string.count);

    original.deinit();
    try testing.expectEqual(@as(usize, 1), child.string.count); // still alive via copy

    copy.deinit(); // drops the last reference, frees child
}

test "reference cycle leaks by design (documented, not a bug to fix here)" {
    var a = try JSValue.newArray(testing.allocator);
    try a.array.value.items.append(testing.allocator, a.retain()); // a contains itself
    try testing.expectEqual(@as(usize, 2), a.array.count);

    // Break the cycle manually so this test doesn't actually leak under
    // std.testing.allocator's leak detector: pop the self-reference back out
    // and release it before releasing the original handle.
    const self_ref = a.array.value.pop().?;
    self_ref.deinit();
    a.deinit();
}

test "cloneArray: OOM leaks nothing and leaves the source intact" {
    // Children are retained only once the clone can no longer fail.
    // Same k-sweep as the constructor OOM tests, but only the clone's own
    // allocations fail: the source must come out untouched (its deinit
    // below must free everything, with no over- or under-retained child).
    var k: usize = 0;
    while (true) : (k += 1) {
        var fa = FailingAllocator.init(testing.allocator, .{});
        const a = fa.allocator();
        const src = try JSValue.newArray(a);
        _ = try src.array.value.push(try JSValue.newString(a, "x"));
        _ = try src.array.value.push(try JSValue.newString(a, "y"));
        fa.fail_index = fa.alloc_index + k;
        const c = src.cloneArray() catch |err| {
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
