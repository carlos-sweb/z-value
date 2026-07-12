const std = @import("std");
const Allocator = std.mem.Allocator;

/// Heap-allocated reference-counting box. Wraps any standalone type (ZArray,
/// ZObject, Regex, RawString) without requiring that type to know about
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

        /// Takes ownership of an already-constructed `value`. count starts at 1.
        pub fn create(allocator: Allocator, value: T) !*Self {
            const box = try allocator.create(Self);
            box.* = .{ .count = 1, .allocator = allocator, .value = value };
            return box;
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
        /// torn down and decref() returned true.
        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self);
        }
    };
}
