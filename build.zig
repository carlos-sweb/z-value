const std = @import("std");

// Every sibling z-* dependency's package name matches its module name
// (e.g. "zarray" -> module "zarray") -- one list drives the dependency
// fetch, the module lookup, and every addImport call site below, so a
// new dependency only needs one line added here.
const dep_names = [_][]const u8{
    "zarray",    "zobject", "zregex", "zstring",  "zsymbol", "zmap",
    "zset",      "zerror",  "zdate",  "zpromise", "zbigint", "zbuffer",
    "ztemporal",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var dep_modules: [dep_names.len]*std.Build.Module = undefined;
    inline for (dep_names, 0..) |name, i| {
        const dep = b.dependency(name, .{ .target = target, .optimize = optimize });
        dep_modules[i] = dep.module(name);
    }

    const zvalue_module = b.addModule("zvalue", .{
        .root_source_file = b.path("src/zvalue.zig"),
    });
    inline for (dep_names, 0..) |name, i| {
        zvalue_module.addImport(name, dep_modules[i]);
    }

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/value_types_test.zig",
        "tests/rc_test.zig",
        "tests/array_test.zig",
        "tests/object_test.zig",
        "tests/regex_test.zig",
        "tests/symbol_test.zig",
        "tests/map_test.zig",
        "tests/set_test.zig",
        "tests/error_test.zig",
        "tests/equality_test.zig",
        "tests/callable_test.zig",
        "tests/date_test.zig",
        "tests/bigint_test.zig",
        "tests/proxy_test.zig",
        "tests/data_view_box_test.zig",
        "tests/typed_array_box_test.zig",
        "tests/temporal_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });

        unit_tests.root_module.addImport("zvalue", zvalue_module);
        inline for (dep_names, 0..) |name, i| {
            unit_tests.root_module.addImport(name, dep_modules[i]);
        }

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    b.default_step = test_step;
}
