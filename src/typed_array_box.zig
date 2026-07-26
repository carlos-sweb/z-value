const zvalue = @import("zvalue.zig");
const JSValue = zvalue.JSValue;

/// The 11 JS-visible TypedArray element kinds. `u8`/`u8_clamped` share
/// the SAME storage (`zbuffer.TypedArrayView(u8)`) -- they differ only
/// in write-coercion (`Uint8ClampedArray` clamps, `Uint8Array` wraps
/// modulo 256) and JS identity (distinct constructors/prototypes,
/// `new Uint8ClampedArray() instanceof Uint8Array` is `false` in real
/// JS). Deliberately NOT in z-buffer: "clamped" is JS-TypedArray-
/// specific framing, not a general buffer concept.
pub const TypedKind = enum {
    i8,
    u8,
    u8_clamped,
    i16,
    u16,
    i32,
    u32,
    f32,
    f64,
    i64,
    u64,

    pub fn elemSize(self: TypedKind) usize {
        return switch (self) {
            .i8, .u8, .u8_clamped => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64, .i64, .u64 => 8,
        };
    }

    pub fn isBigInt(self: TypedKind) bool {
        return self == .i64 or self == .u64;
    }
};

/// A JS TypedArray instance: an element-count/byte-offset window into an
/// `.array_buffer` JSValue, plus which of the 11 kinds it is. Same
/// convention as `DataViewBox`/`Proxy`: `owner` is OWNED once stored
/// (released in `deinit`), but the constructor does NOT retain it for
/// you -- the caller must `.retain()` the `.array_buffer` value first.
pub const TypedArrayBox = struct {
    owner: JSValue,
    byte_offset: usize,
    len: usize, // element count, not bytes
    kind: TypedKind,

    pub fn deinit(self: *TypedArrayBox) void {
        self.owner.deinit();
    }
};
