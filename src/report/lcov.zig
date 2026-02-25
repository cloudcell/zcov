//! LCOV tracefile report generator.
//!
//! Produces the standard LCOV format accepted by Codecov, Coveralls,
//! lcov/genhtml, and most CI platforms.
//!
//! Format reference: https://ltp.sourceforge.net/coverage/lcov/geninfo.1.php

const std = @import("std");
const coverage = @import("../coverage.zig");

/// Write an LCOV tracefile to `writer` from `data`.
pub fn write(writer: *std.Io.Writer, data: *const coverage.CoverageData) !void {
    for (data.files) |fc| {
        try writer.writeAll("TN:\n"); // test name (empty = default)
        try writer.print("SF:{s}\n", .{fc.path});

        // Function coverage (DA lines, then FN/FNDA)
        for (fc.functions) |fn_cov| {
            try writer.print("FN:{d},{s}\n", .{ fn_cov.start_line, fn_cov.name });
        }
        for (fc.functions) |fn_cov| {
            try writer.print("FNDA:{d},{s}\n", .{ fn_cov.hit_count, fn_cov.name });
        }
        try writer.print("FNF:{d}\n", .{fc.functions.len});
        const fns_hit = countHitFunctions(fc.functions);
        try writer.print("FNH:{d}\n", .{fns_hit});

        // Line coverage
        for (fc.lines) |lc| {
            try writer.print("DA:{d},{d}\n", .{ lc.line, lc.hit_count });
        }
        const lf = fc.lines.len;
        var lh: usize = 0;
        for (fc.lines) |lc| if (lc.hit_count > 0) {
            lh += 1;
        };
        try writer.print("LF:{d}\n", .{lf});
        try writer.print("LH:{d}\n", .{lh});

        try writer.writeAll("end_of_record\n");
    }
}

fn countHitFunctions(functions: []const coverage.FunctionCoverage) usize {
    var count: usize = 0;
    for (functions) |f| if (f.hit_count > 0) {
        count += 1;
    };
    return count;
}

test "lcov basic output" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const lines = [_]coverage.LineCoverage{
        .{ .line = 1, .hit_count = 3 },
        .{ .line = 2, .hit_count = 0 },
        .{ .line = 5, .hit_count = 1 },
    };
    const fc = coverage.FileCoverage{
        .path = "src/foo.zig",
        .lines = @constCast(&lines),
        .functions = &.{},
    };
    const data = coverage.CoverageData{
        .allocator = alloc,
        .files = @constCast(&[_]coverage.FileCoverage{fc}),
        .summary = .{
            .lines_found = 3,
            .lines_hit = 2,
            .functions_found = 0,
            .functions_hit = 0,
        },
    };

    try write(&buf.writer, &data);

    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "SF:src/foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DA:1,3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DA:2,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LF:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LH:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "end_of_record") != null);
}
