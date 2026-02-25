//! Binary format for .zcov coverage data files.
//!
//! Layout:
//!   Magic:      [4]u8  = "ZCOV"
//!   Version:    u32    = 1 (little-endian throughout)
//!   Slide:      i64    = ASLR slide: subtract from stored PCs to get virtual addrs
//!   NumPCs:     u32    = number of unique hit edge PCs stored
//!   BinPathLen: u16    = byte length of the binary path string
//!   BinPath:    [BinPathLen]u8
//!   PCs:        [NumPCs]u64 = runtime PC addresses (return addresses of hit edges)

const std = @import("std");

pub const magic: [4]u8 = "ZCOV".*;
pub const version: u32 = 1;

pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    /// ASLR slide. Subtract from each PC to obtain the virtual address as
    /// stored in DWARF debug information.
    slide: i64,
    /// Number of PC addresses that follow after the bin_path.
    num_pcs: u32,
    /// Byte length of the binary path string.
    bin_path_len: u16,
};

pub const WriteError = error{
    BinPathTooLong,
    WriteError,
} || std.mem.Allocator.Error;

// libc file operations (available since runtime links libc)
const CFile = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern "c" fn fclose(stream: *CFile) c_int;
extern "c" fn fwrite(ptr: *const anyopaque, size: usize, count: usize, stream: *CFile) usize;

/// Write a .zcov file to `path`. `pcs` are runtime (slid) PC addresses.
/// `slide` is the ASLR slide for the current process.
/// `bin_path` is the absolute path to the test binary.
/// Note: path must be null-terminated (caller provides a buf with room for sentinel).
pub fn write(
    path: [:0]const u8,
    slide: i64,
    bin_path: []const u8,
    pcs: []const u64,
) WriteError!void {
    if (bin_path.len > std.math.maxInt(u16)) return error.BinPathTooLong;

    const file = fopen(path.ptr, "wb") orelse return error.WriteError;
    defer _ = fclose(file);

    const hdr = Header{
        .magic = magic,
        .version = version,
        .slide = slide,
        .num_pcs = @intCast(pcs.len),
        .bin_path_len = @intCast(bin_path.len),
    };

    if (fwrite(&hdr, @sizeOf(Header), 1, file) != 1) return error.WriteError;
    if (bin_path.len > 0 and fwrite(bin_path.ptr, 1, bin_path.len, file) != bin_path.len)
        return error.WriteError;
    if (pcs.len > 0 and fwrite(pcs.ptr, @sizeOf(u64), pcs.len, file) != pcs.len)
        return error.WriteError;
}

pub const ReadError = error{
    InvalidMagic,
    UnsupportedVersion,
    EndOfStream,
    Overflow,
} || std.Io.Reader.Error || std.mem.Allocator.Error || std.Io.File.OpenError;

pub const ZcovData = struct {
    slide: i64,
    bin_path: []u8,
    pcs: []u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ZcovData) void {
        self.allocator.free(self.bin_path);
        self.allocator.free(self.pcs);
        self.* = undefined;
    }
};

/// Read a .zcov file. Caller owns the returned ZcovData (call deinit).
pub fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ReadError!ZcovData {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var fr = file.reader(io, &.{});

    var hdr: Header = undefined;
    fr.interface.readSliceAll(std.mem.asBytes(&hdr)) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => |e| return e,
    };

    if (!std.mem.eql(u8, &hdr.magic, &magic)) return error.InvalidMagic;
    if (hdr.version != version) return error.UnsupportedVersion;

    const bin_path = try allocator.alloc(u8, hdr.bin_path_len);
    errdefer allocator.free(bin_path);
    if (bin_path.len > 0) {
        fr.interface.readSliceAll(bin_path) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => |e| return e,
        };
    }

    const pcs = try allocator.alloc(u64, hdr.num_pcs);
    errdefer allocator.free(pcs);
    if (pcs.len > 0) {
        fr.interface.readSliceAll(std.mem.sliceAsBytes(pcs)) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => |e| return e,
        };
    }

    return ZcovData{
        .slide = hdr.slide,
        .bin_path = bin_path,
        .pcs = pcs,
        .allocator = allocator,
    };
}
