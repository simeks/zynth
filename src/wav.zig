const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const RiffHeader = extern struct {
    magic: [4]u8 align(1),
    size: u32 align(1),
    format: [4]u8 align(1),
};

const FormatChunk = extern struct {
    id: [4]u8 align(1),
    size: u32 align(1),
    audio_format: u16 align(1),
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

pub const Sample = struct {
    data: []u8,
    num_channels: usize,
    sample_rate: usize,
    bits_per_sample: usize,

    pub fn deinit(self: Sample, gpa: Allocator) void {
        gpa.free(self.data);
    }
};

pub fn readWav(gpa: Allocator, path: []const u8) !Sample {
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
    if (fmt_chunk.audio_format != 1) {
        return error.NotPCM;
    }

    const data_head = try reader.interface.takeStruct(DataHeader, .little);
    if (!std.mem.eql(u8, &data_head.id, "data")) {
        return error.InvalidWave;
    }

    const data = try gpa.alloc(u8, data_head.size);
    try reader.interface.readSliceAll(data);

    return .{
        .data = data,
        .num_channels = fmt_chunk.num_channels,
        .sample_rate = fmt_chunk.sample_rate,
        .bits_per_sample = fmt_chunk.bits_per_sample,
    };
}
