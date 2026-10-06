//! Driver for the Rc zero-counter check wired in build.zig. Each build of
//! this program runs ONE case:
//!   - "doubleRelease": decref() on a box whose count is already 0. The
//!     box is created and released through `Rc` directly and never
//!     destroyed, so its memory is still valid and the count reads exactly
//!     0. That makes the case deterministic; a double `JSValue.deinit()`
//!     would release a box that is already freed, and what its count then
//!     reads depends on the allocator. The build step requires a SIGABRT
//!     plus the panic message, in every build mode including ReleaseFast.
//!   - "doubleGcHook": a second `setGcHook` on a box that already has a
//!     hook, through `JSValue.setGcHook` (the path embedders use). The
//!     build step requires a SIGABRT plus the panic message.
//!   - "balanced": correct retain/release pairs, on `Rc` and through
//!     `JSValue`, and a hook replaced via `clearGcHook()` that then fires
//!     exactly once. The build step requires a clean exit.
//! Panics cannot be caught in-process in Zig 0.16 (there is no
//! `std.testing.expectPanic`), so each case is its own process.
const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const Rc = zvalue.Rc;
const case = @import("rc_panic_case").case;

fn countHook(ctx: *anyopaque, box: *anyopaque) void {
    _ = box;
    const fired: *usize = @ptrCast(@alignCast(ctx));
    fired.* += 1;
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    if (std.mem.eql(u8, case, "doubleRelease")) {
        const box = try Rc(u32).create(a, 7);
        if (!box.decref()) return error.FirstReleaseDidNotReachZero;
        _ = box.decref(); // must abort here
        // Reaching this line means decref did NOT abort: exit 0, which the
        // build step's SIGABRT check reports as a failure.
    } else if (std.mem.eql(u8, case, "doubleGcHook")) {
        var fired: usize = 0;
        const v = try JSValue.newString(a, "hooked");
        v.setGcHook(&fired, countHook);
        v.setGcHook(&fired, countHook); // must abort here
    } else if (std.mem.eql(u8, case, "balanced")) {
        const box = try Rc(u32).create(a, 7);
        _ = box.retain();
        if (box.decref()) return error.ReleasedTooEarly;
        if (!box.decref()) return error.LastReleaseDidNotReachZero;
        box.destroy();

        const s = try JSValue.newString(a, "balanced");
        _ = s.retain();
        s.deinit();
        s.deinit();

        var first: usize = 0;
        var second: usize = 0;
        const h = try Rc(u32).create(a, 7);
        _ = h.setGcHook(&first, countHook).clearGcHook().setGcHook(&second, countHook);
        if (h.refCount() != 1) return error.WrongRefCount;
        if (!h.decref()) return error.LastReleaseDidNotReachZero;
        h.destroy();
        if (first != 0 or second != 1) return error.HookFiredWrong;
    } else unreachable;
}
