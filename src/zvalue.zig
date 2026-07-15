const std = @import("std");
const Allocator = std.mem.Allocator;

const zarray = @import("zarray");
const zobject = @import("zobject");
const zregexp = @import("zregexp");
const zstring = @import("zstring");
const zsymbol = @import("zsymbol");
const zmap = @import("zmap");
const zset = @import("zset");
const zerror = @import("zerror");
const zdate = @import("zdate");

pub const Rc = @import("rc.zig").Rc;
pub const equality = @import("equality.zig");
pub const ZValueError = @import("errors.zig").ZValueError;
pub const Callable = @import("callable.zig").Callable;

const ZArray = zarray.ZArray;
const ZObject = zobject.ZObject;
const Regex = zregexp.Regex;
const ZString = zstring.ZString;
const ZSymbol = zsymbol.ZSymbol;
const ZMap = zmap.ZMap;
const ZSet = zset.ZSet;
const ZError = zerror.ZError;
pub const ErrorKind = zerror.ErrorKind;
pub const ZDate = zdate.ZDate;

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
    string: *Rc(ZString),
    array: *Rc(ZArray(JSValue)),
    object: *Rc(ZObject(JSValue)),
    regex: *Rc(Regex),
    symbol: *Rc(ZSymbol),
    map: *Rc(ZMap(JSValue, JSValue)),
    set: *Rc(ZSet(JSValue)),
    @"error": *Rc(ZError(JSValue)),
    function: *Rc(Callable),
    date: *Rc(ZDate),

    pub const UNDEFINED: JSValue = .{ .@"undefined" = {} };
    pub const NULL: JSValue = .{ .@"null" = {} };

    pub fn fromBool(value: bool) JSValue {
        return .{ .boolean = value };
    }

    pub fn fromNumber(value: f64) JSValue {
        return .{ .number = value };
    }

    pub fn newString(allocator: Allocator, content: []const u8) !JSValue {
        // Always owned (initOwned, never the borrowed-mode init()) — a
        // borrowed ZString's deinit() is a no-op, which would silently break
        // the Rc(T) refcounting contract (the box would "free" without
        // actually freeing anything).
        const str = try ZString.initOwned(allocator, content);
        return .{ .string = try Rc(ZString).create(allocator, str) };
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

    /// Every call produces a brand-new, always-unique symbol — even with an
    /// identical description, it never equals a previously created one (see
    /// equality.zig: symbols compare by Rc box identity). Uses
    /// ZSymbol.init() (a value, not create()'s own heap allocation) since
    /// the Rc box itself is the symbol's one true heap allocation.
    pub fn newSymbol(allocator: Allocator, description: ?[]const u8) !JSValue {
        const sym = try ZSymbol.init(allocator, description);
        return .{ .symbol = try Rc(ZSymbol).create(allocator, sym) };
    }

    pub fn newMap(allocator: Allocator) !JSValue {
        const m = ZMap(JSValue, JSValue).init(allocator);
        return .{ .map = try Rc(ZMap(JSValue, JSValue)).create(allocator, m) };
    }

    pub fn newSet(allocator: Allocator) !JSValue {
        const s = ZSet(JSValue).init(allocator);
        return .{ .set = try Rc(ZSet(JSValue)).create(allocator, s) };
    }

    /// Errors are objects in JS (typeOf() below reports "object", not
    /// "error") but get their own JSValue variant for cheap identity
    /// comparison and type-safe dispatch (e.g. an interpreter's catch-clause
    /// matching), same rationale as symbol/map/set each getting their own
    /// variant instead of being represented as plain `.object` values.
    pub fn newError(allocator: Allocator, kind: ErrorKind, message: []const u8) !JSValue {
        const err = try ZError(JSValue).init(allocator, kind, message);
        return .{ .@"error" = try Rc(ZError(JSValue)).create(allocator, err) };
    }

    /// AggregateError. Like arr.push()/map.set(), this does NOT retain
    /// `errs` for you — ZError(JSValue).initAggregate() only byte-copies the
    /// slice (same shallow-copy shape as ZArray.clone(), see the
    /// OWNERSHIP RULE at the top of this file). If you still need your own
    /// copy of a value after this call, retain() it yourself first:
    /// `newAggregateError(alloc, "msg", &.{ a.retain(), b.retain() })`.
    pub fn newAggregateError(allocator: Allocator, message: []const u8, errs: []const JSValue) !JSValue {
        const err = try ZError(JSValue).initAggregate(allocator, message, errs);
        return .{ .@"error" = try Rc(ZError(JSValue)).create(allocator, err) };
    }

    /// Wraps a native or user-defined `Callable` (see callable.zig) as a
    /// JSValue -- functions are first-class values in JS: they can be
    /// stored in variables/properties/arrays and compared by identity.
    pub fn newFunction(allocator: Allocator, callable: Callable) !JSValue {
        return .{ .function = try Rc(Callable).create(allocator, callable) };
    }

    /// A Date from milliseconds since the Unix epoch. Out-of-range values
    /// become z-date's INVALID_TIME (the "Invalid Date" state), matching
    /// the real Date constructor.
    pub fn newDate(allocator: Allocator, ms: i64) !JSValue {
        return .{ .date = try Rc(ZDate).create(allocator, ZDate.fromTimestamp(ms)) };
    }

    /// ECMAScript `typeof` operator. Note the famous spec quirk:
    /// typeof null === "object", not "null". Arrays/objects/regexes/maps/sets
    /// are all typeof "object" too — only functions get their own "function"
    /// result, everything else heap-boxed is "object".
    pub fn typeOf(self: JSValue) []const u8 {
        return switch (self) {
            .@"undefined" => "undefined",
            .@"null" => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .function => "function",
            .array, .object, .regex, .map, .set, .@"error", .date => "object",
        };
    }

    /// Duck-typed hook picked up by zequality's generic strictEquals/hash
    /// machinery (see z-equality's `hasCustomEql`/`containerEquals`) so that
    /// `ZMap(JSValue, JSValue)`/`ZSet(JSValue)` — which delegate their key
    /// comparison to `zequality.sameValueZero(K, ...)` — work at all. Uses
    /// SameValueZero specifically (not strictEquals) because that's the
    /// ECMA-262 Map/Set key-comparison algorithm, and it's the only consumer
    /// of this method today.
    pub fn eql(a: JSValue, b: JSValue) bool {
        return @import("equality.zig").sameValueZero(a, b);
    }

    /// Pairs with eql() above for the same duck-typing contract (equal
    /// values must hash equally — required together or zequality raises a
    /// compile error).
    pub fn hash(self: JSValue) u64 {
        return @import("equality.zig").hash(self);
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
            .symbol => |box| _ = box.retain(),
            .map => |box| _ = box.retain(),
            .set => |box| _ = box.retain(),
            .@"error" => |box| _ = box.retain(),
            .function => |box| _ = box.retain(),
            .date => |box| _ = box.retain(),
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
                    for (box.value.properties.values()) |prop| prop.value.deinit();
                    box.value.deinit();
                    box.destroy();
                }
            },
            .symbol => |box| {
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .map => |box| {
                if (box.decref()) {
                    // Unlike ZObject (String-keyed), Map keys are arbitrary
                    // JSValues too — both sides need releasing.
                    for (box.value.keys()) |*key| key.deinit();
                    for (box.value.values()) |*value| value.deinit();
                    box.value.deinit();
                    box.destroy();
                }
            },
            .set => |box| {
                if (box.decref()) {
                    for (box.value.values()) |*value| value.deinit();
                    box.value.deinit();
                    box.destroy();
                }
            },
            .@"error" => |box| {
                if (box.decref()) {
                    // AggregateError's errors slice holds JSValues too (only
                    // non-null for .aggregate_error; a no-op loop otherwise).
                    if (box.value.errors) |errs| {
                        for (errs) |*e| e.deinit();
                    }
                    box.value.deinit();
                    box.destroy();
                }
            },
            .function => |box| {
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            // ZDate is a pure 8-byte value (no allocator stored, no
            // deinit of its own) -- only the Rc box itself needs freeing.
            .date => |box| {
                if (box.decref()) {
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

    /// Rc-aware duplicate of a `.map` JSValue: retains every key AND every
    /// value (Map keys are JSValues too, unlike ZObject's plain-string
    /// keys), analogous to cloneArray()/cloneObject(). ZMap has no
    /// clone()/shallow-copy method to accidentally misuse directly, unlike
    /// ZArray/ZObject — but this still keeps the same Rc-aware-duplicate
    /// naming convention for consistency.
    pub fn cloneMap(self: JSValue) !JSValue {
        const box = self.map;
        var new_map = ZMap(JSValue, JSValue).init(box.allocator);
        errdefer new_map.deinit();

        const pairs = try box.value.entries(box.allocator);
        defer box.allocator.free(pairs);
        for (pairs) |pair| {
            try new_map.set(pair.key.retain(), pair.value.retain());
        }

        return .{ .map = try Rc(ZMap(JSValue, JSValue)).create(box.allocator, new_map) };
    }

    /// Rc-aware duplicate of a `.set` JSValue: retains every value.
    pub fn cloneSet(self: JSValue) !JSValue {
        const box = self.set;
        var new_set = ZSet(JSValue).init(box.allocator);
        errdefer new_set.deinit();

        for (box.value.values()) |value| {
            try new_set.add(value.retain());
        }

        return .{ .set = try Rc(ZSet(JSValue)).create(box.allocator, new_set) };
    }

    /// Rc-aware duplicate of a `.error` JSValue: for AggregateError, retains
    /// every JSValue in `errors` (analogous to cloneArray()/cloneSet()) —
    /// ZError(JSValue).initAggregate() only byte-copies the slice it's given,
    /// it does not retain on its own.
    pub fn cloneError(self: JSValue) !JSValue {
        const box = self.@"error";
        var new_err: ZError(JSValue) = undefined;
        if (box.value.errors) |errs| {
            const retained = try box.allocator.alloc(JSValue, errs.len);
            defer box.allocator.free(retained);
            for (errs, 0..) |e, i| retained[i] = e.retain();
            new_err = try ZError(JSValue).initAggregate(box.allocator, box.value.message, retained);
        } else {
            new_err = try ZError(JSValue).init(box.allocator, box.value.kind, box.value.message);
        }
        return .{ .@"error" = try Rc(ZError(JSValue)).create(box.allocator, new_err) };
    }
};
