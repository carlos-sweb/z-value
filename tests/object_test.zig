const std = @import("std");
const testing = std.testing;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const FailingAllocator = std.testing.FailingAllocator;

test "object: set value types, deinit frees the object" {
    var obj = try JSValue.newObject(testing.allocator);
    try obj.asObject().value.set("age", JSValue.fromNumber(25.0));
    try obj.asObject().value.set("active", JSValue.fromBool(true));
    obj.deinit();
}

test "object: nested string property value is released recursively" {
    var obj = try JSValue.newObject(testing.allocator);
    const name = try JSValue.newString(testing.allocator, "carlos");
    try obj.asObject().value.set("name", name);
    obj.deinit(); // must release `name` too, or the leak detector catches it.
}

test "object: shared child value is released once per retain" {
    var shared = try JSValue.newObject(testing.allocator);
    try shared.asObject().value.set("k", JSValue.fromNumber(1.0));

    var container = try JSValue.newObject(testing.allocator);
    try container.asObject().value.set("a", shared.retain());
    try container.asObject().value.set("b", shared.retain());

    try testing.expectEqual(@as(usize, 3), shared.asObject().refCount()); // test's own + 2 retains

    container.deinit();
    try testing.expectEqual(@as(usize, 1), shared.asObject().refCount());

    shared.deinit();
}

test "cloneObject retains every property value" {
    var original = try JSValue.newObject(testing.allocator);
    const child = try JSValue.newString(testing.allocator, "shared");
    try original.asObject().value.set("k", child);
    try testing.expectEqual(@as(usize, 1), child.asString().refCount());

    var copy = try original.cloneObject();
    try testing.expectEqual(@as(usize, 2), child.asString().refCount());

    original.deinit();
    try testing.expectEqual(@as(usize, 1), child.asString().refCount());

    copy.deinit();
}

