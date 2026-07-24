//! Unified coverage data model.
//! All report generators consume this representation.
//!
//! Function coverage is derived from PC-to-function mapping using
//! FunctionBoundary entries from the DWARF resolver.

const std = @import("std");

pub const SourceLocation = struct {
    /// Absolute path to the source file.
    file: []const u8,
    /// 1-based line number.
    line: u32,
    /// 1-based column (0 = unknown).
    column: u32,
};

pub const LineCoverage = struct {
    /// 1-based line number.
    line: u32,
    /// Number of times this line was executed (0 = not executed).
    hit_count: u32,
};

pub const FunctionCoverage = struct {
    /// Mangled function name as it appears in DWARF or symbol table.
    name: []const u8,
    /// 1-based line number where the function starts (0 if unknown).
    start_line: u32,
    /// Number of times the function was called (approximated from hit lines within range).
    hit_count: u32,
};

pub const FileCoverage = struct {
    /// Absolute path to the source file.
    path: []const u8,
    /// Coverage per executed line (sorted by line number, only lines that
    /// appear in DWARF are included).
    lines: []LineCoverage,
    /// Functions defined in this file.
    functions: []FunctionCoverage,
};

pub const Summary = struct {
    lines_found: u32,
    lines_hit: u32,
    functions_found: u32,
    functions_hit: u32,

    pub fn linePercent(s: Summary) f64 {
        if (s.lines_found == 0) return 100.0;
        return @as(f64, @floatFromInt(s.lines_hit)) / @as(f64, @floatFromInt(s.lines_found)) * 100.0;
    }

    pub fn functionPercent(s: Summary) f64 {
        if (s.functions_found == 0) return 100.0;
        return @as(f64, @floatFromInt(s.functions_hit)) / @as(f64, @floatFromInt(s.functions_found)) * 100.0;
    }
};

