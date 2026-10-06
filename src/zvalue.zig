const std = @import("std");
const Allocator = std.mem.Allocator;

const zarray = @import("zarray");
const zobject = @import("zobject");
const zregex = @import("zregex");
const zstring = @import("zstring");
const zsymbol = @import("zsymbol");
const zmap = @import("zmap");
const zset = @import("zset");
const zerror = @import("zerror");
const zdate = @import("zdate");
const zpromise = @import("zpromise");
const zbigint = @import("zbigint");
const zbuffer = @import("zbuffer");
const ztemporal_value = @import("temporal_value.zig");

pub const Rc = @import("rc.zig").Rc;
pub const equality = @import("equality.zig");
pub const ZValueError = @import("errors.zig").ZValueError;
pub const Callable = @import("callable.zig").Callable;
pub const Proxy = @import("proxy.zig").Proxy;
pub const DataViewBox = @import("data_view_box.zig").DataViewBox;
pub const TypedArrayBox = @import("typed_array_box.zig").TypedArrayBox;
pub const TypedKind = @import("typed_array_box.zig").TypedKind;

const ZArray = zarray.ZArray;
const ZObject = zobject.ZObject;
const Regex = zregex.Regex;
const ZString = zstring.ZString;
const ZSymbol = zsymbol.ZSymbol;
const ZMap = zmap.ZMap;
const ZSet = zset.ZSet;
const ZError = zerror.ZError;
pub const ErrorKind = zerror.ErrorKind;
pub const ZDate = zdate.ZDate;
pub const ZPromise = zpromise.ZPromise;
pub const PromiseState = zpromise.State;
pub const ZBigInt = zbigint.ZBigInt;
pub const BigIntError = zbigint.BigIntError;
pub const ArrayBuffer = zbuffer.ArrayBuffer;
pub const BufferError = zbuffer.BufferError;
pub const TemporalValue = ztemporal_value.TemporalValue;
/// Re-exported for embedders implementing Object.defineProperty over
/// ZObject records.
pub const PropertyDescriptor = zobject.PropertyDescriptor;
/// Re-exported for the Rc-aware object mutators (`objectSet` and friends).
pub const ZObjectError = zobject.ZObjectError;

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
    undefined: void,
    null: void,
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
    promise: *Rc(ZPromise(JSValue)),
    bigint: *Rc(ZBigInt),
    proxy: *Rc(Proxy),
    array_buffer: *Rc(ArrayBuffer),
    data_view: *Rc(DataViewBox),
    typed_array: *Rc(TypedArrayBox),
    temporal: *Rc(TemporalValue),

    pub const UNDEFINED: JSValue = .{ .undefined = {} };
    pub const NULL: JSValue = .{ .null = {} };

    pub fn fromBool(value: bool) JSValue {
        return .{ .boolean = value };
    }

    pub fn fromNumber(value: f64) JSValue {
        return .{ .number = value };
    }

    pub fn newString(allocator: Allocator, content: []const u8) ZValueError!JSValue {
        // Always owned (initOwned, never the borrowed-mode init()) — a
        // borrowed ZString's deinit() is a no-op, which would silently break
        // the Rc(T) refcounting contract (the box would "free" without
        // actually freeing anything).
        var str = try ZString.initOwned(allocator, content);
        errdefer str.deinit();
        return .{ .string = try Rc(ZString).create(allocator, str) };
    }

    pub fn newArray(allocator: Allocator) ZValueError!JSValue {
        const arr = ZArray(JSValue).init(allocator);
        return .{ .array = try Rc(ZArray(JSValue)).create(allocator, arr) };
    }

    pub fn newObject(allocator: Allocator) ZValueError!JSValue {
        const obj = ZObject(JSValue).init(allocator);
        return .{ .object = try Rc(ZObject(JSValue)).create(allocator, obj) };
    }

    /// Takes ownership of an already-compiled Regex (e.g. from
    /// `zregex.Regex.compile()`) -- including on failure: if the box
    /// can't be allocated, `re` is released here, never by the caller.
    pub fn fromRegex(allocator: Allocator, re: Regex) ZValueError!JSValue {
        errdefer re.deinit();
        return .{ .regex = try Rc(Regex).create(allocator, re) };
    }

    /// Every call produces a brand-new, always-unique symbol — even with an
    /// identical description, it never equals a previously created one (see
    /// equality.zig: symbols compare by Rc box identity). Uses
    /// ZSymbol.init() (a value, not create()'s own heap allocation) since
    /// the Rc box itself is the symbol's one true heap allocation.
    pub fn newSymbol(allocator: Allocator, description: ?[]const u8) ZValueError!JSValue {
        var sym = try ZSymbol.init(allocator, description);
        errdefer sym.deinit();
        return .{ .symbol = try Rc(ZSymbol).create(allocator, sym) };
    }

    pub fn newMap(allocator: Allocator) ZValueError!JSValue {
        const m = ZMap(JSValue, JSValue).init(allocator);
        return .{ .map = try Rc(ZMap(JSValue, JSValue)).create(allocator, m) };
    }

    pub fn newSet(allocator: Allocator) ZValueError!JSValue {
        const s = ZSet(JSValue).init(allocator);
        return .{ .set = try Rc(ZSet(JSValue)).create(allocator, s) };
    }

    /// Errors are objects in JS (typeOf() below reports "object", not
    /// "error") but get their own JSValue variant for cheap identity
    /// comparison and type-safe dispatch (e.g. an interpreter's catch-clause
    /// matching), same rationale as symbol/map/set each getting their own
    /// variant instead of being represented as plain `.object` values.
    pub fn newError(allocator: Allocator, kind: ErrorKind, message: []const u8) ZValueError!JSValue {
        var err = try ZError(JSValue).init(allocator, kind, message);
        errdefer err.deinit();
        return .{ .@"error" = try Rc(ZError(JSValue)).create(allocator, err) };
    }

    /// AggregateError. Like arr.push()/map.set(), this does NOT retain
    /// `errs` for you — ZError(JSValue).initAggregate() only byte-copies the
    /// slice (same shallow-copy shape as ZArray.clone(), see the
    /// OWNERSHIP RULE at the top of this file). If you still need your own
    /// copy of a value after this call, retain() it yourself first:
    /// `newAggregateError(alloc, "msg", &.{ a.retain(), b.retain() })`.
    /// Ownership of `errs`' elements is taken even on failure (same as
    /// `newDataView`'s `owner`): they are released here if this errors.
    pub fn newAggregateError(allocator: Allocator, message: []const u8, errs: []const JSValue) ZValueError!JSValue {
        errdefer for (errs) |e| e.deinit();
        var err = try ZError(JSValue).initAggregate(allocator, message, errs);
        errdefer err.deinit();
        return .{ .@"error" = try Rc(ZError(JSValue)).create(allocator, err) };
    }

    /// Wraps a native or user-defined `Callable` (see callable.zig) as a
    /// JSValue -- functions are first-class values in JS: they can be
    /// stored in variables/properties/arrays and compared by identity.
    /// Takes ownership of `callable` (its `prototype`/`statics`, if set)
    /// even on failure -- released here if the box can't be allocated.
    pub fn newFunction(allocator: Allocator, callable: Callable) ZValueError!JSValue {
        var owned = callable;
        errdefer owned.deinit();
        return .{ .function = try Rc(Callable).create(allocator, owned) };
    }

    /// A Date from milliseconds since the Unix epoch. Out-of-range values
    /// become z-date's INVALID_TIME (the "Invalid Date" state), matching
    /// the real Date constructor.
    pub fn newDate(allocator: Allocator, ms: i64) ZValueError!JSValue {
        return .{ .date = try Rc(ZDate).create(allocator, ZDate.fromTimestamp(ms)) };
    }

    /// Wraps any of the 8 z-temporal instance types (see `TemporalValue`'s
    /// doc comment for why they share one variant instead of getting one
    /// each).
    pub fn newTemporal(allocator: Allocator, value: TemporalValue) ZValueError!JSValue {
        return .{ .temporal = try Rc(TemporalValue).create(allocator, value) };
    }

    /// A fresh pending Promise. State transitions and reaction scheduling
    /// are the embedder's job (see z-promise's own doc: it stores, the
    /// interpreter schedules and calls).
    pub fn newPromise(allocator: Allocator) ZValueError!JSValue {
        return .{ .promise = try Rc(ZPromise(JSValue)).create(allocator, ZPromise(JSValue).init()) };
    }

    /// Parses the exact raw digit text a BigInt literal/coercion hands in
    /// (see z-bigint's `ZBigInt.fromDigitText` for the accepted grammar:
    /// optional `0x`/`0o`/`0b` prefix, `_` separators, optional sign).
    pub fn newBigInt(allocator: Allocator, raw_digit_text: []const u8) BigIntError!JSValue {
        var v = try ZBigInt.fromDigitText(allocator, raw_digit_text);
        errdefer v.deinit();
        return .{ .bigint = try Rc(ZBigInt).create(allocator, v) };
    }

    /// Boxes an already-computed `ZBigInt` (e.g. the result of
    /// `ZBigInt.add`/`.mul`/etc.) -- unlike `newBigInt`, does not parse
    /// digit text. Takes ownership of `v` (matching `newDate`/`newSymbol`'s
    /// "box whatever you're handed" convention for freshly-constructed
    /// values with no other owner yet) -- including on failure: `v` is
    /// released here if the box can't be allocated.
    pub fn newBigIntFromValue(allocator: Allocator, v: ZBigInt) ZValueError!JSValue {
        var owned = v;
        errdefer owned.deinit();
        return .{ .bigint = try Rc(ZBigInt).create(allocator, owned) };
    }

    /// Does NOT retain `target`/`handler` for you (see proxy.zig's doc
    /// comment) -- same convention as `newAggregateError`'s `errs`. Like
    /// `newDataView`, ownership is taken even on failure: both are
    /// released here if the box can't be allocated.
    pub fn newProxy(allocator: Allocator, target: JSValue, handler: JSValue) ZValueError!JSValue {
        errdefer {
            target.deinit();
            handler.deinit();
        }
        return .{ .proxy = try Rc(Proxy).create(allocator, .{ .target = target, .handler = handler }) };
    }

    /// Allocates a new zero-initialized `ArrayBuffer` of `byte_length`
    /// bytes.
    pub fn newArrayBuffer(allocator: Allocator, byte_length: usize) ZValueError!JSValue {
        var buf = try ArrayBuffer.init(allocator, byte_length);
        errdefer buf.deinit();
        return .{ .array_buffer = try Rc(ArrayBuffer).create(allocator, buf) };
    }

    /// Same storage as `newArrayBuffer` -- this engine has no real
    /// cross-agent memory model, so `SharedArrayBuffer` is `ArrayBuffer`
    /// plus `is_shared` for prototype dispatch (see
    /// atomics-sharedarraybuffer.md). Still one JSValue tag,
    /// `.array_buffer`.
    pub fn newSharedArrayBuffer(allocator: Allocator, byte_length: usize) ZValueError!JSValue {
        var buf = try ArrayBuffer.init(allocator, byte_length);
        errdefer buf.deinit();
        buf.is_shared = true;
        return .{ .array_buffer = try Rc(ArrayBuffer).create(allocator, buf) };
    }

    /// Precondition: `owner` must be `.array_buffer`. If it is not, the
    /// process aborts with a clear message, in every build mode -- this is
    /// a caller bug, not JS-facing input (z-interpreter validates the
    /// argument and throws a real JS TypeError before calling), so it is
    /// not part of the error set.
    ///
    /// Does NOT retain `owner` for you (same convention as `newProxy`'s
    /// `target`/`handler`) -- the caller must `.retain()` it first if it
    /// still needs its own reference afterward.
    pub fn newDataView(allocator: Allocator, owner: JSValue, byte_offset: usize, byte_length: ?usize) BufferError!JSValue {
        owner.requireTag(.array_buffer, "newDataView: owner must be .array_buffer");
        // `owner` is already a retained reference handed off by the
        // caller -- on any error below, nothing else will ever release
        // it, so this function must.
        errdefer owner.deinit();
        const box = owner.array_buffer;
        const view = try zbuffer.DataView.init(&box.value, byte_offset, byte_length);
        return .{ .data_view = try Rc(DataViewBox).create(allocator, .{ .view = view, .owner = owner }) };
    }

    /// Same "caller retains, this takes ownership" convention as
    /// `newDataView`, and the same validate-via-delegation shape:
    /// dispatches to the right `zbuffer.TypedArrayView(T).init` for its
    /// `Misaligned`/`OutOfBounds` bounds checking AND to resolve `len`
    /// when omitted (`null` -> every whole element from `byte_offset` to
    /// the end of the buffer, matching `new Int32Array(buffer,
    /// byteOffset)` with no length argument) -- the returned view's
    /// `.len` is what actually gets stored; `TypedArrayBox` keeps the
    /// raw offset/len/kind and reconstructs a view on demand per access,
    /// since `kind` is a runtime tag and `T` isn't known until then.
    ///
    /// Precondition: `owner` must be `.array_buffer`. If it is not, the
    /// process aborts with a clear message (same as `newDataView`).
    pub fn newTypedArray(allocator: Allocator, owner: JSValue, byte_offset: usize, len: ?usize, kind: TypedKind) BufferError!JSValue {
        owner.requireTag(.array_buffer, "newTypedArray: owner must be .array_buffer");
        errdefer owner.deinit();
        const box = owner.array_buffer;
        const resolved_len: usize = switch (kind) {
            .i8 => (try zbuffer.TypedArrayView(i8).init(&box.value, byte_offset, len)).len,
            .u8, .u8_clamped => (try zbuffer.TypedArrayView(u8).init(&box.value, byte_offset, len)).len,
            .i16 => (try zbuffer.TypedArrayView(i16).init(&box.value, byte_offset, len)).len,
            .u16 => (try zbuffer.TypedArrayView(u16).init(&box.value, byte_offset, len)).len,
            .i32 => (try zbuffer.TypedArrayView(i32).init(&box.value, byte_offset, len)).len,
            .u32 => (try zbuffer.TypedArrayView(u32).init(&box.value, byte_offset, len)).len,
            .f32 => (try zbuffer.TypedArrayView(f32).init(&box.value, byte_offset, len)).len,
            .f64 => (try zbuffer.TypedArrayView(f64).init(&box.value, byte_offset, len)).len,
            .i64 => (try zbuffer.TypedArrayView(i64).init(&box.value, byte_offset, len)).len,
            .u64 => (try zbuffer.TypedArrayView(u64).init(&box.value, byte_offset, len)).len,
        };
        return .{ .typed_array = try Rc(TypedArrayBox).create(allocator, .{ .owner = owner, .byte_offset = byte_offset, .len = resolved_len, .kind = kind }) };
    }

    /// Aborts the process with `<context>, got .<actual tag>` unless `self`
    /// holds `expected`. Used for caller-bug preconditions (never for
    /// JS-facing input): `std.debug.panic` stays active in every build mode,
    /// so a wrong variant is a deterministic abort instead of reading
    /// another variant's payload (undefined behavior in ReleaseFast).
    fn requireTag(self: JSValue, comptime expected: std.meta.Tag(JSValue), comptime context: []const u8) void {
        if (self != expected) std.debug.panic(context ++ ", got .{s}", .{@tagName(self)});
    }

    /// ECMAScript `typeof` operator. Note the famous spec quirk:
    /// typeof null === "object", not "null". Arrays/objects/regexes/maps/sets
    /// are all typeof "object" too — only functions get their own "function"
    /// result, everything else heap-boxed is "object".
    pub fn typeOf(self: JSValue) []const u8 {
        // A proxy reports its TARGET's type, not a fixed "object" -- a proxy
        // wrapping a callable is itself typeof "function". The target chain
        // is walked with a loop (not recursion), so a 1 000 000-deep
        // proxy-of-proxy chain costs no native stack.
        //
        // `slow` trails `cur` at half speed (Floyd's cycle check, no memory
        // needed): a chain that loops back on itself can't come from JS (a
        // Proxy's target is fixed at creation), only from code mutating
        // `Proxy.target` directly, and it has no final target to report --
        // abort with a clear message instead of spinning forever.
        var cur = self;
        var slow = self;
        var advance_slow = false;
        while (cur == .proxy) {
            cur = cur.proxy.value.target;
            if (advance_slow) {
                slow = slow.proxy.value.target;
                if (cur == .proxy and cur.proxy == slow.proxy) {
                    std.debug.panic("typeOf: proxy target chain is cyclic", .{});
                }
            }
            advance_slow = !advance_slow;
        }
        return switch (cur) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .function => "function",
            .bigint => "bigint",
            .proxy => unreachable, // the loop above only exits on a non-proxy
            .array, .object, .regex, .map, .set, .@"error", .date, .promise, .array_buffer, .data_view, .typed_array, .temporal => "object",
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
            .undefined, .null, .boolean, .number => {},
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
            .promise => |box| _ = box.retain(),
            .bigint => |box| _ = box.retain(),
            .proxy => |box| _ = box.retain(),
            .array_buffer => |box| _ = box.retain(),
            .data_view => |box| _ = box.retain(),
            .typed_array => |box| _ = box.retain(),
            .temporal => |box| _ = box.retain(),
        }
        return self;
    }

    /// Sets the GC hook (see `Rc(T).setGcHook`) on whichever box backs this
    /// value; a no-op for the four inline variants. An embedder uses this
    /// right after creating a value to keep an external registry in sync
    /// with `Rc.destroy()`, wherever that ends up being triggered from.
    pub fn setGcHook(self: JSValue, ctx: *anyopaque, hook: *const fn (ctx: *anyopaque, box: *anyopaque) void) void {
        switch (self) {
            .undefined, .null, .boolean, .number => {},
            .string => |box| _ = box.setGcHook(ctx, hook),
            .array => |box| _ = box.setGcHook(ctx, hook),
            .object => |box| _ = box.setGcHook(ctx, hook),
            .regex => |box| _ = box.setGcHook(ctx, hook),
            .symbol => |box| _ = box.setGcHook(ctx, hook),
            .map => |box| _ = box.setGcHook(ctx, hook),
            .set => |box| _ = box.setGcHook(ctx, hook),
            .@"error" => |box| _ = box.setGcHook(ctx, hook),
            .function => |box| _ = box.setGcHook(ctx, hook),
            .date => |box| _ = box.setGcHook(ctx, hook),
            .promise => |box| _ = box.setGcHook(ctx, hook),
            .bigint => |box| _ = box.setGcHook(ctx, hook),
            .proxy => |box| _ = box.setGcHook(ctx, hook),
            .array_buffer => |box| _ = box.setGcHook(ctx, hook),
            .data_view => |box| _ = box.setGcHook(ctx, hook),
            .typed_array => |box| _ = box.setGcHook(ctx, hook),
            .temporal => |box| _ = box.setGcHook(ctx, hook),
        }
    }

    /// Releases this reference. When the underlying box's refcount reaches
    /// zero, tears down the wrapped value (releasing any nested JSValues
    /// first) and frees the box.
    ///
    /// Iterative, not recursive: nesting depth costs no native stack, so a
    /// 100 000-deep `a = [a]` chain is released as safely as a flat one.
    /// It also never allocates (see `PendingRelease`), so releasing memory
    /// can never fail for lack of memory.
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
        var pending: PendingRelease = .{};
        self.releaseInto(&pending);
        pending.drain();
    }

    /// Container boxes whose refcount just reached zero but whose children
    /// have not been released yet: one intrusive singly-linked list per
    /// container type. The link lives in the box's own `_count` field, which
    /// is dead once it reaches zero (nothing reads it again before
    /// `destroy()`), so queueing a box needs no memory at all -- and each
    /// list being homogeneous means no type tag has to be stored alongside
    /// the link. The list heads are the only state, and they live on the
    /// stack of `deinit()`.
    ///
    /// Only types that can nest arbitrarily deep are queued. Leaves (no
    /// nested JSValues) are torn down on the spot, and views (`data_view`,
    /// `typed_array`) release their single owner into the lists and are torn
    /// down on the spot too.
    const PendingRelease = struct {
        array: ?*Rc(ZArray(JSValue)) = null,
        object: ?*Rc(ZObject(JSValue)) = null,
        map: ?*Rc(ZMap(JSValue, JSValue)) = null,
        set: ?*Rc(ZSet(JSValue)) = null,
        @"error": ?*Rc(ZError(JSValue)) = null,
        function: ?*Rc(Callable) = null,
        promise: ?*Rc(ZPromise(JSValue)) = null,
        proxy: ?*Rc(Proxy) = null,

        fn push(self: *PendingRelease, comptime tag: []const u8, box: @typeInfo(@FieldType(PendingRelease, tag)).optional.child) void {
            std.debug.assert(box._count == 0);
            box._count = if (@field(self, tag)) |head| @intFromPtr(head) else 0;
            @field(self, tag) = box;
        }

        fn pop(self: *PendingRelease, comptime tag: []const u8) @FieldType(PendingRelease, tag) {
            const box = @field(self, tag) orelse return null;
            @field(self, tag) = if (box._count == 0) null else @ptrFromInt(box._count);
            box._count = 0;
            return box;
        }

        /// Tears down every queued box. Releasing a box's children may
        /// queue more boxes; the loop runs until every list is empty.
        ///
        /// The payload types defined in this repo (`Callable`, `Proxy`,
        /// `DataViewBox`, `TypedArrayBox`) have their own `deinit()` that
        /// calls `JSValue.deinit()` on their fields; calling it here would
        /// start a nested release per level and bring the recursion back.
        /// Their JSValue fields are released into the lists by hand
        /// instead -- keep these arms in sync with those `deinit()`s.
        fn drain(self: *PendingRelease) void {
            while (true) {
                if (self.pop("array")) |box| {
                    for (box.value.toSliceMut()) |child| child.releaseInto(self);
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("object")) |box| {
                    for (box.value.properties.values()) |prop| {
                        prop.value.releaseInto(self);
                        if (prop.getter) |g| g.releaseInto(self);
                        if (prop.setter) |st| st.releaseInto(self);
                    }
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("map")) |box| {
                    // Unlike ZObject (String-keyed), Map keys are arbitrary
                    // JSValues too — both sides need releasing.
                    for (box.value.keys()) |key| key.releaseInto(self);
                    for (box.value.values()) |value| value.releaseInto(self);
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("set")) |box| {
                    for (box.value.values()) |value| value.releaseInto(self);
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("error")) |box| {
                    // AggregateError's errors slice holds JSValues too (only
                    // non-null for .aggregate_error).
                    if (box.value.errors) |errs| {
                        for (errs) |e| e.releaseInto(self);
                    }
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("function")) |box| {
                    // Same fields Callable.deinit() releases.
                    if (box.value.prototype) |p| p.releaseInto(self);
                    if (box.value.statics) |st| st.releaseInto(self);
                    box.destroy();
                } else if (self.pop("promise")) |box| {
                    // The settled result and every handler/derived in
                    // still-pending reactions are JSValues this box owns.
                    if (box.value.result) |r| r.releaseInto(self);
                    for (box.value.reactions.items) |reaction| {
                        if (reaction.on_fulfilled) |h| h.releaseInto(self);
                        if (reaction.on_rejected) |h| h.releaseInto(self);
                        if (reaction.derived) |d| d.releaseInto(self);
                    }
                    box.value.deinit(box.allocator);
                    box.destroy();
                } else if (self.pop("proxy")) |box| {
                    // Same fields Proxy.deinit() releases.
                    box.value.target.releaseInto(self);
                    box.value.handler.releaseInto(self);
                    box.destroy();
                } else break;
            }
        }
    };

    /// Drops one reference. A box that reaches zero is either torn down on
    /// the spot (leaves and views: bounded work, no recursion beyond one
    /// view -> owner step) or queued on `pending` (containers).
    fn releaseInto(self: JSValue, pending: *PendingRelease) void {
        switch (self) {
            .undefined, .null, .boolean, .number => {},
            // Leaves that own heap storage of their own.
            inline .string, .regex, .symbol, .bigint, .array_buffer => |box| {
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            // Pure values (ZDate, every z-temporal type) -- only the box
            // itself needs freeing.
            inline .date, .temporal => |box| {
                if (box.decref()) box.destroy();
            },
            // Views own no bytes of their own, only their `.array_buffer`
            // owner (same field DataViewBox/TypedArrayBox.deinit() release).
            inline .data_view, .typed_array => |box| {
                if (box.decref()) {
                    box.value.owner.releaseInto(pending);
                    box.destroy();
                }
            },
            inline .array, .object, .map, .set, .@"error", .function, .promise, .proxy => |box, tag| {
                if (box.decref()) pending.push(@tagName(tag), box);
            },
        }
    }

    // ---- Rc-aware mutation ------------------------------------------------
    //
    // z-object/z-map/z-set store and drop values by plain copy: generic over
    // T, they never release a value they overwrite or remove. These wrappers
    // do it for JSValue containers. Same contract as the constructors: every
    // JSValue handed in is consumed, also when the call fails. A value being
    // replaced is released only AFTER the new one is stored, so replacing a
    // value with the same box (`o.x = o.x`) never drops its count to zero
    // midway. Each requires the matching variant (see `requireTag`).
    //
    // Two ownership conventions coexist, so do not mix them up:
    //   - constructors (`new*`) and these wrappers CONSUME every JSValue
    //     handed in, also on error: never `errdefer v.deinit()` around them.
    //   - the raw payload APIs (`ZObject.set`/`defineProperty`, `ZMap.set`,
    //     `ZSet.add`, `ZArray` mutators, reached through `box.value`) do NOT
    //     consume on error: the caller still owns the value and must
    //     release it. On success they store it without releasing anything
    //     they overwrite or remove.

    /// `self[key] = value`, releasing whatever the property held before
    /// (its value, or its getter/setter if it was an accessor -- a plain set
    /// replaces an accessor with a data property). On error (frozen,
    /// non-writable, non-extensible, out of memory) `value` is released and
    /// the property is unchanged. `o.x = o.x` is safe: the old value is
    /// released only after the new one is stored. Raw counterpart:
    /// `ZObject.set`, which keeps `value` with the caller on error and never
    /// releases the value it overwrites.
    pub fn objectSet(self: JSValue, key: []const u8, value: JSValue) ZObjectError!void {
        self.requireTag(.object, "objectSet: expected .object");
        const obj = &self.object.value;
        const old = OwnSlots.read(obj, key);
        obj.set(key, value) catch |err| {
            value.deinit();
            return err;
        };
        old.release();
    }

    /// Defines `key` as a data property with `descriptor`, releasing what it
    /// held before. If it was an accessor, its getter/setter slots are
    /// cleared (it becomes a data property, as in JS) and released. On error
    /// `value` is released and the property is unchanged. Redefining with
    /// the same box is safe (old slots are released last). Raw counterpart:
    /// `ZObject.defineProperty`, which keeps `value` with the caller on
    /// error and releases nothing.
    pub fn objectDefine(self: JSValue, key: []const u8, value: JSValue, descriptor: PropertyDescriptor) ZObjectError!void {
        self.requireTag(.object, "objectDefine: expected .object");
        const obj = &self.object.value;
        const old = OwnSlots.read(obj, key);
        obj.defineProperty(key, value, descriptor) catch |err| {
            value.deinit();
            return err;
        };
        // defineProperty leaves the accessor slots in place; drop them
        // before releasing what they pointed to.
        if (obj.getOwnRecordMut(key)) |rec| {
            rec.getter = null;
            rec.setter = null;
        }
        old.release();
    }

    /// Removes own property `key` and releases its value (and getter/
    /// setter). Returns false if it wasn't there. On error (frozen,
    /// non-configurable) nothing is removed or released. Consumes no
    /// JSValue (the key is a plain string). Raw counterpart:
    /// `ZObject.delete`, which removes the slot without releasing it.
    pub fn objectDelete(self: JSValue, key: []const u8) ZObjectError!bool {
        self.requireTag(.object, "objectDelete: expected .object");
        const obj = &self.object.value;
        const old = OwnSlots.read(obj, key);
        const removed = try obj.delete(key);
        if (removed) old.release();
        return removed;
    }

    /// Removes every own property and releases what they held. Fails --
    /// releasing nothing -- under the same conditions as `ZObject.clear`
    /// (a frozen object, or any non-configurable property), which are
    /// checked first so values are never released for a clear that is then
    /// refused. Consumes no JSValue. Raw counterpart: `ZObject.clear`,
    /// which drops the slots without releasing them.
    pub fn objectClear(self: JSValue) ZObjectError!void {
        self.requireTag(.object, "objectClear: expected .object");
        const obj = &self.object.value;
        if (obj.is_frozen) return error.ObjectIsFrozen;
        for (obj.properties.values()) |prop| {
            if (!prop.descriptor.configurable) return error.PropertyNotConfigurable;
        }
        for (obj.properties.values()) |prop| {
            prop.value.deinit();
            if (prop.getter) |g| g.deinit();
            if (prop.setter) |st| st.deinit();
        }
        obj.clear() catch |err| std.debug.panic("objectClear: ZObject.clear refused after its preconditions passed: {s}", .{@errorName(err)});
    }

    /// The JSValues one own property slot holds, copied out before a
    /// mutation so they can be released once it has succeeded.
    const OwnSlots = struct {
        value: ?JSValue = null,
        getter: ?JSValue = null,
        setter: ?JSValue = null,

        fn read(obj: *const ZObject(JSValue), key: []const u8) OwnSlots {
            const rec = obj.getOwnRecord(key) orelse return .{};
            return .{ .value = rec.value, .getter = rec.getter, .setter = rec.setter };
        }

        fn release(self: OwnSlots) void {
            if (self.value) |v| v.deinit();
            if (self.getter) |g| g.deinit();
            if (self.setter) |st| st.deinit();
        }
    };

    /// `self.set(key, value)` with Map semantics: an existing key keeps its
    /// position and its STORED key box; the old value and the incoming
    /// (now redundant) key are released after the new value is stored. On
    /// error both `key` and `value` are released and the map is unchanged.
    /// Passing the stored key box or the stored value box again is safe
    /// (the caller retained it). Raw counterpart: `ZMap.set`, which keeps
    /// `key`/`value` with the caller on error and never releases the old
    /// value or the redundant key.
    pub fn mapSet(self: JSValue, key: JSValue, value: JSValue) ZValueError!void {
        self.requireTag(.map, "mapSet: expected .map");
        const m = &self.map.value;
        const old_value = m.get(key);
        m.set(key, value) catch |err| {
            key.deinit();
            value.deinit();
            return err;
        };
        if (old_value) |old| {
            key.deinit();
            old.deinit();
        }
    }

    /// Removes `key` and releases the STORED key and its value (the stored
    /// key may be a different, equal box than `key`, e.g. two "k" strings).
    /// `key` itself is only looked up, not consumed -- also when it is the
    /// stored box. Returns false if the key wasn't there. Raw counterpart:
    /// `ZMap.delete`, which removes the entry without releasing it.
    pub fn mapDelete(self: JSValue, key: JSValue) bool {
        self.requireTag(.map, "mapDelete: expected .map");
        const entry = self.map.value.fetchDelete(key) orelse return false;
        entry.key.deinit();
        entry.value.deinit();
        return true;
    }

    /// Removes every entry and releases every key and value. Consumes no
    /// JSValue. Raw counterpart: `ZMap.clear`, which releases nothing.
    pub fn mapClear(self: JSValue) void {
        self.requireTag(.map, "mapClear: expected .map");
        const m = &self.map.value;
        for (m.keys()) |key| key.deinit();
        for (m.values()) |value| value.deinit();
        m.clear();
    }

    /// Adds `value` unless an equal value is already present, in which case
    /// `value` is released (the stored one stays) -- so adding the stored
    /// box again just drops the caller's reference. On error `value` is
    /// released and the set is unchanged. Raw counterpart: `ZSet.add`,
    /// which keeps `value` with the caller on error and never releases a
    /// duplicate.
    pub fn setAdd(self: JSValue, value: JSValue) ZValueError!void {
        self.requireTag(.set, "setAdd: expected .set");
        const st = &self.set.value;
        if (st.has(value)) {
            value.deinit();
            return;
        }
        st.add(value) catch |err| {
            value.deinit();
            return err;
        };
    }

    /// Removes `value` and releases the STORED element (possibly a
    /// different, equal box). `value` itself is only looked up, not
    /// consumed -- also when it is the stored box. Returns false if it
    /// wasn't there. Raw counterpart: `ZSet.delete`, which removes the
    /// element without releasing it.
    pub fn setDelete(self: JSValue, value: JSValue) bool {
        self.requireTag(.set, "setDelete: expected .set");
        // ZSet is a ZMap(T, void) underneath; its fetchDelete hands back
        // the stored element.
        const entry = self.set.value.map.fetchDelete(value) orelse return false;
        entry.key.deinit();
        return true;
    }

    /// Removes every element and releases it. Consumes no JSValue. Raw
    /// counterpart: `ZSet.clear`, which releases nothing.
    pub fn setClear(self: JSValue) void {
        self.requireTag(.set, "setClear: expected .set");
        const st = &self.set.value;
        for (st.values()) |value| value.deinit();
        st.clear();
    }

    /// Rc-aware duplicate of a `.array` JSValue: unlike `ZArray(JSValue).clone()`
    /// (a shallow byte-copy that does NOT retain its elements — never call it
    /// directly on `T = JSValue`), this retains every child element so the
    /// two arrays can each be independently deinit()'d without double-freeing
    /// shared children.
    ///
    /// Precondition: `self` must be `.array`. If it is not, the process
    /// aborts with a clear message, in every build mode.
    pub fn cloneArray(self: JSValue) ZValueError!JSValue {
        self.requireTag(.array, "cloneArray: expected .array");
        const box = self.array;
        var new_arr = try box.value.clone();
        errdefer new_arr.deinit();
        const new_box = try Rc(ZArray(JSValue)).create(box.allocator, new_arr);
        // Retain only once nothing below can fail: an earlier retain would
        // leave every child over-counted if the box allocation failed.
        for (new_box.value.toSliceMut()) |*child| _ = child.retain();
        return .{ .array = new_box };
    }

    /// Rc-aware duplicate of a `.object` JSValue: retains every property
    /// value, analogous to cloneArray(). Does NOT copy the prototype pointer
    /// (see the KNOWN GAP note on deinit()) beyond whatever raw pointer copy
    /// ZObject's own property storage performs.
    ///
    /// Precondition: `self` must be `.object`. If it is not, the process
    /// aborts with a clear message, in every build mode.
    pub fn cloneObject(self: JSValue) !JSValue {
        self.requireTag(.object, "cloneObject: expected .object");
        const box = self.object;
        var new_obj = ZObject(JSValue).init(box.allocator);
        // On failure, release every value already copied (each was retained
        // right after its own successful set()) before freeing the object.
        errdefer {
            for (new_obj.properties.values()) |prop| prop.value.deinit();
            new_obj.deinit();
        }

        const keys = try box.value.keys(box.allocator);
        defer box.allocator.free(keys);
        for (keys) |key| {
            const value = box.value.get(key).?;
            try new_obj.set(key, value);
            _ = value.retain();
        }

        return .{ .object = try Rc(ZObject(JSValue)).create(box.allocator, new_obj) };
    }

    /// Rc-aware duplicate of a `.map` JSValue: retains every key AND every
    /// value (Map keys are JSValues too, unlike ZObject's plain-string
    /// keys), analogous to cloneArray()/cloneObject(). ZMap has no
    /// clone()/shallow-copy method to accidentally misuse directly, unlike
    /// ZArray/ZObject — but this still keeps the same Rc-aware-duplicate
    /// naming convention for consistency.
    ///
    /// Precondition: `self` must be `.map`. If it is not, the process
    /// aborts with a clear message, in every build mode.
    pub fn cloneMap(self: JSValue) ZValueError!JSValue {
        self.requireTag(.map, "cloneMap: expected .map");
        const box = self.map;
        var new_map = ZMap(JSValue, JSValue).init(box.allocator);
        // Same shape as cloneObject(): release what was already copied.
        errdefer {
            for (new_map.keys()) |key| key.deinit();
            for (new_map.values()) |value| value.deinit();
            new_map.deinit();
        }

        const pairs = try box.value.entries(box.allocator);
        defer box.allocator.free(pairs);
        for (pairs) |pair| {
            try new_map.set(pair.key, pair.value);
            _ = pair.key.retain();
            _ = pair.value.retain();
        }

        return .{ .map = try Rc(ZMap(JSValue, JSValue)).create(box.allocator, new_map) };
    }

    /// Rc-aware duplicate of a `.set` JSValue: retains every value.
    ///
    /// Precondition: `self` must be `.set`. If it is not, the process
    /// aborts with a clear message, in every build mode.
    pub fn cloneSet(self: JSValue) ZValueError!JSValue {
        self.requireTag(.set, "cloneSet: expected .set");
        const box = self.set;
        var new_set = ZSet(JSValue).init(box.allocator);
        // Same shape as cloneObject(): release what was already copied.
        errdefer {
            for (new_set.values()) |value| value.deinit();
            new_set.deinit();
        }

        for (box.value.values()) |value| {
            try new_set.add(value);
            _ = value.retain();
        }

        return .{ .set = try Rc(ZSet(JSValue)).create(box.allocator, new_set) };
    }

    /// Rc-aware duplicate of a `.error` JSValue: for AggregateError, retains
    /// every JSValue in `errors` (analogous to cloneArray()/cloneSet()) —
    /// ZError(JSValue).initAggregate() only byte-copies the slice it's given,
    /// it does not retain on its own.
    ///
    /// Precondition: `self` must be `.error`. If it is not, the process
    /// aborts with a clear message, in every build mode.
    pub fn cloneError(self: JSValue) ZValueError!JSValue {
        self.requireTag(.@"error", "cloneError: expected .error");
        const box = self.@"error";
        var new_err = if (box.value.errors) |errs|
            try ZError(JSValue).initAggregate(box.allocator, box.value.message, errs)
        else
            try ZError(JSValue).init(box.allocator, box.value.kind, box.value.message);
        errdefer new_err.deinit();
        const new_box = try Rc(ZError(JSValue)).create(box.allocator, new_err);
        // Retain only once nothing below can fail (same as cloneArray()).
        if (new_box.value.errors) |errs| {
            for (errs) |e| _ = e.retain();
        }
        return .{ .@"error" = new_box };
    }
};