test "known gap: prototype is not reference-counted (documented, not asserted safe)" {
    var proto = try JSValue.newObject(testing.allocator);
    var child = try JSValue.newObject(testing.allocator);
    try child.asObject().value.setPrototype(&proto.asObject().value);

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
        try src.asObject().value.set("a", try JSValue.newString(a, "a"));
        try src.asObject().value.set("b", try JSValue.newString(a, "b"));
        try src.asObject().value.set("c", try JSValue.newString(a, "c"));
        try src.asObject().value.set("d", try JSValue.newString(a, "d"));
        try src.asObject().value.set("e", try JSValue.newString(a, "e"));
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

test "object: releasing a 100 000-deep property chain does not overflow the stack" {
    var cur = JSValue.NULL;
    for (0..100_000) |_| {
        const outer = try JSValue.newObject(testing.allocator);
        try outer.asObject().value.set("next", cur);
        cur = outer;
    }
    cur.deinit();
}

// ---- Rc-aware mutation wrappers -----------------------------------------

test "objectSet: new key, replacement and same box keep counts balanced" {
    const a = testing.allocator;
    const o = try JSValue.newObject(a);
    defer o.deinit();

    try o.objectSet("x", try JSValue.newString(a, "first"));
    // Replacement releases "first" (the testing allocator reports it otherwise).
    try o.objectSet("x", try JSValue.newString(a, "second"));
    try testing.expectEqualStrings("second", o.asObject().value.get("x").?.asString().value.data);

    // Same box: `o.x = o.x` -- store first, release after, never hits zero.
    const cur = o.asObject().value.get("x").?;
    try testing.expectEqual(@as(usize, 1), cur.asString().refCount());
    try o.objectSet("x", cur.retain());
    try testing.expectEqual(@as(usize, 1), cur.asString().refCount());
    try testing.expectEqualStrings("second", o.asObject().value.get("x").?.asString().value.data);
}

test "objectSet: replacing an accessor releases its getter and setter" {
    const a = testing.allocator;
    const o = try JSValue.newObject(a);
    defer o.deinit();
    try o.asObject().value.defineAccessor("acc", try JSValue.newString(a, "getter"), try JSValue.newString(a, "setter"), JSValue.UNDEFINED);
    try o.objectSet("acc", JSValue.fromNumber(1));
    const rec = o.asObject().value.getOwnRecord("acc").?;
    try testing.expect(!rec.isAccessor());
    try testing.expectEqual(@as(f64, 1), rec.value.asNumber());
}

test "objectSet: a refused set (frozen) consumes the value and leaves the object unchanged" {
    const a = testing.allocator;
    const o = try JSValue.newObject(a);
    defer o.deinit();
    try o.objectSet("x", try JSValue.newString(a, "kept"));
    o.asObject().value.freeze();
    try testing.expectError(error.ObjectIsFrozen, o.objectSet("x", try JSValue.newString(a, "dropped")));
    try testing.expectEqualStrings("kept", o.asObject().value.get("x").?.asString().value.data);
}

test "objectSet: out of memory consumes the value, nothing leaks" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const o = try JSValue.newObject(a);
    const v = try JSValue.newString(a, "value");
    fa.fail_index = fa.alloc_index; // the next allocation (the new key) fails
    try testing.expectError(error.OutOfMemory, o.objectSet("new", v));
    fa.fail_index = std.math.maxInt(usize);
    try testing.expect(o.asObject().value.getOwn("new") == null);
    o.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "objectSet: assign then replace then deinit leaks nothing (byte count)" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const o = try JSValue.newObject(a);
    try o.objectSet("k", try JSValue.newString(a, "one"));
    try o.objectSet("k", try JSValue.newString(a, "two"));
    try o.objectSet("k", try JSValue.newArray(a));
    o.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "objectDefine: replaces a value, turns an accessor into data, same box, refusal" {
    const a = testing.allocator;
    const o = try JSValue.newObject(a);
    defer o.deinit();
    const data: zvalue.PropertyDescriptor = .{ .writable = true, .enumerable = true, .configurable = true };

    try o.objectDefine("x", try JSValue.newString(a, "first"), data);
    try o.objectDefine("x", try JSValue.newString(a, "second"), data);
    try testing.expectEqualStrings("second", o.asObject().value.get("x").?.asString().value.data);

    // Over an accessor: slots cleared and released.
    try o.asObject().value.defineAccessor("acc", try JSValue.newString(a, "getter"), null, JSValue.UNDEFINED);
    try o.objectDefine("acc", JSValue.fromNumber(2), data);
    try testing.expect(!o.asObject().value.getOwnRecord("acc").?.isAccessor());

    // Same box.
    const cur = o.asObject().value.get("x").?;
    try o.objectDefine("x", cur.retain(), data);
    try testing.expectEqual(@as(usize, 1), cur.asString().refCount());

    // Refusal: redefining a non-configurable property consumes the value.
    try o.objectDefine("fixed", try JSValue.newString(a, "kept"), .{ .writable = false, .enumerable = true, .configurable = false });
    try testing.expectError(error.PropertyNotConfigurable, o.objectDefine("fixed", try JSValue.newString(a, "dropped"), data));
    try testing.expectEqualStrings("kept", o.asObject().value.get("fixed").?.asString().value.data);
}

test "objectDefine: out of memory consumes the value, nothing leaks" {
    var fa = FailingAllocator.init(testing.allocator, .{});
    const a = fa.allocator();
    const o = try JSValue.newObject(a);
    const v = try JSValue.newString(a, "value");
    fa.fail_index = fa.alloc_index;
    try testing.expectError(error.OutOfMemory, o.objectDefine("new", v, .{ .writable = true, .enumerable = true, .configurable = true }));
    fa.fail_index = std.math.maxInt(usize);
    o.deinit();
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
}

test "objectDelete: releases the removed value and accessor slots; refusal releases nothing" {
    const a = testing.allocator;
    const o = try JSValue.newObject(a);
    defer o.deinit();
    try o.objectSet("x", try JSValue.newString(a, "gone"));
    try o.asObject().value.defineAccessor("acc", try JSValue.newString(a, "g"), try JSValue.newString(a, "s"), JSValue.UNDEFINED);
    try testing.expect(try o.objectDelete("x"));
    try testing.expect(try o.objectDelete("acc"));
    try testing.expect(!try o.objectDelete("x"));
    try testing.expectEqual(@as(usize, 0), o.asObject().value.size());

    try o.objectSet("y", try JSValue.newString(a, "stays"));
    o.asObject().value.freeze();
    try testing.expectError(error.ObjectIsFrozen, o.objectDelete("y"));
    try testing.expectEqualStrings("stays", o.asObject().value.get("y").?.asString().value.data);
}

test "objectClear: releases every value; a refused clear releases nothing" {
    const a = testing.allocator;
    const o = try JSValue.newObject(a);
    defer o.deinit();
    try o.objectSet("a", try JSValue.newString(a, "1"));
    try o.objectSet("b", try JSValue.newArray(a));
    try o.asObject().value.defineAccessor("c", try JSValue.newString(a, "g"), null, JSValue.UNDEFINED);
    try o.objectClear();
    try testing.expectEqual(@as(usize, 0), o.asObject().value.size());

    try o.objectSet("a", try JSValue.newString(a, "kept"));
    try o.objectDefine("fixed", try JSValue.newString(a, "kept too"), .{ .writable = true, .enumerable = true, .configurable = false });
    try testing.expectError(error.PropertyNotConfigurable, o.objectClear());
    try testing.expectEqualStrings("kept", o.asObject().value.get("a").?.asString().value.data);
    o.asObject().value.freeze();
    try testing.expectError(error.ObjectIsFrozen, o.objectClear());
    try testing.expectEqual(@as(usize, 2), o.asObject().value.size());
}
