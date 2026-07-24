const std = @import("std");
const Allocator = std.mem.Allocator;

/// Heap-allocated reference-counting box. Wraps any standalone type (ZArray,
/// ZObject, Regex, ZString) without requiring that type to know about
/// refcounting at all — z-value owns the counting, the wrapped library stays
/// standalone.
///
/// Deliberately "dumb": it does not call `value.deinit()` automatically when
/// the count reaches zero, because the destruction policy differs by T (some
/// wrapped types contain nested JSValues that must be released first). That
/// policy lives in JSValue.deinit(), which calls `decref()` and then decides
/// what to do with `value` itself.
pub fn Rc(comptime T: type) type {
    return struct {
        const Self = @This();

        count: usize,
        allocator: Allocator,
        value: T,
        /// GC hook (optional, unused unless an embedder sets it): an opaque
        /// callback invoked right before this box's memory is freed in
        /// `destroy()`, whether that's triggered by an ordinary
        /// refcount-to-zero or by a future embedder-side cycle collector
        /// force-freeing an unreachable box. Lets the embedder keep an
        /// external "all live GC objects" registry in sync without z-value
        /// knowing anything about that registry -- same ctx+fn-pointer
        /// decoupling already used for `Callable.ctx`/`call`.
        gc_hook_ctx: ?*anyopaque = null,
        gc_hook: ?*const fn (ctx: *anyopaque, box: *anyopaque) void = null,

        /// Takes ownership of an already-constructed `value`. count starts at 1.
        pub fn create(allocator: Allocator, value: T) !*Self {
            const box = try allocator.create(Self);
            box.* = .{ .count = 1, .allocator = allocator, .value = value };
            return box;
        }

        /// Sets the GC hook (see the field doc comment). Returns `self` so
        /// call sites can chain it onto `create()`.
        pub fn setGcHook(self: *Self, ctx: *anyopaque, hook: *const fn (ctx: *anyopaque, box: *anyopaque) void) *Self {
            self.gc_hook_ctx = ctx;
            self.gc_hook = hook;
            return self;
        }

        /// Increments the refcount. Returns self so call sites can chain.
        pub fn retain(self: *Self) *Self {
            self.count += 1;
            return self;
        }

        /// Decrements the refcount. Returns true if it just reached zero —
        /// the caller decides how to tear down `value` (see JSValue.deinit()),
        /// since Rc(T) doesn't know whether T holds nested JSValues.
        ///
        /// Asserts the count never underflows: an unbalanced retain()/decref()
        /// pair is a real bug, and this turns it into a crash instead of silent
        /// corruption — but only in Debug/ReleaseSafe builds; in ReleaseFast
        /// this assert is compiled out and underflow is undefined behavior.
        pub fn decref(self: *Self) bool {
            std.debug.assert(self.count > 0);
            self.count -= 1;
            return self.count == 0;
        }

        /// Frees the box itself. Call only after `value` has already been
        /// torn down and decref() returned true. Fires the GC hook first
        /// (if set) so the embedder's registry never holds a dangling
        /// entry, even for a split second.
        pub fn destroy(self: *Self) void {
            if (self.gc_hook) |hook| hook(self.gc_hook_ctx.?, self);
            self.allocator.destroy(self);
        }
    };
}
