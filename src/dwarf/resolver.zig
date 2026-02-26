//! Resolves PC addresses to source file:line locations using DWARF debug info.
//!
//! Uses Zig's standard library (std.debug.Info) which supports ELF (Linux)
//! and Mach-O (macOS) out of the box.

const std = @import("std");
const builtin = @import("builtin");

pub const ResolvedLocation = struct {
    /// Absolute or relative path to the source file.
    file: []const u8,
    /// 1-based line number (0 = unknown).
    line: u32,
    /// 1-based column (0 = unknown).
    column: u32,
};

pub const ResolveError = std.debug.Info.LoadError || std.debug.Info.ResolveAddressesError || error{
    OutOfMemory,
    NoDebugInfo,
};

/// Resolves a batch of PC addresses (runtime, with ASLR slide applied) to
/// source locations.
///
/// `slide` is the ASLR slide stored in the .zcov file: subtract it from
/// each runtime PC to get the virtual address in the binary.
///
/// `pcs` should ideally be sorted ascending for best performance.
///
/// Returns a slice of ResolvedLocation parallel to `pcs`. Caller owns the
/// result; free with `allocator.free(result)`.
pub fn resolveAddresses(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    slide: i64,
    pcs: []const u64,
) ResolveError![]ResolvedLocation {
    if (pcs.len == 0) return &.{};

    // Determine object format and CPU arch from the current target.
    // (We are analyzing a binary that was built for the current host.)
    const format = builtin.object_format;
    const arch = builtin.cpu.arch;

    // Build a Build.Cache.Path for the binary.
    // std.debug.Info.load expects a Build.Cache.Path (with Io.Dir handle).
    const dirname = std.fs.path.dirname(bin_path) orelse ".";
    const dir_handle = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    const path: std.Build.Cache.Path = .{
        .root_dir = .{
            .handle = dir_handle,
            // Must be non-null so Cache.Path.toString() produces the full
            // absolute path. With path=null, toString() emits only the basename,
            // which can accidentally open a same-named directory in CWD and
            // cause mmap(EINVAL) on macOS.
            .path = dirname,
        },
        .sub_path = std.fs.path.basename(bin_path),
    };
    defer path.root_dir.handle.close(io);

    // Create the Coverage data structure that the resolver populates.
    var coverage: std.debug.Coverage = .init;
    defer coverage.deinit(allocator);

    // Load debug info.
    var info = try std.debug.Info.load(allocator, io, path, &coverage, format, arch);
    defer info.deinit(allocator);

    // Convert runtime addresses to virtual addresses (subtract ASLR slide).
    const virtual_pcs = try allocator.alloc(u64, pcs.len);
    defer allocator.free(virtual_pcs);
    for (pcs, virtual_pcs) |pc, *vpc| {
        vpc.* = if (slide >= 0)
            pc -| @as(u64, @intCast(slide))
        else
            pc + @as(u64, @intCast(-slide));
    }

    // Sort for resolveAddresses (requires ascending order).
    // We keep a sort index to map results back to original order.
    const IndexedPc = struct { pc: u64, orig_idx: usize };
    const indexed = try allocator.alloc(IndexedPc, pcs.len);
    defer allocator.free(indexed);
    for (virtual_pcs, 0..) |pc, i| indexed[i] = .{ .pc = pc, .orig_idx = i };
    std.mem.sort(IndexedPc, indexed, {}, struct {
        fn lt(_: void, a: IndexedPc, b: IndexedPc) bool {
            return a.pc < b.pc;
        }
    }.lt);

    const sorted_pcs = try allocator.alloc(u64, pcs.len);
    defer allocator.free(sorted_pcs);
    for (indexed, sorted_pcs) |ip, *sp| sp.* = ip.pc;

    // Resolve addresses.
    const raw_locs = try allocator.alloc(std.debug.Coverage.SourceLocation, pcs.len);
    defer allocator.free(raw_locs);
    try info.resolveAddresses(allocator, io, sorted_pcs, raw_locs);

    // Build output in original PC order, translating Coverage.SourceLocation
    // to our ResolvedLocation.
    const result = try allocator.alloc(ResolvedLocation, pcs.len);
    errdefer allocator.free(result);

    // Map sorted results back to original indices.
    const sorted_results = try allocator.alloc(ResolvedLocation, pcs.len);
    defer allocator.free(sorted_results);

    for (raw_locs, 0..) |raw, i| {
        sorted_results[i] = try convertSourceLocation(&coverage, allocator, raw);
    }
    for (indexed, sorted_results) |ip, sr| {
        result[ip.orig_idx] = sr;
    }

    return result;
}

fn convertSourceLocation(
    coverage: *std.debug.Coverage,
    allocator: std.mem.Allocator,
    raw: std.debug.Coverage.SourceLocation,
) !ResolvedLocation {
    if (raw.file == .invalid) {
        return .{ .file = "<unknown>", .line = 0, .column = 0 };
    }

    const file = coverage.fileAt(raw.file);
    const basename = coverage.stringAt(file.basename);

    // Reconstruct the full path: directory + "/" + basename.
    const dir_idx = file.directory_index;
    const dir_key = coverage.directories.keys()[dir_idx];
    const dir_name = coverage.stringAt(dir_key);

    const full_path = if (dir_name.len > 0)
        try std.fs.path.join(allocator, &.{ dir_name, basename })
    else
        try allocator.dupe(u8, basename);

    return .{
        .file = full_path,
        .line = raw.line,
        .column = raw.column,
    };
}