pub const CoverageData = struct {
    allocator: std.mem.Allocator,
    files: []FileCoverage,
    summary: Summary,

    pub fn deinit(self: *CoverageData) void {
        for (self.files) |fc| {
            self.allocator.free(fc.lines);
            for (fc.functions) |fn_cov| {
                self.allocator.free(fn_cov.name);
            }
            self.allocator.free(fc.functions);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

/// A function boundary tied to a specific file path.
pub const FunctionBoundaryMapEntry = struct {
    file_path: []const u8,
    functions: []const FunctionBoundary,
};

/// External function boundary info from DWARF/symbol table.
pub const FunctionBoundary = struct {
    /// Mangled function name.
    name: []const u8,
    /// 1-based line number where the function starts (0 if unknown).
    start_line: u32,
    /// Start virtual address.
    start_pc: u64,
    /// End virtual address (exclusive).
    end_pc: u64,
};

/// Builder accumulates per-file line hit counts and function hit counts, then produces CoverageData.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    /// file_path → (line → hit_count)
    file_map: std.StringHashMap(std.AutoHashMap(u32, u32)),
    /// List of recorded function hits; used during build() to populate FunctionCoverage
    function_hits: std.ArrayListUnmanaged(FunctionHitRecord),

    const FunctionHitRecord = struct {
        file_path: []const u8,
        func_name: []const u8,
        count: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .file_map = std.StringHashMap(std.AutoHashMap(u32, u32)).init(allocator),
            .function_hits = .empty,
        };
    }

    pub fn deinit(self: *Builder) void {
        var it = self.file_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.file_map.deinit();
        for (self.function_hits.items) |rec| {
            self.allocator.free(rec.file_path);
            self.allocator.free(rec.func_name);
        }
        self.function_hits.deinit(self.allocator);
    }

    /// Record that `line` in `file_path` was hit.
    /// Builder copies `file_path` on first insertion and owns the copy.
    pub fn recordHit(self: *Builder, file_path: []const u8, line: u32) !void {
        const gop = try self.file_map.getOrPut(file_path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, file_path);
            gop.value_ptr.* = std.AutoHashMap(u32, u32).init(self.allocator);
        }
        const count_gop = try gop.value_ptr.getOrPut(line);
        if (!count_gop.found_existing) {
            count_gop.value_ptr.* = 0;
        }
        count_gop.value_ptr.* += 1;
    }

    /// Record that `function_name` was hit in `file_path`.
    /// Builder copies both `file_path` and `function_name` on first insertion.
    pub fn recordFunctionHit(self: *Builder, file_path: []const u8, function_name: []const u8) !void {
        // Try to find existing record
        for (self.function_hits.items) |*rec| {
            if (std.mem.eql(u8, rec.file_path, file_path) and
                std.mem.eql(u8, rec.func_name, function_name))
            {
                rec.count += 1;
                return;
            }
        }
        // Not found, create new record
        try self.function_hits.append(self.allocator, .{
            .file_path = try self.allocator.dupe(u8, file_path),
            .func_name = try self.allocator.dupe(u8, function_name),
            .count = 1,
        });
    }

    /// Produce the final CoverageData. Caller owns the result (call deinit).
    /// `func_boundaries`: optional array of function boundaries grouped by file path.
    pub fn build(self: *Builder, func_boundaries: ?[]const FunctionBoundaryMapEntry) !CoverageData {
        var files: std.ArrayList(FileCoverage) = .empty;
        errdefer files.deinit(self.allocator);

        var summary = Summary{
            .lines_found = 0,
            .lines_hit = 0,
            .functions_found = 0,
            .functions_hit = 0,
        };

        var it = self.file_map.iterator();
        while (it.next()) |file_entry| {
            const path = file_entry.key_ptr.*;
            const line_map = file_entry.value_ptr;

            // Build sorted list of line coverages
            var lines: std.ArrayList(LineCoverage) = .empty;
            errdefer lines.deinit(self.allocator);

            var line_it = line_map.iterator();
            while (line_it.next()) |le| {
                try lines.append(self.allocator, .{ .line = le.key_ptr.*, .hit_count = le.value_ptr.* });
            }

            std.mem.sort(LineCoverage, lines.items, {}, struct {
                fn lt(_: void, a: LineCoverage, b: LineCoverage) bool {
                    return a.line < b.line;
                }
            }.lt);

            for (lines.items) |lc| {
                summary.lines_found += 1;
                if (lc.hit_count > 0) summary.lines_hit += 1;
            }

            // Look up function boundaries for this file by linear scan,
            // convert FunctionBoundary → FunctionCoverage, and apply function hits
            // from the builder's internal function_hits list.
            var func_cov: std.ArrayList(FunctionCoverage) = .empty;
            errdefer func_cov.deinit(self.allocator);
            if (func_boundaries) |bounds| {
                for (bounds) |entry| {
                    if (std.mem.eql(u8, entry.file_path, path)) {
                        summary.functions_found += @intCast(entry.functions.len);
                        for (entry.functions) |fb| {
                            const fn_name = try self.allocator.dupe(u8, fb.name);
                            // Look up hit count from function_hits list
                            var hit_count: u32 = 0;
                            for (self.function_hits.items) |rec| {
                                if (std.mem.eql(u8, rec.file_path, path) and
                                    std.mem.eql(u8, rec.func_name, fb.name))
                                {
                                    hit_count = rec.count;
                                    break;
                                }
                            }
                            try func_cov.append(self.allocator, FunctionCoverage{
                                .name = fn_name,
                                .start_line = fb.start_line,
                                .hit_count = hit_count,
                            });
                            if (hit_count > 0) summary.functions_hit += 1;
                        }
                        break;
                    }
                }
            }

            try files.append(self.allocator, .{
                .path = path,
                .lines = try lines.toOwnedSlice(self.allocator),
                .functions = try func_cov.toOwnedSlice(self.allocator),
            });
        }

        return CoverageData{
            .allocator = self.allocator,
            .files = try files.toOwnedSlice(self.allocator),
            .summary = summary,
        };
    }
};

test "Builder recordHit increments count" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("foo.zig", 5);
    try bldr.recordHit("foo.zig", 5);
    try bldr.recordHit("foo.zig", 5);

    const line_map = bldr.file_map.get("foo.zig").?;
    try std.testing.expectEqual(@as(u32, 3), line_map.get(5).?);
}

test "Builder recordHit tracks multiple files independently" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("a.zig", 1);
    try bldr.recordHit("b.zig", 2);

    try std.testing.expectEqual(@as(usize, 2), bldr.file_map.count());
    try std.testing.expectEqual(@as(u32, 1), bldr.file_map.get("a.zig").?.get(1).?);
    try std.testing.expectEqual(@as(u32, 1), bldr.file_map.get("b.zig").?.get(2).?);
}

test "Builder recordHit copies key string" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    // Allocate a key, record a hit, then free the original.
    // The builder must own its own copy so the map remains valid afterward.
    const key = try std.testing.allocator.dupe(u8, "owned.zig");
    try bldr.recordHit(key, 1);
    std.testing.allocator.free(key);

    try std.testing.expect(bldr.file_map.contains("owned.zig"));
}

