const zvalue = @import("zvalue.zig");
const zbuffer = @import("zbuffer");
const JSValue = zvalue.JSValue;

/// A JS `DataView`: a byte-offset/length window into an `.array_buffer`
/// JSValue, plus the raw `zbuffer.DataView` that does the actual
/// get/set work. `owner` is the `.array_buffer` JSValue this view reads
/// and writes through -- `view.buffer` points at `&owner.array_buffer
/// .value`, whose address is stable for as long as this box holds a
/// reference to it.
///
/// Same convention as `Proxy` (`proxy.zig`): `owner` is OWNED once
/// stored (released in `deinit`), but the constructor does NOT retain
/// it for you -- the caller must `.retain()` the `.array_buffer` value
/// itself before handing it to `JSValue.newDataView` if it still needs
/// its own reference afterward.
pub const DataViewBox = struct {
    view: zbuffer.DataView,
    owner: JSValue,

    pub fn deinit(self: *DataViewBox) void {
        self.owner.deinit();
    }
};
