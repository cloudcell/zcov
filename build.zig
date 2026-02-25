const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-cov CLI executable
    const exe = b.addExecutable(.{
        .name = "zig-cov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // zig-cov-rt: runtime static library linked into instrumented test binaries.
    // Module with link_libc = true so atexit() is available.
    const rt_lib = b.addLibrary(.{
        .name = "zig-cov-rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    b.installArtifact(rt_lib);

    // Run step for the CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-cov");
    run_step.dependOn(&run_cmd.step);

    // Tests for zig-cov itself (main + report + coverage model)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Runtime library tests
    const rt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_rt_tests = b.addRunArtifact(rt_tests);
    test_step.dependOn(&run_rt_tests.step);

    // Synthetic benchmarks (run with: zig build bench)
    const bench_exe = b.addExecutable(.{
        .name = "zig-cov-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run synthetic performance benchmarks");
    bench_step.dependOn(&run_bench.step);
}
