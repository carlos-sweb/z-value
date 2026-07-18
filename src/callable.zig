const std = @import("std");
const Allocator = std.mem.Allocator;
const JSValue = @import("zvalue.zig").JSValue;

/// A native or user-defined callable, invoked via `call`. `ctx` is an
/// opaque pointer whose concrete type is owned entirely by whatever
/// installs the callable (a host/native function, or an interpreter's
/// closure representation) -- z-value never dereferences it, keeping this
/// repo independent of any parser/AST/interpreter family. `anyerror`
/// (rather than a closed error set) is deliberate: invoking arbitrary
/// interpreted code can fail for reasons z-value has no way to enumerate
/// in advance (allocation failure, an interpreter's own ad hoc errors,
/// eventually thrown JS exceptions).
pub const Callable = struct {
    ctx: *anyopaque,
    name: []const u8 = "",
    /// Declared parameter count (excludes rest/defaults), for `.length`.
    arity: usize = 0,
    call: *const fn (ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue,
    /// Lazily-created `prototype` property (constructor semantics) -- null
    /// until first touched by an interpreter. Always an `.object` JSValue
    /// when set. Managed entirely by whoever installs the callable (e.g.
    /// an interpreter arena-allocating it); never released here.
    prototype: ?JSValue = null,
    /// Whether `new` may be applied to this callable. Arrows and
    /// host/native functions are not constructors (real spec behavior);
    /// an interpreter's ordinary function/function-expression closures
    /// set this true.
    constructable: bool = false,
    /// Lazily-created property bag for everything else assigned onto the
    /// function (`F.myProp = 1`, class statics). Same contract as
    /// `prototype`: null until first touched, always an `.object` JSValue
    /// when set, managed entirely by the installer. Static inheritance
    /// (`class B extends A` seeing `A.staticMethod` through `B`) falls
    /// out of chaining this bag's ZObject prototype to the parent's bag.
    statics: ?JSValue = null,

    /// No-op: a Callable owns nothing of its own to release. Whatever
    /// `ctx` points at is the installer's responsibility to manage (e.g.
    /// an interpreter arena-allocating closure contexts and never freeing
    /// them individually).
    pub fn deinit(self: *Callable) void {
        _ = self;
    }
};
