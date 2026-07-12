const std = @import("std");
const Allocator = std.mem.Allocator;

const zarray = @import("zarray");
const zobject = @import("zobject");
const zregexp = @import("zregexp");

pub const Rc = @import("rc.zig").Rc;
pub const RawString = @import("raw_string.zig").RawString;
pub const equality = @import("equality.zig");
pub const ZValueError = @import("errors.zig").ZValueError;

const ZArray = zarray.ZArray;
const ZObject = zobject.ZObject;
const Regex = zregexp.Regex;

/// A JS value: undefined/null/boolean/number are inline (trivially copyable
/// bits); string/array/object/regex are heap-owning and live behind a
/// pointer to a reference-counted box (see Rc(T) in rc.zig), never embedded
/// by value, because:
///   - array/object/regex have *identity* semantics in JS (two distinct
///     objects are never `===`, even with identical content).
///   - it keeps @sizeOf(JSValue) small so copying a JSValue is O(1)
///     regardless of how large the array/object behind it is.
///
/// OWNERSHIP RULE (Zig has no copy constructors, so this is convention, not
/// compiler-enforced): copying a JSValue by assignment does NOT touch the
/// refcount. Call `retain()` explicitly whenever a copy needs to outlive the
/// original binding (e.g. storing a JSValue into a second container), and
/// call `deinit()` exactly once per retained/owned reference when done.
/// `ZArray(JSValue).clone()` / `ZObject(JSValue)`'s property-copy helpers are
/// shallow (byte copies) and do NOT retain their elements — never call them
/// directly on `T = JSValue`; use `cloneArray()`/`cloneObject()` below.
pub const JSValue = union(enum) {
    @"undefined": void,
    @"null": void,
    boolean: bool,
    number: f64,
    string: *Rc(RawString),
    array: *Rc(ZArray(JSValue)),
    object: *Rc(ZObject(JSValue)),
    regex: *Rc(Regex),

    pub const UNDEFINED: JSValue = .{ .@"undefined" = {} };
    pub const NULL: JSValue = .{ .@"null" = {} };

    pub fn fromBool(value: bool) JSValue {
        return .{ .boolean = value };
    }

    pub fn fromNumber(value: f64) JSValue {
        return .{ .number = value };
    }

    pub fn newString(allocator: Allocator, content: []const u8) !JSValue {
        const raw = try RawString.init(allocator, content);
        return .{ .string = try Rc(RawString).create(allocator, raw) };
    }

    pub fn newArray(allocator: Allocator) !JSValue {
        const arr = ZArray(JSValue).init(allocator);
        return .{ .array = try Rc(ZArray(JSValue)).create(allocator, arr) };
    }

    pub fn newObject(allocator: Allocator) !JSValue {
        const obj = ZObject(JSValue).init(allocator);
        return .{ .object = try Rc(ZObject(JSValue)).create(allocator, obj) };
    }

    /// Takes ownership of an already-compiled Regex (e.g. from
    /// `zregexp.Regex.compile()`).
    pub fn fromRegex(allocator: Allocator, re: Regex) !JSValue {
        return .{ .regex = try Rc(Regex).create(allocator, re) };
    }

    /// ECMAScript `typeof` operator. Note the famous spec quirk:
    /// typeof null === "object", not "null". Arrays/objects/regexes are all
    /// typeof "object" too — only functions (not modeled yet) are "function".
    pub fn typeOf(self: JSValue) []const u8 {
        return switch (self) {
            .@"undefined" => "undefined",
            .@"null" => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .array, .object, .regex => "object",
        };
    }

    /// Increments the refcount of the underlying box, if any (no-op for
    /// inline value types). Returns self so call sites can chain, e.g.
    /// `arr.push(child.retain())`.
    pub fn retain(self: JSValue) JSValue {
        switch (self) {
            .@"undefined", .@"null", .boolean, .number => {},
            .string => |box| _ = box.retain(),
            .array => |box| _ = box.retain(),
            .object => |box| _ = box.retain(),
            .regex => |box| _ = box.retain(),
        }
        return self;
    }

    /// Releases this reference. When the underlying box's refcount reaches
    /// zero, tears down the wrapped value (recursively releasing any nested
    /// JSValues first) and frees the box.
    ///
    /// KNOWN GAP: ZObject(JSValue).prototype is a raw `?*Self` inherited from
    /// z-object with no lifetime management of its own — it is not retained
    /// or released here. If a prototype object is freed while another object
    /// still points to it as a prototype, that pointer dangles. z-object
    /// would need to become Rc-aware for this to be handled automatically;
    /// out of scope for this version.
    ///
    /// KNOWN GAP: reference cycles (e.g. an array pushing a JSValue that
    /// refers back to itself) never reach refcount zero and leak by design —
    /// there is no cycle collector in this version.
    pub fn deinit(self: JSValue) void {
        switch (self) {
            .@"undefined", .@"null", .boolean, .number => {},
            .string => |box| {
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .regex => |box| {
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .array => |box| {
                if (box.decref()) {
                    for (box.value.toSliceMut()) |*child| child.deinit();
                    box.value.deinit();
                    box.destroy();
                }
            },
            .object => |box| {
                if (box.decref()) {
                    var it = box.value.properties.valueIterator();
                    while (it.next()) |prop| prop.value.deinit();
                    box.value.deinit();
                    box.destroy();
                }
            },
        }
    }

    /// Rc-aware duplicate of a `.array` JSValue: unlike `ZArray(JSValue).clone()`
    /// (a shallow byte-copy that does NOT retain its elements — never call it
    /// directly on `T = JSValue`), this retains every child element so the
    /// two arrays can each be independently deinit()'d without double-freeing
    /// shared children.
    pub fn cloneArray(self: JSValue) !JSValue {
        const box = self.array;
        var new_arr = try box.value.clone();
        errdefer new_arr.deinit();
        for (new_arr.toSliceMut()) |*child| _ = child.retain();
        return .{ .array = try Rc(ZArray(JSValue)).create(box.allocator, new_arr) };
    }

    /// Rc-aware duplicate of a `.object` JSValue: retains every property
    /// value, analogous to cloneArray(). Does NOT copy the prototype pointer
    /// (see the KNOWN GAP note on deinit()) beyond whatever raw pointer copy
    /// ZObject's own property storage performs.
    pub fn cloneObject(self: JSValue) !JSValue {
        const box = self.object;
        var new_obj = ZObject(JSValue).init(box.allocator);
        errdefer new_obj.deinit();

        const keys = try box.value.keys(box.allocator);
        defer box.allocator.free(keys);
        for (keys) |key| {
            const value = box.value.get(key).?;
            try new_obj.set(key, value.retain());
        }

        return .{ .object = try Rc(ZObject(JSValue)).create(box.allocator, new_obj) };
    }
};
