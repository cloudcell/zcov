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

fn generateReport(
    gpa: std.mem.Allocator,
    io: std.Io,
    zcov_files: []const []const u8,
    opts: *const Opts,
) !void {
    var builder = coverage.Builder.init(gpa);
    defer builder.deinit();

    // Collect (bin_path, slide) pairs from .zcov files.
    var bin_slides: std.ArrayList(struct { path: []const u8, slide: i64 }) = .empty;
    errdefer {
        for (bin_slides.items) |bs| gpa.free(bs.path);
        bin_slides.deinit(gpa);
    }

    for (zcov_files) |zcov_path| {
        processZcovFile(gpa, io, zcov_path, &builder) catch |err| {
            std.debug.print("zig-cov: warning: failed to process '{s}': {}\n", .{ zcov_path, err });
            continue;
        };
        // Record binary info for function boundary extraction later.
        var data = zcov_format.read(gpa, io, zcov_path) catch continue;
        defer data.deinit();
        // Deduplicate: only add if not already present.
        var is_dup = false;
        for (bin_slides.items) |bs| {
            if (std.mem.eql(u8, bs.path, data.bin_path) and bs.slide == data.slide) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            try bin_slides.append(gpa, .{ .path = try gpa.dupe(u8, data.bin_path), .slide = data.slide });
        }
    }

    // Extract function boundaries for each unique binary.
    var all_func_boundaries: std.ArrayList(coverage.FunctionBoundaryMapEntry) = .empty;
    errdefer {
        for (all_func_boundaries.items) |entry| {
            gpa.free(entry.file_path);
            gpa.free(entry.functions);
        }
        all_func_boundaries.deinit(gpa);
    }

    for (bin_slides.items) |bs| {
        const func_bounds = resolver.extractFunctionBoundaries(
            gpa,
            io,
            bs.path,
            bs.slide,
        ) catch |err| {
            std.debug.print(
                "zig-cov: warning: function boundary extraction failed for '{s}': {}\n",
                .{ bs.path, err },
            );
            continue;
        };
        if (func_bounds.len > 0) {
            const entry = coverage.FunctionBoundaryMapEntry{
                .file_path = try gpa.dupe(u8, bs.path),
                .functions = try gpa.dupe(coverage.FunctionBoundary, func_bounds),
            };
            gpa.free(func_bounds);
            try all_func_boundaries.append(gpa, entry);
        }
    }
    for (bin_slides.items) |bs| gpa.free(bs.path);
    bin_slides.deinit(gpa);

    const func_bounds_slice = if (all_func_boundaries.items.len > 0)
        all_func_boundaries.items
    else
        &[_]coverage.FunctionBoundaryMapEntry{};

    var cov_data = try builder.build(func_bounds_slice);
    // Don't defer cov_data.deinit() here — we need to clean up all_func_boundaries first.

    if (cov_data.files.len == 0) {
        std.debug.print("zig-cov: no coverage data could be resolved\n", .{});
        cov_data.deinit();
        for (all_func_boundaries.items) |entry| {
            gpa.free(entry.file_path);
            gpa.free(entry.functions);
        }
        all_func_boundaries.deinit(gpa);
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
            passes = true; // fail_under only checks line coverage for summary
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

    // Clean up in reverse order.
    cov_data.deinit();
    for (all_func_boundaries.items) |entry| {
        gpa.free(entry.file_path);
        gpa.free(entry.functions);
    }
    all_func_boundaries.deinit(gpa);

    if (!passes) std.process.exit(1);
}

/// Process a single .zcov file: resolve PCs to file:line and record hits.
fn processZcovFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    zcov_path: []const u8,
    builder: *coverage.Builder,
) !void {
    var data = try zcov_format.read(gpa, io, zcov_path);
    defer data.deinit();

    if (data.pcs.len == 0) return;

    std.debug.print("zig-cov: resolving {d} PCs from {s}...\n", .{ data.pcs.len, data.bin_path });

    const locations = try resolver.resolveAddresses(
        gpa,
        io,
        data.bin_path,
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

    for (locations) |loc| {
        if (loc.line == 0) continue; // unknown location
        try builder.recordHit(loc.file, loc.line);
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