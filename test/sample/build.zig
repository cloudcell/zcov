const std = @import("std");

pub fn build(b: *std.Build) void {
    const coverage = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
    const rt_path = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o object file") orelse null;

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = .Debug,
        }),
    });

    if (coverage) {
        unit_tests.sanitize_coverage_trace_pc_guard = true;
        // link_libc is required because the zig-cov runtime uses C functions
        // (atexit, getenv, fopen, etc.) that need the system C library.
        unit_tests.root_module.link_libc = true;
        // Force LLVM backend: sancov instrumentation is only inserted by LLVM's
        // codegen, not by Zig's own backend.
        unit_tests.use_llvm = true;
        if (rt_path) |p| {
            // Zig 0.17+: Use the deprecated cwd_relative variant directly.
            // This ensures the path is resolved relative to the CWD at build time.
            unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
        }
    }

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
