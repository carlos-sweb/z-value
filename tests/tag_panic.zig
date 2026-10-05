//! Driver for the precondition-panic checks wired in build.zig: each build of
//! this program calls ONE constructor/clone with a JSValue of the wrong
//! variant. The test step runs it and requires a SIGABRT plus the exact
//! panic message on stderr. Panics cannot be caught in-process in Zig 0.16
//! (there is no `std.testing.expectPanic`), so each case is its own process.
const std = @import("std");
const JSValue = @import("zvalue").JSValue;
const case = @import("tag_panic_case").case;

pub fn main() !void {
    const a = std.heap.page_allocator;
    const not_a_buffer = try JSValue.newObject(a);
    const wrong: JSValue = if (std.mem.eql(u8, case, "cloneObject")) try JSValue.newArray(a) else not_a_buffer;
    if (std.mem.eql(u8, case, "newDataView")) {
        _ = try JSValue.newDataView(a, wrong, 0, null);
    } else if (std.mem.eql(u8, case, "newTypedArray")) {
        _ = try JSValue.newTypedArray(a, wrong, 0, null, .u8);
    } else if (std.mem.eql(u8, case, "cloneArray")) {
        _ = try wrong.cloneArray();
    } else if (std.mem.eql(u8, case, "cloneObject")) {
        _ = try wrong.cloneObject();
    } else if (std.mem.eql(u8, case, "cloneMap")) {
        _ = try wrong.cloneMap();
    } else if (std.mem.eql(u8, case, "cloneSet")) {
        _ = try wrong.cloneSet();
    } else if (std.mem.eql(u8, case, "cloneError")) {
        _ = try wrong.cloneError();
    } else unreachable;
    // Reaching this line means the precondition did NOT abort: exit 0,
    // which the build step's SIGABRT check reports as a failure.
}
