//! zig-cov build script.
//! Requires Zig 0.17.0+ due to std.Io.Threaded.io() API changes, bufPrintZ removal, etc.

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
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // zig-cov-rt: runtime object file linked into instrumented test binaries.
    // We produce an object file (.o) instead of a static library (.a) because
    // Zig's linker does not search .a archives for undefined symbols when they
    // are passed as positional arguments. An object file is always fully linked.
    // Module with link_libc = true so atexit() is available.
    const rt_lib = b.addObject(.{
        .name = "zig-cov-rt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    // Install the object file to zig-out/lib/ so the integration test and
    // users' build.zig can reference it via a known path.
    const rt_install = b.addInstallFile(rt_lib.getEmittedBin(), "lib/zig-cov-rt.o");
    b.getInstallStep().dependOn(&rt_install.step);

    // Run step for the CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zig-cov");
    run_step.dependOn(&run_cmd.step);

    // Tests for zig-cov itself (main + report + coverage model).
    // link_libc = true is required because zcov_format.zig (imported transitively)
    // has tests that call fopen/fread, which need the system C library.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
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

    // Coverage model + report formatter tests.
    // Uses a dedicated root (report_tests.zig) so that DCE does not drop these
    // modules: their code is only reachable from the CLI main, which is replaced
    // by the test runner and therefore eliminated in a test binary.
    const report_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/report_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_report_tests = b.addRunArtifact(report_tests);
    test_step.dependOn(&run_report_tests.step);

    // Integration test (run with: zig build itest)
    // Builds the sample project under test/sample/ with coverage and verifies
    // that the full pipeline (sancov → .zcov → DWARF → report) is correct.
    const itest_options = b.addOptions();
    itest_options.addOption([]const u8, "sample_dir", "test/sample");
    itest_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);

    // Path relative to the sample project directory (test/sample/).
    itest_options.addOption([]const u8, "rt_lib_path", "../zig-out/lib/zig-cov-rt.o");

    const itest_exe = b.addExecutable(.{
        .name = "zig-cov-itest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    itest_exe.root_module.addOptions("build_options", itest_options);
    itest_exe.step.dependOn(b.getInstallStep()); // ensure zig-cov-rt.o is installed first

    const run_itest = b.addRunArtifact(itest_exe);
    const itest_step = b.step("itest", "Run integration tests (full pipeline: sancov → .zcov → DWARF → report)");
    itest_step.dependOn(&run_itest.step);

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
