const ztemporal = @import("ztemporal");

/// Wraps any of z-temporal's 8 instance types behind ONE `JSValue.temporal`
/// variant, instead of exploding the top-level `JSValue` union by 8 (which
/// would force every other exhaustive switch across z-value/z-interpreter
/// -- equality, typeOf, GC tracing, coercion, inspect, JSON.stringify,
/// array-method value checks, etc. -- to grow 8 new arms each). Every
/// z-temporal type is a pure value (no allocator stored, no owned memory,
/// confirmed in z-temporal's own README/phase notes -- ZonedDateTime is
/// "no owned slice, no deinit" despite needing I/O to construct/query),
/// so this union costs nothing to store or copy, and needs no per-variant
/// deinit of its own -- same shape as `ZDate` already had.
pub const TemporalValue = union(enum) {
    plain_date: ztemporal.PlainDate,
    plain_time: ztemporal.PlainTime,
    plain_date_time: ztemporal.PlainDateTime,
    plain_year_month: ztemporal.PlainYearMonth,
    plain_month_day: ztemporal.PlainMonthDay,
    instant: ztemporal.Instant,
    zoned_date_time: ztemporal.ZonedDateTime,
    duration: ztemporal.Duration,

    /// The `Temporal.XKind` name real JS reports for
    /// `Object.prototype.toString.call(x)` / `x.constructor.name`-style
    /// checks -- also doubles as this repo's own JS-facing type tag,
    /// exposed as `os`-free (engine-core) `Temporal.*` sub-namespace names.
    pub fn kindName(self: TemporalValue) []const u8 {
        return switch (self) {
            .plain_date => "Temporal.PlainDate",
            .plain_time => "Temporal.PlainTime",
            .plain_date_time => "Temporal.PlainDateTime",
            .plain_year_month => "Temporal.PlainYearMonth",
            .plain_month_day => "Temporal.PlainMonthDay",
            .instant => "Temporal.Instant",
            .zoned_date_time => "Temporal.ZonedDateTime",
            .duration => "Temporal.Duration",
        };
    }
};
