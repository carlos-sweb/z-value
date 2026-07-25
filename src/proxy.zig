const JSValue = @import("zvalue.zig").JSValue;

/// A JS `Proxy`: a `target`/`handler` pair. Unlike every other boxed
/// JSValue variant, Proxy has no data or algorithm of its own -- it's
/// pure trap-dispatch indirection, entirely interpreted by whoever reads
/// `target`/`handler` back out (an interpreter's property-access/call/
/// construct dispatch). Both fields are OWNED once stored (released in
/// `deinit`), but -- matching `newAggregateError`'s `errs` convention in
/// zvalue.zig -- the constructor does NOT retain them for you: the
/// caller must `.retain()` target/handler itself before handing them to
/// `JSValue.newProxy` if it still needs its own reference afterward.
pub const Proxy = struct {
    target: JSValue,
    handler: JSValue,

    pub fn deinit(self: *Proxy) void {
        self.target.deinit();
        self.handler.deinit();
    }
};
