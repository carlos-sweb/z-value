const std = @import("std");
const Allocator = std.mem.Allocator;

/// PLACEHOLDER payload for JSValue.string: an owned UTF-8 byte buffer, no
/// rope/small-string-optimization/UTF-16 surrogate handling. Real ECMAScript
/// String semantics (UTF-16 indexing, spec-exact methods) live in z-string,
/// which is pinned to Zig 0.15.2 and therefore not usable here yet.
///
/// This keeps the shape of JSValue stable: `string: *Rc(RawString)` becomes
/// `string: *Rc(ZString)` once z-string ports to 0.16 — a change to the
/// payload type inside the same box, not a restructuring of JSValue or any
/// call site that does `switch (value) { .string => ... }`.
pub const RawString = struct {
    bytes: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, content: []const u8) !RawString {
        return .{ .bytes = try allocator.dupe(u8, content), .allocator = allocator };
    }

    pub fn deinit(self: *RawString) void {
        self.allocator.free(self.bytes);
    }
};
