//! zig-cov: Zig code coverage tool.
//!
//! Usage:
//!   zig-cov test [options] [-- zig-build-args...]
//!   zig-cov report [options] <zcov-file>...
//!   zig-cov --help
//!
//! Options:
//!   --format=lcov|summary     Output format (default: summary)
//!   --output=<path>           Output file path (default: stdout for summary,
//!                             coverage.lcov for lcov)
//!   --fail-under=<pct>        Exit 1 if line coverage is below this %
//!   --color=on|off|auto       Terminal color (default: auto)
//!   --project=<dir>           Project directory containing build.zig
//!                             (default: current directory)

const std = @import("std");
const builtin = @import("builtin");

const zcov_format = @import("runtime/zcov_format.zig");
const coverage = @import("coverage.zig");
const resolver = @import("dwarf/resolver.zig");
const lcov_report = @import("report/lcov.zig");
const summary_report = @import("report/summary.zig");
const orchestrator = @import("build_orchestrator.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Collect args into a slice.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    var args_iter = init.minimal.args.iterate();
    while (args_iter.next()) |arg| {
        try args_list.append(gpa, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "test")) {
        try cmdTest(gpa, io, init.environ_map, args[2..]);
    } else if (std.mem.eql(u8, cmd, "report")) {
        try cmdReport(gpa, io, args[2..]);
    } else {
        std.debug.print("zig-cov: unknown command '{s}'\n", .{cmd});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    const text =
        \\zig-cov - Zig code coverage tool
        \\
        \\Usage:
        \\  zig-cov test [options] [-- zig-build-args...]
        \\  zig-cov report [options] <file.zcov>...
        \\
        \\Commands:
        \\  test     Build with coverage, run tests, generate report
        \\  report   Generate report from existing .zcov file(s)
        \\
        \\Options:
        \\  --format=lcov|summary     Output format (default: summary)
        \\  --output=<path>           Output file (default: stdout for summary)
        \\  --fail-under=<pct>        Exit 1 if line coverage below threshold
        \\  --color=on|off|auto       Terminal color (default: auto)
        \\  --project=<dir>           Project directory (default: .)
        \\
        \\Setup (add to your build.zig):
        \\  const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
        \\  const rt_path  = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;
        \\  if (coverage) {
        \\      unit_tests.sanitize_coverage_trace_pc_guard = true;
        \\      if (rt_path) |p| unit_tests.root_module.addObjectFile(.{ .cwd_relative = p });
        \\  }
        \\
    ;
    std.debug.print("{s}", .{text});
}

// ---------------------------------------------------------------------------
// Parsed options
// ---------------------------------------------------------------------------

const Format = enum { summary, lcov };

const Opts = struct {
    format: Format = .summary,
    output: ?[]const u8 = null,
    fail_under: f64 = 0,
    color: bool = true,
    project: []const u8 = ".",
    extra_args: std.ArrayList([]const u8),

    fn deinit(self: *Opts, gpa: std.mem.Allocator) void {
        self.extra_args.deinit(gpa);
    }
};

fn parseOpts(gpa: std.mem.Allocator, raw_args: []const []const u8) !Opts {
    var opts = Opts{
        .extra_args = .empty,
    };

    var i: usize = 0;
    var after_dashdash = false;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (after_dashdash) {
            try opts.extra_args.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_dashdash = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const val = arg["--format=".len..];
            if (std.mem.eql(u8, val, "lcov")) {
                opts.format = .lcov;
            } else if (std.mem.eql(u8, val, "summary")) {
                opts.format = .summary;
            } else {
                std.debug.print("zig-cov: unknown format '{s}'\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            opts.output = arg["--output=".len..];
        } else if (std.mem.startsWith(u8, arg, "--fail-under=")) {
            const val = arg["--fail-under=".len..];
            opts.fail_under = std.fmt.parseFloat(f64, val) catch {
                std.debug.print("zig-cov: invalid --fail-under value '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--color=on")) {
            opts.color = true;
        } else if (std.mem.eql(u8, arg, "--color=off")) {
            opts.color = false;
        } else if (std.mem.startsWith(u8, arg, "--project=")) {
            opts.project = arg["--project=".len..];
        } else {
            try opts.extra_args.append(gpa, arg);
        }
    }

    return opts;
}

// ---------------------------------------------------------------------------
// `zig-cov test` command
// ---------------------------------------------------------------------------

fn cmdTest(
    gpa: std.mem.Allocator,
    io: std.Io,
    parent_environ: *std.process.Environ.Map,
    raw_args: []const []const u8,
) !void {
    var opts = try parseOpts(gpa, raw_args);
    defer opts.deinit(gpa);

    std.debug.print("zig-cov: running tests with coverage...\n", .{});

    var run_result = try orchestrator.run(.{
        .project_dir = opts.project,
        .extra_args = opts.extra_args.items,
        .allocator = gpa,
        .io = io,
        .parent_environ = parent_environ,
    });
    defer run_result.deinit();

    if (run_result.zcov_files.len == 0) {
        std.debug.print("zig-cov: no .zcov files found — did you add the build.zig integration?\n", .{});
        std.process.exit(1);
    }

    try generateReport(gpa, io, run_result.zcov_files, &opts);
}

// ---------------------------------------------------------------------------
// `zig-cov report` command
// ---------------------------------------------------------------------------

fn cmdReport(gpa: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !void {
    if (raw_args.len == 0) {
        std.debug.print("zig-cov: report: no .zcov files specified\n", .{});
        std.process.exit(1);
    }

    var opts = try parseOpts(gpa, raw_args);
    defer opts.deinit(gpa);

    // Positional args (non-option args) are the .zcov files.
    const zcov_files = opts.extra_args.items;
    try generateReport(gpa, io, zcov_files, &opts);
}

// ---------------------------------------------------------------------------
// Core: build coverage model from .zcov files, generate report
// ---------------------------------------------------------------------------

/// Helper: binary search to find which function contains a PC.
/// Functions must be sorted by start_pc (which extractFunctionBoundaries does).
fn findFunctionByPC(pcs: []const resolver.FunctionBoundary, pc: u64) ?usize {
    var lo: usize = 0;
    var hi = pcs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (pcs[mid].end_pc <= pc) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo > 0) {
        const fb = pcs[lo - 1];
        if (pc >= fb.start_pc) return lo - 1;
    }
    return null;
}

/// Track binary → .zcov files mapping.
const BinZcov = struct {
    path: []const u8,
    slide: i64,
    zcov_files: std.ArrayList([]const u8),
    func_bounds: []const resolver.FunctionBoundary,

    fn deinit(self: *BinZcov, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        // Don't free zcov_files items — they are owned by RunResult.
        self.zcov_files.deinit(gpa);
        for (self.func_bounds) |fb| gpa.free(fb.name);
        gpa.free(self.func_bounds);
    }
};

fn generateReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    zcov_files: []const []const u8,
    opts: *const Opts,
) !void {
    var builder = coverage.Builder.init(gpa);
    defer builder.deinit();

    // Track binary → .zcov files mapping.
    var bin_map: std.StringHashMap(BinZcov) = .init(gpa);
    defer {
        var it = bin_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(gpa);
        }
        bin_map.deinit();
    }

    // First pass: collect .zcov files per binary.
    for (zcov_files) |zcov_path| {
        var data = zcov_format.read(gpa, io, zcov_path) catch |err| {
            std.debug.print("zig-cov: warning: failed to read '{s}': {}\n", .{ zcov_path, err });
            continue;
        };
        defer data.deinit();

        const key = try gpa.dupe(u8, data.bin_path);
        const entry = try bin_map.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .path = key,
                .slide = data.slide,
                .zcov_files = .empty,
                .func_bounds = &.{},
            };
        }
        try entry.value_ptr.zcov_files.append(gpa, zcov_path);
    }

    // Extract function boundaries for each binary.
    var it = bin_map.iterator();
    while (it.next()) |entry| {
        const bin_entry = &entry.value_ptr.*;
        bin_entry.func_bounds = resolver.extractFunctionBoundaries(
            gpa,
            io,
            bin_entry.path,
            bin_entry.slide,
        ) catch |err| {
            std.debug.print(
                "zig-cov: warning: function boundary extraction failed for '{s}': {}\n",
                .{ bin_entry.path, err },
            );
            bin_entry.func_bounds = &.{};
            continue;
        };
    }

    // Second pass: process .zcov files with function boundaries.
    it = bin_map.iterator();
    while (it.next()) |entry| {
        const bin_entry = &entry.value_ptr.*;
        if (bin_entry.func_bounds.len == 0) continue;

        for (bin_entry.zcov_files.items) |zcov_path| {
            processZcovFileWithFuncBounds(
                gpa, io, zcov_path, bin_entry.path,
                bin_entry.func_bounds, &builder,
            ) catch |err| {
                std.debug.print("zig-cov: warning: failed to process '{s}': {}\n", .{ zcov_path, err });
            };
        }
    }

    // Build coverage data (func_boundaries not needed since we already tracked function hits).
    var cov_data = try builder.build(null);
    if (cov_data.files.len == 0) {
        std.debug.print("zig-cov: no coverage data could be resolved\n", .{});
        cov_data.deinit();
        std.process.exit(1);
    }

    // Write report using a buffer for stdout.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    var passes: bool = undefined;
    switch (opts.format) {
        .summary => {
            passes = try summary_report.write(stdout, &cov_data, .{
                .color = opts.color,
                .fail_under = opts.fail_under,
            });
            try stdout.flush();
        },
        .lcov => {
            passes = true;
            if (opts.output) |out_path| {
                var file = try std.Io.Dir.createFileAbsolute(io, out_path, .{});
                defer file.close(io);
                var file_buf: [4096]u8 = undefined;
                var file_fw = file.writer(io, &file_buf);
                try lcov_report.write(&file_fw.interface, &cov_data);
                try file_fw.interface.flush();
                std.debug.print("zig-cov: wrote LCOV to {s}\n", .{out_path});
            } else {
                try lcov_report.write(stdout, &cov_data);
                try stdout.flush();
            }
        },
    }

    cov_data.deinit();
    if (!passes) std.process.exit(1);
}

