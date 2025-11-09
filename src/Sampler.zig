const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const wav = @import("wav.zig");

const Device = @import("Device.zig");

const Sampler = @This();

sample: wav.Sample,
pos: f32,

pub fn init(gpa: Allocator, path: []const u8) !Sampler {
    const sample = try wav.readWav(gpa, path);
    assert(sample.num_channels == 1); // TODO:
    assert(sample.bits_per_sample == 16); // TODO:
    return .{
        .sample = sample,
        .pos = 0,
    };
}
pub fn deinit(self: *Sampler, gpa: Allocator) void {
    self.sample.deinit(gpa);
}

pub fn render(self: *Sampler, buffer: []u8) void {
    const frame_len = @sizeOf(f32) * Device.num_channels;

    const src_step = @as(f32, @floatFromInt(self.sample.sample_rate)) /
        @as(f32, @floatFromInt(Device.sample_rate));

    var offset: usize = 0;
    while (offset + frame_len <= buffer.len) {
        if (@as(usize, @intFromFloat(@floor(self.pos))) >= self.sample.data.len) {
            self.pos = 0;
        }
        const src_i0: usize = @intFromFloat(@floor(self.pos));
        const src_i1: usize = src_i0 + 1;
        const frac: f32 = self.pos - @floor(self.pos);

        const s0: i16 = std.mem.bytesToValue(i16, self.sample.data[src_i0 .. src_i0 + 2]);
        const s1: i16 = std.mem.bytesToValue(i16, self.sample.data[src_i1 .. src_i1 + 2]);

        const f0: f32 = @as(f32, @floatFromInt(s0)) / 32768.0;
        const f1: f32 = @as(f32, @floatFromInt(s1)) / 32768.0;

        const sample: f32 = f0 + (f1 - f0) * frac;

        for (0..Device.num_channels) |_| {
            @memcpy(buffer[offset .. offset + 4], std.mem.asBytes(&sample));
            offset += @sizeOf(f32);
        }

        self.pos += 2 * src_step;
    }
}

pub fn interface(self: *Sampler) Device.Source {
    return .{
        .self = self,
        .render = @ptrCast(&render),
    };
}
