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

    /// No-op: a Callable owns nothing of its own to release. Whatever
    /// `ctx` points at is the installer's responsibility to manage (e.g.
    /// an interpreter arena-allocating closure contexts and never freeing
    /// them individually).
    pub fn deinit(self: *Callable) void {
        _ = self;
    }
};
