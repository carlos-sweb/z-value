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
///
/// Invariants:
///
/// - Single-threaded. `_count` is a plain `usize`, not atomic: a box (and
///   every JSValue reaching it) must stay on one thread. A multi-threaded
///   consumer needs a separate Arc-style type, not a flag on this one.
/// - `_count` is internal, not public API. While `JSValue.deinit()` tears
///   a tree down, a box whose count reached zero reuses `_count` as the
///   link of a pending-release list, so it can hold a pointer value instead
///   of 0. Consumers must not write it; use `retain()` / `JSValue.deinit()`,
///   and read it only through `refCount()`.
/// - Teardown order: the payload (`value`) is destroyed first, then
///   `destroy()` fires the GC hook (if any), then the box memory is freed.
pub fn Rc(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Internal refcount -- not public API, see the invariants above.
        /// The leading underscore marks it as private (Zig has no private
        /// fields); read it through `refCount()`.
        _count: usize,
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
        ///
        /// The hook runs once per box, inside `destroy()`, AFTER the
        /// payload has been destroyed and before the box memory is freed.
        /// It may use the `box` address as a key (e.g. to drop a registry
        /// entry), but it must not:
        /// - read `value` (already torn down);
        /// - read or write `_count` of this or any other box (a box queued
        ///   for release holds a list link there, not a refcount);
        /// - release, retain or destroy the box that invoked it.
        gc_hook_ctx: ?*anyopaque = null,
        gc_hook: ?*const fn (ctx: *anyopaque, box: *anyopaque) void = null,

        /// Takes ownership of an already-constructed `value`. count starts at 1.
        pub fn create(allocator: Allocator, value: T) !*Self {
            const box = try allocator.create(Self);
            box.* = .{ ._count = 1, .allocator = allocator, .value = value };
            return box;
        }

        /// Installs the GC hook (see the field doc comment). It does not
        /// call it: the hook is called later, once, by `destroy()`. A box
        /// takes one hook: calling this while a hook is already installed
        /// aborts with a panic, in every build mode, instead of silently
        /// dropping the first one. Use `clearGcHook()` first to replace it.
        /// Returns `self` so call sites can chain it onto `create()`.
        pub fn setGcHook(self: *Self, ctx: *anyopaque, hook: *const fn (ctx: *anyopaque, box: *anyopaque) void) *Self {
            if (self.gc_hook != null) {
                @branchHint(.cold);
                std.debug.panic("setGcHook: a hook is already installed; call clearGcHook first or use a single install", .{});
            }
            self.gc_hook_ctx = ctx;
            self.gc_hook = hook;
            return self;
        }

        /// Removes the GC hook, if any; `destroy()` then fires nothing.
        /// Returns `self` so call sites can chain it.
        pub fn clearGcHook(self: *Self) *Self {
            self.gc_hook_ctx = null;
            self.gc_hook = null;
            return self;
        }

        /// The current reference count, for tests and diagnostics. Not
        /// meaningful once the count has reached zero (see the invariants
        /// above).
        pub fn refCount(self: *const Self) usize {
            return self._count;
        }

        /// Increments the refcount. Returns self so call sites can chain.
        pub fn retain(self: *Self) *Self {
            self._count += 1;
            return self;
        }

        /// Decrements the refcount. Returns true if it just reached zero —
        /// the caller decides how to tear down `value` (see JSValue.deinit()),
        /// since Rc(T) doesn't know whether T holds nested JSValues.
        ///
        /// Releasing a box whose count is already 0 aborts with a panic, in
        /// every build mode (ReleaseFast included): an unbalanced
        /// retain()/decref() pair is a real bug, and this turns it into a
        /// crash instead of a silent underflow. The check is reliable only
        /// while the box memory is still allocated. A double
        /// `JSValue.deinit()` releases a box that was already freed: it is
        /// caught only if that memory still reads 0, and if the allocator
        /// has reused it, the stale release corrupts another box unseen.
        pub fn decref(self: *Self) bool {
            if (self._count == 0) {
                @branchHint(.cold);
                std.debug.panic("Rc.decref: count is {d}; release of a box with no references left (double release or unbalanced retain/decref)", .{self._count});
            }
            self._count -= 1;
            return self._count == 0;
        }

        /// Frees the box itself. Call only after `value` has already been
        /// torn down and decref() returned true. Fires the GC hook first
        /// (if set) so the embedder's registry never holds a dangling
        /// entry, even for a split second. The hook therefore sees a box
        /// whose payload is already gone (see the `gc_hook` field).
        pub fn destroy(self: *Self) void {
            if (self.gc_hook) |hook| hook(self.gc_hook_ctx.?, self);
            self.allocator.destroy(self);
        }
    };
}
