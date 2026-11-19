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
pub const PropertyDescriptor = zobject.PropertyDescriptor;
pub const ZObjectError = zobject.ZObjectError;

pub const JSValue = extern struct {
    bits: u64,

    comptime {
        std.debug.assert(@sizeOf(JSValue) == 8);
    }

    pub const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0000;
    pub const PTR_MASK: u64 = 0x0000_7FFF_FFFF_FFFF;
    pub const HEADER_MASK: u64 = 0xFFFF_8000_0000_0000;

    pub const Tag = enum(u5) {
        number = 0,
        undefined = 1,
        null = 2,
        boolean = 3,
        string = 4,
        array = 5,
        object = 6,
        regex = 7,
        symbol = 8,
        map = 9,
        set = 10,
        @"error" = 11,
        function = 12,
        date = 13,
        promise = 14,
        bigint = 15,
        proxy = 16,
        array_buffer = 17,
        data_view = 18,
        typed_array = 19,
        temporal = 20,
    };

    pub const Unpacked = union(enum) {
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
    };

    pub inline fn makeHeader(t: Tag) u64 {
        const raw: u5 = @intFromEnum(t);
        const sign: u64 = @as(u64, (raw >> 4) & 1) << 63;
        const tag_field: u64 = @as(u64, raw & 0xF) << 47;
        return sign | 0x7FF8_0000_0000_0000 | tag_field;
    }

    pub inline fn fromHeap(comptime t: Tag, ptr: anytype) JSValue {
        const raw = @intFromPtr(ptr);
        std.debug.assert(raw <= PTR_MASK);
        return .{ .bits = makeHeader(t) | raw };
    }

    pub const TAG_UNDEFINED: u64 = makeHeader(.undefined);
    pub const TAG_NULL: u64 = makeHeader(.null);
    pub const TAG_BOOLEAN_BASE: u64 = makeHeader(.boolean);
    pub const TAG_FALSE: u64 = TAG_BOOLEAN_BASE;
    pub const TAG_TRUE: u64 = TAG_BOOLEAN_BASE | 1;

    pub const UNDEFINED: JSValue = .{ .bits = TAG_UNDEFINED };
    pub const NULL: JSValue = .{ .bits = TAG_NULL };
    pub const TRUE: JSValue = .{ .bits = TAG_TRUE };
    pub const FALSE: JSValue = .{ .bits = TAG_FALSE };

    pub const undefined_val: JSValue = UNDEFINED;
    pub const null_val: JSValue = NULL;

    pub inline fn fromBool(value: bool) JSValue {
        return if (value) TRUE else FALSE;
    }

    pub inline fn fromNumber(value: f64) JSValue {
        if (std.math.isNan(value)) return .{ .bits = CANONICAL_NAN };
        return .{ .bits = @bitCast(value) };
    }

    pub inline fn fromString(box: *Rc(ZString)) JSValue {
        return fromHeap(.string, box);
    }

    pub inline fn fromArray(box: *Rc(ZArray(JSValue))) JSValue {
        return fromHeap(.array, box);
    }

    pub inline fn fromObject(box: *Rc(ZObject(JSValue))) JSValue {
        return fromHeap(.object, box);
    }

    pub inline fn fromRegexBox(box: *Rc(Regex)) JSValue {
        return fromHeap(.regex, box);
    }

    pub inline fn fromSymbol(box: *Rc(ZSymbol)) JSValue {
        return fromHeap(.symbol, box);
    }

    pub inline fn fromMap(box: *Rc(ZMap(JSValue, JSValue))) JSValue {
        return fromHeap(.map, box);
    }

    pub inline fn fromSet(box: *Rc(ZSet(JSValue))) JSValue {
        return fromHeap(.set, box);
    }

    pub inline fn fromError(box: *Rc(ZError(JSValue))) JSValue {
        return fromHeap(.@"error", box);
    }

    pub inline fn fromFunction(box: *Rc(Callable)) JSValue {
        return fromHeap(.function, box);
    }

    pub inline fn fromDate(box: *Rc(ZDate)) JSValue {
        return fromHeap(.date, box);
    }

    pub inline fn fromPromise(box: *Rc(ZPromise(JSValue))) JSValue {
        return fromHeap(.promise, box);
    }

    pub inline fn fromBigInt(box: *Rc(ZBigInt)) JSValue {
        return fromHeap(.bigint, box);
    }

    pub inline fn fromProxy(box: *Rc(Proxy)) JSValue {
        return fromHeap(.proxy, box);
    }

    pub inline fn fromArrayBuffer(box: *Rc(ArrayBuffer)) JSValue {
        return fromHeap(.array_buffer, box);
    }

    pub inline fn fromDataView(box: *Rc(DataViewBox)) JSValue {
        return fromHeap(.data_view, box);
    }

    pub inline fn fromTypedArray(box: *Rc(TypedArrayBox)) JSValue {
        return fromHeap(.typed_array, box);
    }

    pub inline fn fromTemporal(box: *Rc(TemporalValue)) JSValue {
        return fromHeap(.temporal, box);
    }

    pub inline fn pack(u: Unpacked) JSValue {
        return switch (u) {
            .undefined => UNDEFINED,
            .null => NULL,
            .boolean => |b| fromBool(b),
            .number => |n| fromNumber(n),
            .string => |ptr| fromString(ptr),
            .array => |ptr| fromArray(ptr),
            .object => |ptr| fromObject(ptr),
            .regex => |ptr| fromRegexBox(ptr),
            .symbol => |ptr| fromSymbol(ptr),
            .map => |ptr| fromMap(ptr),
            .set => |ptr| fromSet(ptr),
            .@"error" => |ptr| fromError(ptr),
            .function => |ptr| fromFunction(ptr),
            .date => |ptr| fromDate(ptr),
            .promise => |ptr| fromPromise(ptr),
            .bigint => |ptr| fromBigInt(ptr),
            .proxy => |ptr| fromProxy(ptr),
            .array_buffer => |ptr| fromArrayBuffer(ptr),
            .data_view => |ptr| fromDataView(ptr),
            .typed_array => |ptr| fromTypedArray(ptr),
            .temporal => |ptr| fromTemporal(ptr),
        };
    }

    pub inline fn isNumber(self: JSValue) bool {
        return self.bits == CANONICAL_NAN or (self.bits & 0x7FF8_0000_0000_0000) != 0x7FF8_0000_0000_0000;
    }

    pub inline fn asNumber(self: JSValue) f64 {
        return @bitCast(self.bits);
    }

    pub inline fn tag(self: JSValue) Tag {
        if (self.isNumber()) return .number;
        const sign: u5 = @intCast((self.bits >> 63) & 1);
        const field: u5 = @intCast((self.bits >> 47) & 0xF);
        const raw: u5 = (sign << 4) | field;
        return @enumFromInt(raw);
    }

    pub inline fn isUndefined(self: JSValue) bool {
        return self.bits == TAG_UNDEFINED;
    }

    pub inline fn isNull(self: JSValue) bool {
        return self.bits == TAG_NULL;
    }

    pub inline fn isBool(self: JSValue) bool {
        return (self.bits & ~@as(u64, 1)) == TAG_BOOLEAN_BASE;
    }

    pub inline fn asBool(self: JSValue) bool {
        return (self.bits & 1) != 0;
    }

    pub inline fn isString(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.string);
    }

    pub inline fn asString(self: JSValue) *Rc(ZString) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isArray(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.array);
    }

    pub inline fn asArray(self: JSValue) *Rc(ZArray(JSValue)) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isObject(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.object);
    }

    pub inline fn asObject(self: JSValue) *Rc(ZObject(JSValue)) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isRegex(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.regex);
    }

    pub inline fn asRegex(self: JSValue) *Rc(Regex) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isSymbol(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.symbol);
    }

    pub inline fn asSymbol(self: JSValue) *Rc(ZSymbol) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isMap(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.map);
    }

    pub inline fn asMap(self: JSValue) *Rc(ZMap(JSValue, JSValue)) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isSet(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.set);
    }

    pub inline fn asSet(self: JSValue) *Rc(ZSet(JSValue)) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isError(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.@"error");
    }

    pub inline fn asError(self: JSValue) *Rc(ZError(JSValue)) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isFunction(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.function);
    }

    pub inline fn asFunction(self: JSValue) *Rc(Callable) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isDate(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.date);
    }

    pub inline fn asDate(self: JSValue) *Rc(ZDate) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isPromise(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.promise);
    }

    pub inline fn asPromise(self: JSValue) *Rc(ZPromise(JSValue)) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isBigInt(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.bigint);
    }

    pub inline fn asBigInt(self: JSValue) *Rc(ZBigInt) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isProxy(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.proxy);
    }

    pub inline fn asProxy(self: JSValue) *Rc(Proxy) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isArrayBuffer(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.array_buffer);
    }

    pub inline fn asArrayBuffer(self: JSValue) *Rc(ArrayBuffer) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isDataView(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.data_view);
    }

    pub inline fn asDataView(self: JSValue) *Rc(DataViewBox) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isTypedArray(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.typed_array);
    }

    pub inline fn asTypedArray(self: JSValue) *Rc(TypedArrayBox) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn isTemporal(self: JSValue) bool {
        return (self.bits & HEADER_MASK) == makeHeader(.temporal);
    }

    pub inline fn asTemporal(self: JSValue) *Rc(TemporalValue) {
        return @ptrFromInt(self.bits & PTR_MASK);
    }

    pub inline fn needsDeinit(self: JSValue) bool {
        if (self.isNumber()) return false;
        return @intFromEnum(self.tag()) >= 4;
    }

    pub inline fn toBoolean(self: JSValue) bool {
        if (self.bits == TAG_TRUE) return true;
        if (self.bits == TAG_FALSE or self.bits == TAG_UNDEFINED or self.bits == TAG_NULL) return false;
        if (self.isNumber()) {
            const n = self.asNumber();
            return n != 0 and !std.math.isNan(n);
        }
        if (self.isString()) {
            return self.asString().value.data.len > 0;
        }
        return true;
    }

    pub inline fn isTruthy(self: JSValue) bool {
        return self.toBoolean();
    }

    pub inline fn unpack(self: JSValue) Unpacked {
        if (self.isNumber()) return .{ .number = self.asNumber() };
        return switch (self.tag()) {
            .number => .{ .number = self.asNumber() },
            .undefined => .{ .undefined = {} },
            .null => .{ .null = {} },
            .boolean => .{ .boolean = self.asBool() },
            .string => .{ .string = self.asString() },
            .array => .{ .array = self.asArray() },
            .object => .{ .object = self.asObject() },
            .regex => .{ .regex = self.asRegex() },
            .symbol => .{ .symbol = self.asSymbol() },
            .map => .{ .map = self.asMap() },
            .set => .{ .set = self.asSet() },
            .@"error" => .{ .@"error" = self.asError() },
            .function => .{ .function = self.asFunction() },
            .date => .{ .date = self.asDate() },
            .promise => .{ .promise = self.asPromise() },
            .bigint => .{ .bigint = self.asBigInt() },
            .proxy => .{ .proxy = self.asProxy() },
            .array_buffer => .{ .array_buffer = self.asArrayBuffer() },
            .data_view => .{ .data_view = self.asDataView() },
            .typed_array => .{ .typed_array = self.asTypedArray() },
            .temporal => .{ .temporal = self.asTemporal() },
        };
    }

    pub fn newString(allocator: Allocator, content: []const u8) ZValueError!JSValue {
        var str = try ZString.initOwned(allocator, content);
        errdefer str.deinit();
        return fromString(try Rc(ZString).create(allocator, str));
    }

    pub fn newArray(allocator: Allocator) ZValueError!JSValue {
        const arr = ZArray(JSValue).init(allocator);
        return fromArray(try Rc(ZArray(JSValue)).create(allocator, arr));
    }

    pub fn newObject(allocator: Allocator) ZValueError!JSValue {
        const obj = ZObject(JSValue).init(allocator);
        return fromObject(try Rc(ZObject(JSValue)).create(allocator, obj));
    }

    pub fn fromRegex(allocator: Allocator, re: Regex) ZValueError!JSValue {
        errdefer re.deinit();
        return fromRegexBox(try Rc(Regex).create(allocator, re));
    }

    pub fn newSymbol(allocator: Allocator, description: ?[]const u8) ZValueError!JSValue {
        var sym = try ZSymbol.init(allocator, description);
        errdefer sym.deinit();
        return fromSymbol(try Rc(ZSymbol).create(allocator, sym));
    }

    pub fn newMap(allocator: Allocator) ZValueError!JSValue {
        const m = ZMap(JSValue, JSValue).init(allocator);
        return fromMap(try Rc(ZMap(JSValue, JSValue)).create(allocator, m));
    }

    pub fn newSet(allocator: Allocator) ZValueError!JSValue {
        const s = ZSet(JSValue).init(allocator);
        return fromSet(try Rc(ZSet(JSValue)).create(allocator, s));
    }

    pub fn newError(allocator: Allocator, kind: ErrorKind, message: []const u8) ZValueError!JSValue {
        var err = try ZError(JSValue).init(allocator, kind, message);
        errdefer err.deinit();
        return fromError(try Rc(ZError(JSValue)).create(allocator, err));
    }

    pub fn newAggregateError(allocator: Allocator, message: []const u8, errs: []const JSValue) ZValueError!JSValue {
        errdefer for (errs) |e| e.deinit();
        var err = try ZError(JSValue).initAggregate(allocator, message, errs);
        errdefer err.deinit();
        return fromError(try Rc(ZError(JSValue)).create(allocator, err));
    }

    pub fn newFunction(allocator: Allocator, callable: Callable) ZValueError!JSValue {
        var owned = callable;
        errdefer owned.deinit();
        return fromFunction(try Rc(Callable).create(allocator, owned));
    }

    pub fn newDate(allocator: Allocator, ms: i64) ZValueError!JSValue {
        return fromDate(try Rc(ZDate).create(allocator, ZDate.fromTimestamp(ms)));
    }

    pub fn newTemporal(allocator: Allocator, value: TemporalValue) ZValueError!JSValue {
        return fromTemporal(try Rc(TemporalValue).create(allocator, value));
    }

    pub fn newPromise(allocator: Allocator) ZValueError!JSValue {
        return fromPromise(try Rc(ZPromise(JSValue)).create(allocator, ZPromise(JSValue).init()));
    }

    pub fn newBigInt(allocator: Allocator, raw_digit_text: []const u8) BigIntError!JSValue {
        var v = try ZBigInt.fromDigitText(allocator, raw_digit_text);
        errdefer v.deinit();
        return fromBigInt(try Rc(ZBigInt).create(allocator, v));
    }

    pub fn newBigIntFromValue(allocator: Allocator, v: ZBigInt) ZValueError!JSValue {
        var owned = v;
        errdefer owned.deinit();
        return fromBigInt(try Rc(ZBigInt).create(allocator, owned));
    }

    pub fn newProxy(allocator: Allocator, target: JSValue, handler: JSValue) ZValueError!JSValue {
        errdefer {
            target.deinit();
            handler.deinit();
        }
        return fromProxy(try Rc(Proxy).create(allocator, .{ .target = target, .handler = handler }));
    }

    pub fn newArrayBuffer(allocator: Allocator, byte_length: usize) ZValueError!JSValue {
        var buf = try ArrayBuffer.init(allocator, byte_length);
        errdefer buf.deinit();
        return fromArrayBuffer(try Rc(ArrayBuffer).create(allocator, buf));
    }

    pub fn newSharedArrayBuffer(allocator: Allocator, byte_length: usize) ZValueError!JSValue {
        var buf = try ArrayBuffer.init(allocator, byte_length);
        errdefer buf.deinit();
        buf.is_shared = true;
        return fromArrayBuffer(try Rc(ArrayBuffer).create(allocator, buf));
    }

    pub fn newDataView(allocator: Allocator, owner: JSValue, byte_offset: usize, byte_length: ?usize) BufferError!JSValue {
        owner.requireTag(.array_buffer, "newDataView: owner must be .array_buffer");
        errdefer owner.deinit();
        const box = owner.asArrayBuffer();
        const view = try zbuffer.DataView.init(&box.value, byte_offset, byte_length);
        return fromDataView(try Rc(DataViewBox).create(allocator, .{ .view = view, .owner = owner }));
    }

    pub fn newTypedArray(allocator: Allocator, owner: JSValue, byte_offset: usize, len: ?usize, kind: TypedKind) BufferError!JSValue {
        owner.requireTag(.array_buffer, "newTypedArray: owner must be .array_buffer");
        errdefer owner.deinit();
        const box = owner.asArrayBuffer();
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
        return fromTypedArray(try Rc(TypedArrayBox).create(allocator, .{ .owner = owner, .byte_offset = byte_offset, .len = resolved_len, .kind = kind }));
    }

    pub fn requireTag(self: JSValue, comptime expected: Tag, comptime context: []const u8) void {
        if (self.tag() != expected) std.debug.panic(context ++ ", got .{s}", .{@tagName(self.tag())});
    }

    pub fn typeOf(self: JSValue) []const u8 {
        var cur = self;
        var slow = self;
        var advance_slow = false;
        while (cur.isProxy()) {
            cur = cur.asProxy().value.target;
            if (advance_slow) {
                slow = slow.asProxy().value.target;
                if (cur.isProxy() and cur.asProxy() == slow.asProxy()) {
                    std.debug.panic("typeOf: proxy target chain is cyclic", .{});
                }
            }
            advance_slow = !advance_slow;
        }
        return switch (cur.tag()) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .function => "function",
            .bigint => "bigint",
            .proxy => unreachable,
            .array, .object, .regex, .map, .set, .@"error", .date, .promise, .array_buffer, .data_view, .typed_array, .temporal => "object",
        };
    }

    pub fn eql(a: JSValue, b: JSValue) bool {
        return @import("equality.zig").sameValueZero(a, b);
    }

    pub fn hash(self: JSValue) u64 {
        return @import("equality.zig").hash(self);
    }

    pub inline fn retain(self: JSValue) JSValue {
        if (self.needsDeinit()) {
            switch (self.tag()) {
                .string => _ = self.asString().retain(),
                .array => _ = self.asArray().retain(),
                .object => _ = self.asObject().retain(),
                .regex => _ = self.asRegex().retain(),
                .symbol => _ = self.asSymbol().retain(),
                .map => _ = self.asMap().retain(),
                .set => _ = self.asSet().retain(),
                .@"error" => _ = self.asError().retain(),
                .function => _ = self.asFunction().retain(),
                .date => _ = self.asDate().retain(),
                .promise => _ = self.asPromise().retain(),
                .bigint => _ = self.asBigInt().retain(),
                .proxy => _ = self.asProxy().retain(),
                .array_buffer => _ = self.asArrayBuffer().retain(),
                .data_view => _ = self.asDataView().retain(),
                .typed_array => _ = self.asTypedArray().retain(),
                .temporal => _ = self.asTemporal().retain(),
                else => {},
            }
        }
        return self;
    }

    pub fn setGcHook(self: JSValue, ctx: *anyopaque, hook: *const fn (ctx: *anyopaque, box: *anyopaque) void) void {
        if (!self.needsDeinit()) return;
        switch (self.tag()) {
            .number, .undefined, .null, .boolean => {},
            .string => _ = self.asString().setGcHook(ctx, hook),
            .array => _ = self.asArray().setGcHook(ctx, hook),
            .object => _ = self.asObject().setGcHook(ctx, hook),
            .regex => _ = self.asRegex().setGcHook(ctx, hook),
            .symbol => _ = self.asSymbol().setGcHook(ctx, hook),
            .map => _ = self.asMap().setGcHook(ctx, hook),
            .set => _ = self.asSet().setGcHook(ctx, hook),
            .@"error" => _ = self.asError().setGcHook(ctx, hook),
            .function => _ = self.asFunction().setGcHook(ctx, hook),
            .date => _ = self.asDate().setGcHook(ctx, hook),
            .promise => _ = self.asPromise().setGcHook(ctx, hook),
            .bigint => _ = self.asBigInt().setGcHook(ctx, hook),
            .proxy => _ = self.asProxy().setGcHook(ctx, hook),
            .array_buffer => _ = self.asArrayBuffer().setGcHook(ctx, hook),
            .data_view => _ = self.asDataView().setGcHook(ctx, hook),
            .typed_array => _ = self.asTypedArray().setGcHook(ctx, hook),
            .temporal => _ = self.asTemporal().setGcHook(ctx, hook),
        }
    }

    pub fn deinit(self: JSValue) void {
        var pending: PendingRelease = .{};
        self.releaseInto(&pending);
        pending.drain();
    }

    const PendingRelease = struct {
        array: ?*Rc(ZArray(JSValue)) = null,
        object: ?*Rc(ZObject(JSValue)) = null,
        map: ?*Rc(ZMap(JSValue, JSValue)) = null,
        set: ?*Rc(ZSet(JSValue)) = null,
        @"error": ?*Rc(ZError(JSValue)) = null,
        function: ?*Rc(Callable) = null,
        promise: ?*Rc(ZPromise(JSValue)) = null,
        proxy: ?*Rc(Proxy) = null,

        fn push(self: *PendingRelease, comptime t: []const u8, box: @typeInfo(@FieldType(PendingRelease, t)).optional.child) void {
            std.debug.assert(box._count == 0);
            box._count = if (@field(self, t)) |head| @intFromPtr(head) else 0;
            @field(self, t) = box;
        }

        fn pop(self: *PendingRelease, comptime t: []const u8) @FieldType(PendingRelease, t) {
            const box = @field(self, t) orelse return null;
            @field(self, t) = if (box._count == 0) null else @ptrFromInt(box._count);
            box._count = 0;
            return box;
        }

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
                    for (box.value.keys()) |key| key.releaseInto(self);
                    for (box.value.values()) |value| value.releaseInto(self);
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("set")) |box| {
                    for (box.value.values()) |value| value.releaseInto(self);
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("error")) |box| {
                    if (box.value.errors) |errs| {
                        for (errs) |e| e.releaseInto(self);
                    }
                    box.value.deinit();
                    box.destroy();
                } else if (self.pop("function")) |box| {
                    if (box.value.prototype) |p| p.releaseInto(self);
                    if (box.value.statics) |st| st.releaseInto(self);
                    box.destroy();
                } else if (self.pop("promise")) |box| {
                    if (box.value.result) |r| r.releaseInto(self);
                    for (box.value.reactions.items) |reaction| {
                        if (reaction.on_fulfilled) |h| h.releaseInto(self);
                        if (reaction.on_rejected) |h| h.releaseInto(self);
                        if (reaction.derived) |d| d.releaseInto(self);
                    }
                    box.value.deinit(box.allocator);
                    box.destroy();
                } else if (self.pop("proxy")) |box| {
                    box.value.target.releaseInto(self);
                    box.value.handler.releaseInto(self);
                    box.destroy();
                } else break;
            }
        }
    };

    fn releaseInto(self: JSValue, pending: *PendingRelease) void {
        if (!self.needsDeinit()) return;
        switch (self.tag()) {
            .number, .undefined, .null, .boolean => {},
            .string => {
                const box = self.asString();
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .regex => {
                const box = self.asRegex();
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .symbol => {
                const box = self.asSymbol();
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .bigint => {
                const box = self.asBigInt();
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .array_buffer => {
                const box = self.asArrayBuffer();
                if (box.decref()) {
                    box.value.deinit();
                    box.destroy();
                }
            },
            .date => {
                const box = self.asDate();
                if (box.decref()) box.destroy();
            },
            .temporal => {
                const box = self.asTemporal();
                if (box.decref()) box.destroy();
            },
            .data_view => {
                const box = self.asDataView();
                if (box.decref()) {
                    box.value.owner.releaseInto(pending);
                    box.destroy();
                }
            },
            .typed_array => {
                const box = self.asTypedArray();
                if (box.decref()) {
                    box.value.owner.releaseInto(pending);
                    box.destroy();
                }
            },
            .array => {
                const box = self.asArray();
                if (box.decref()) pending.push("array", box);
            },
            .object => {
                const box = self.asObject();
                if (box.decref()) pending.push("object", box);
            },
            .map => {
                const box = self.asMap();
                if (box.decref()) pending.push("map", box);
            },
            .set => {
                const box = self.asSet();
                if (box.decref()) pending.push("set", box);
            },
            .@"error" => {
                const box = self.asError();
                if (box.decref()) pending.push("error", box);
            },
            .function => {
                const box = self.asFunction();
                if (box.decref()) pending.push("function", box);
            },
            .promise => {
                const box = self.asPromise();
                if (box.decref()) pending.push("promise", box);
            },
            .proxy => {
                const box = self.asProxy();
                if (box.decref()) pending.push("proxy", box);
            },
        }
    }

    pub fn objectSet(self: JSValue, key: []const u8, value: JSValue) ZObjectError!void {
        self.requireTag(.object, "objectSet: expected .object");
        const obj = &self.asObject().value;
        const old = OwnSlots.read(obj, key);
        obj.set(key, value) catch |err| {
            value.deinit();
            return err;
        };
        old.release();
    }

    pub fn objectDefine(self: JSValue, key: []const u8, value: JSValue, descriptor: PropertyDescriptor) ZObjectError!void {
        self.requireTag(.object, "objectDefine: expected .object");
        const obj = &self.asObject().value;
        const old = OwnSlots.read(obj, key);
        obj.defineProperty(key, value, descriptor) catch |err| {
            value.deinit();
            return err;
        };
        if (obj.getOwnRecordMut(key)) |rec| {
            rec.getter = null;
            rec.setter = null;
        }
        old.release();
    }

    pub fn objectDelete(self: JSValue, key: []const u8) ZObjectError!bool {
        self.requireTag(.object, "objectDelete: expected .object");
        const obj = &self.asObject().value;
        const old = OwnSlots.read(obj, key);
        const removed = try obj.delete(key);
        if (removed) old.release();
        return removed;
    }

    pub fn objectClear(self: JSValue) ZObjectError!void {
        self.requireTag(.object, "objectClear: expected .object");
        const obj = &self.asObject().value;
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

    pub fn mapSet(self: JSValue, key: JSValue, value: JSValue) ZValueError!void {
        self.requireTag(.map, "mapSet: expected .map");
        const m = &self.asMap().value;
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

    pub fn mapDelete(self: JSValue, key: JSValue) bool {
        self.requireTag(.map, "mapDelete: expected .map");
        const entry = self.asMap().value.fetchDelete(key) orelse return false;
        entry.key.deinit();
        entry.value.deinit();
        return true;
    }

    pub fn mapClear(self: JSValue) void {
        self.requireTag(.map, "mapClear: expected .map");
        const m = &self.asMap().value;
        for (m.keys()) |key| key.deinit();
        for (m.values()) |value| value.deinit();
        m.clear();
    }

    pub fn setAdd(self: JSValue, value: JSValue) ZValueError!void {
        self.requireTag(.set, "setAdd: expected .set");
        const st = &self.asSet().value;
        if (st.has(value)) {
            value.deinit();
            return;
        }
        st.add(value) catch |err| {
            value.deinit();
            return err;
        };
    }

    pub fn setDelete(self: JSValue, value: JSValue) bool {
        self.requireTag(.set, "setDelete: expected .set");
        const entry = self.asSet().value.map.fetchDelete(value) orelse return false;
        entry.key.deinit();
        return true;
    }

    pub fn setClear(self: JSValue) void {
        self.requireTag(.set, "setClear: expected .set");
        const st = &self.asSet().value;
        for (st.values()) |value| value.deinit();
        st.clear();
    }

    pub fn cloneArray(self: JSValue) ZValueError!JSValue {
        self.requireTag(.array, "cloneArray: expected .array");
        const box = self.asArray();
        var new_arr = try box.value.clone();
        errdefer new_arr.deinit();
        const new_box = try Rc(ZArray(JSValue)).create(box.allocator, new_arr);
        for (new_box.value.toSliceMut()) |*child| _ = child.retain();
        return fromArray(new_box);
    }

    pub fn cloneObject(self: JSValue) !JSValue {
        self.requireTag(.object, "cloneObject: expected .object");
        const box = self.asObject();
        var new_obj = ZObject(JSValue).init(box.allocator);
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

        return fromObject(try Rc(ZObject(JSValue)).create(box.allocator, new_obj));
    }

    pub fn cloneMap(self: JSValue) ZValueError!JSValue {
        self.requireTag(.map, "cloneMap: expected .map");
        const box = self.asMap();
        var new_map = ZMap(JSValue, JSValue).init(box.allocator);
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

        return fromMap(try Rc(ZMap(JSValue, JSValue)).create(box.allocator, new_map));
    }

    pub fn cloneSet(self: JSValue) ZValueError!JSValue {
        self.requireTag(.set, "cloneSet: expected .set");
        const box = self.asSet();
        var new_set = ZSet(JSValue).init(box.allocator);
        errdefer {
            for (new_set.values()) |value| value.deinit();
            new_set.deinit();
        }

        for (box.value.values()) |value| {
            try new_set.add(value);
            _ = value.retain();
        }

        return fromSet(try Rc(ZSet(JSValue)).create(box.allocator, new_set));
    }

    pub fn cloneError(self: JSValue) ZValueError!JSValue {
        self.requireTag(.@"error", "cloneError: expected .error");
        const box = self.asError();
        var new_err = if (box.value.errors) |errs|
            try ZError(JSValue).initAggregate(box.allocator, box.value.message, errs)
        else
            try ZError(JSValue).init(box.allocator, box.value.kind, box.value.message);
        errdefer new_err.deinit();
        const new_box = try Rc(ZError(JSValue)).create(box.allocator, new_err);
        if (new_box.value.errors) |errs| {
            for (errs) |e| _ = e.retain();
        }
        return fromError(new_box);
    }
};
