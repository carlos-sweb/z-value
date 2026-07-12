const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zarray_dep = b.dependency("zarray", .{ .target = target, .optimize = optimize });
    const zobject_dep = b.dependency("zobject", .{ .target = target, .optimize = optimize });
    const zregexp_dep = b.dependency("zregexp", .{ .target = target, .optimize = optimize });
    const zstring_dep = b.dependency("zstring", .{ .target = target, .optimize = optimize });
    const zsymbol_dep = b.dependency("zsymbol", .{ .target = target, .optimize = optimize });
    const zmap_dep = b.dependency("zmap", .{ .target = target, .optimize = optimize });
    const zset_dep = b.dependency("zset", .{ .target = target, .optimize = optimize });
    const zerror_dep = b.dependency("zerror", .{ .target = target, .optimize = optimize });
    const zarray_module = zarray_dep.module("zarray");
    const zobject_module = zobject_dep.module("zobject");
    const zregexp_module = zregexp_dep.module("zregexp");
    const zstring_module = zstring_dep.module("zstring");
    const zsymbol_module = zsymbol_dep.module("zsymbol");
    const zmap_module = zmap_dep.module("zmap");
    const zset_module = zset_dep.module("zset");
    const zerror_module = zerror_dep.module("zerror");

    const zvalue_module = b.addModule("zvalue", .{
        .root_source_file = b.path("src/zvalue.zig"),
    });
    zvalue_module.addImport("zarray", zarray_module);
    zvalue_module.addImport("zobject", zobject_module);
    zvalue_module.addImport("zregexp", zregexp_module);
    zvalue_module.addImport("zstring", zstring_module);
    zvalue_module.addImport("zsymbol", zsymbol_module);
    zvalue_module.addImport("zmap", zmap_module);
    zvalue_module.addImport("zset", zset_module);
    zvalue_module.addImport("zerror", zerror_module);

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
        unit_tests.root_module.addImport("zarray", zarray_module);
        unit_tests.root_module.addImport("zobject", zobject_module);
        unit_tests.root_module.addImport("zregexp", zregexp_module);
        unit_tests.root_module.addImport("zstring", zstring_module);
        unit_tests.root_module.addImport("zsymbol", zsymbol_module);
        unit_tests.root_module.addImport("zmap", zmap_module);
        unit_tests.root_module.addImport("zset", zset_module);
        unit_tests.root_module.addImport("zerror", zerror_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    b.default_step = test_step;
}