/// Process a single .zcov file: resolve PCs to file:line AND track function hits.
fn processZcovFileWithFuncBounds(
    gpa: std.mem.Allocator,
    io: std.Io,
    zcov_path: []const u8,
    bin_path: []const u8,
    func_bounds: []const resolver.FunctionBoundary,
    builder: *coverage.Builder,
) !void {
    var data = try zcov_format.read(gpa, io, zcov_path);
    defer data.deinit();

    if (data.pcs.len == 0) return;

    std.debug.print("zig-cov: resolving {d} PCs from {s}...\n", .{ data.pcs.len, data.bin_path });

    const locations = try resolver.resolveAddresses(
        gpa,
        io,
        bin_path,
        data.slide,
        data.pcs,
    );
    defer {
        for (locations) |loc| {
            if (!std.mem.eql(u8, loc.file, "<unknown>")) {
                gpa.free(loc.file);
            }
        }
        gpa.free(locations);
    }

    // Track line hits and function hits in parallel.
    for (data.pcs, locations) |pc, loc| {
        if (loc.line == 0) continue; // unknown location
        try builder.recordHit(loc.file, loc.line);

        // Find function for this PC using binary search.
        const func_idx = findFunctionByPC(func_bounds, pc);
        if (func_idx) |idx| {
            try builder.recordFunctionHit(loc.file, func_bounds[idx].name);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse opts - format lcov" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{"--format=lcov"});
    defer opts.deinit(alloc);
    try std.testing.expectEqual(Format.lcov, opts.format);
}

test "parse opts - fail under" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{"--fail-under=75.5"});
    defer opts.deinit(alloc);
    try std.testing.expectApproxEqAbs(@as(f64, 75.5), opts.fail_under, 0.001);
}

test "parse opts - extra args after --" {
    const alloc = std.testing.allocator;
    var opts = try parseOpts(alloc, &.{ "--", "-v", "--verbose" });
    defer opts.deinit(alloc);
    try std.testing.expectEqualStrings("-v", opts.extra_args.items[0]);
}