const std = @import("std");
const Allocator = std.mem.Allocator;

const RiffHeader = extern struct {
    magic: [4]u8 align(1),
    size: u32 align(1),
    format: [4]u8 align(1),
};

const FormatChunk = extern struct {
    id: [4]u8 align(1),
    size: u32 align(1),
    format: u16 align(1),
    num_channels: u16 align(1),
    sample_rate: u32 align(1),
    byte_rate: u32 align(1),
    block_align: u16 align(1),
    bits_per_sample: u16 align(1),
};

const DataHeader = extern struct {
    id: [4]u8 align(1),
    size: u32 align(1),
};

pub fn readWav(gpa: Allocator, path: []const u8) ![]const u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var read_buf: [1024]u8 = undefined;
    var reader = f.reader(&read_buf);

    const header = try reader.interface.takeStruct(RiffHeader, .little);
    if (!std.mem.eql(u8, &header.magic, "RIFF")) {
        return error.InvalidWave;
    }
    if (!std.mem.eql(u8, &header.format, "WAVE")) {
        return error.InvalidWave;
    }

    const fmt_chunk = try reader.interface.takeStruct(FormatChunk, .little);
    if (!std.mem.eql(u8, &fmt_chunk.id, "fmt ")) {
        return error.InvalidWave;
    }

    const data_head = try reader.interface.takeStruct(DataHeader, .little);
    if (!std.mem.eql(u8, &data_head.id, "data")) {
        return error.InvalidWave;
    }

    const data = try gpa.alloc(u8, data_head.size);
    defer gpa.free(data);
    try reader.interface.readSliceAll(data);

    return data;
}