test "Builder build produces sorted lines and correct summary" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("z.zig", 10);
    try bldr.recordHit("z.zig", 2);
    try bldr.recordHit("z.zig", 2); // line 2 hit twice

    var cov = try bldr.build(null);
    defer cov.deinit(); // runs before bldr.deinit() (LIFO)

    try std.testing.expectEqual(@as(usize, 1), cov.files.len);
    const lines = cov.files[0].lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    // Lines sorted by number: 2 then 10
    try std.testing.expectEqual(@as(u32, 2), lines[0].line);
    try std.testing.expectEqual(@as(u32, 2), lines[0].hit_count);
    try std.testing.expectEqual(@as(u32, 10), lines[1].line);
    try std.testing.expectEqual(@as(u32, 1), lines[1].hit_count);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.lines_found);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.lines_hit);
}

test "Builder build with function boundaries populates functions" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    try bldr.recordHit("foo.zig", 10);
    try bldr.recordHit("foo.zig", 20);

    const funcs = &[_]FunctionBoundary{
        .{ .name = "_init", .start_line = 1, .start_pc = 0x1000, .end_pc = 0x1050 },
        .{ .name = "main", .start_line = 10, .start_pc = 0x1050, .end_pc = 0x1100 },
    };
    const entries = [_]FunctionBoundaryMapEntry{
        .{ .file_path = "foo.zig", .functions = funcs[0..] },
    };

    var cov = try bldr.build(&entries);
    defer cov.deinit();

    try std.testing.expectEqual(@as(usize, 1), cov.files.len);
    try std.testing.expectEqual(@as(usize, 2), cov.files[0].functions.len);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.functions_found);
}

test "Summary linePercent and functionPercent" {
    const s = Summary{
        .lines_found = 10,
        .lines_hit = 5,
        .functions_found = 4,
        .functions_hit = 3,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), s.linePercent(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), s.functionPercent(), 0.001);
}

test "Builder recordFunctionHit tracks function hits and build uses them" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    // Must record line hits first so file exists in file_map, then record function hits
    try bldr.recordHit("foo.zig", 5); // creates the file entry
    try bldr.recordFunctionHit("foo.zig", "myFunc");
    try bldr.recordFunctionHit("foo.zig", "myFunc");
    try bldr.recordFunctionHit("foo.zig", "myFunc");
    try bldr.recordFunctionHit("foo.zig", "unusedFunc");

    // Verify by building coverage - hit_count should be reflected
    const funcs = &[_]FunctionBoundary{
        .{ .name = "myFunc", .start_line = 1, .start_pc = 0x1000, .end_pc = 0x1050 },
        .{ .name = "unusedFunc", .start_line = 10, .start_pc = 0x2000, .end_pc = 0x2050 },
    };
    const entries = [_]FunctionBoundaryMapEntry{
        .{ .file_path = "foo.zig", .functions = funcs[0..] },
    };

    var cov = try bldr.build(&entries);
    defer cov.deinit();

    try std.testing.expectEqual(@as(usize, 1), cov.files.len);
    try std.testing.expectEqual(@as(u32, 3), cov.files[0].functions[0].hit_count);
    try std.testing.expectEqual(@as(u32, 1), cov.files[0].functions[1].hit_count);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.functions_found);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.functions_hit);
}

test "Builder build populates function coverage with hit counts" {
    var bldr = Builder.init(std.testing.allocator);
    defer bldr.deinit();

    // Record line hits (required to create file entries)
    try bldr.recordHit("foo.zig", 10);
    try bldr.recordHit("foo.zig", 20);
    try bldr.recordHit("foo.zig", 30);

    // Record function hits
    try bldr.recordFunctionHit("foo.zig", "main");
    try bldr.recordFunctionHit("foo.zig", "helper");
    try bldr.recordFunctionHit("foo.zig", "helper");
    try bldr.recordFunctionHit("foo.zig", "helper");

    const funcs = &[_]FunctionBoundary{
        .{ .name = "main", .start_line = 10, .start_pc = 0x1050, .end_pc = 0x10a0 },
        .{ .name = "helper", .start_line = 20, .start_pc = 0x10a0, .end_pc = 0x10f0 },
    };
    const entries = [_]FunctionBoundaryMapEntry{
        .{ .file_path = "foo.zig", .functions = funcs[0..] },
    };

    var cov = try bldr.build(&entries);
    defer cov.deinit();

    try std.testing.expectEqual(@as(usize, 1), cov.files.len);
    try std.testing.expectEqual(@as(usize, 2), cov.files[0].functions.len);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.functions_found);
    try std.testing.expectEqual(@as(u32, 2), cov.summary.functions_hit);
}

test "Summary returns 100 percent when no items" {
    const s = Summary{
        .lines_found = 0,
        .lines_hit = 0,
        .functions_found = 0,
        .functions_hit = 0,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), s.linePercent(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), s.functionPercent(), 0.001);
}