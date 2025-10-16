const std = @import("std");

const Device = @import("Device.zig");

// Atari ST
const clock_hz: f32 = 2_000_000.0;

const Synth = @This();

const Voice = struct {
    phase: f32 = 0.0,
    step: f32 = 0.0,

    fn setPeriod(self: *Voice, period: u32) void {
        const n: f32 = if (period == 0) 1.0 else @floatFromInt(period);
        const f = clock_hz / (16.0 * n);
        self.step = f / @as(f32, @floatFromInt(Device.sample_rate));
        if (!std.math.isFinite(self.step)) self.step = 0.0;
    }

    fn sample(self: *Voice) f32 {
        // Square wave
        self.phase += self.step;
        if (self.phase >= 1.0) self.phase -= 1.0;
        return if (self.phase < 0.5) 1.0 else -1.0;
    }
};

on: ?Key = null,
mutex: std.Thread.Mutex = .{},

voice1: Voice = .{},
voice2: Voice = .{ .phase = 0.1 },

pub fn init() Synth {
    return .{};
}
pub fn deinit(self: *Synth) void {
    _ = self;
}

pub fn keyOn(self: *Synth, key: Key) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.on = key;

    const freq = key_to_freq[@intFromEnum(key)];
    var period: u32 = @intFromFloat(@floor(clock_hz / (16.0 * freq)));
    if (period == 0) period = 1;

    self.voice1.setPeriod(std.math.clamp(period, 0, 0xfff));
    self.voice2.setPeriod(std.math.clamp(period, 0, 0xfff));
}
pub fn keyOff(self: *Synth) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.on = null;
}
pub fn render(self: *Synth, buffer: []u8) void {
    comptime if (Device.sample_format != .FLOAT32LE) {
        // Below we assume little-endian float
        @compileError("pls fix");
    };

    self.mutex.lock();
    defer self.mutex.unlock();

    const frame_len = @sizeOf(f32) * Device.num_channels;

    var offset: usize = 0;
    while (offset + frame_len <= buffer.len) {
        const s1: f32 = 0.25 * self.voice1.sample();
        const s2: f32 = 0.25 * self.voice2.sample();

        var sample = 0.25 * 0.5 * (s1 + s2);
        sample = std.math.clamp(sample, -0.9999, 0.9999);

        for (0..Device.num_channels) |_| {
            @memcpy(buffer[offset .. offset + 4], std.mem.asBytes(&sample));
            offset += @sizeOf(f32);
        }
    }
}

pub fn interface(self: *Synth) Device.Source {
    return .{
        .self = self,
        .render = @ptrCast(&render),
    };
}

pub const Key = enum {
    c4,
    cs4,
    d4,
    ds4,
    e4,
    f4,
    fs4,
    g4,
    gs4,
    a4,
    as4,
    b4,
};

/// https://inspiredacoustics.com/en/MIDI_note_numbers_and_center_frequencies
const key_to_freq = std.enums.directEnumArray(Key, f32, 0, .{
    .c4 = 261.63,
    .cs4 = 277.18,
    .d4 = 293.66,
    .ds4 = 311.13,
    .e4 = 329.63,
    .f4 = 349.23,
    .fs4 = 369.99,
    .g4 = 392.00,
    .gs4 = 415.30,
    .a4 = 440.00,
    .as4 = 466.16,
    .b4 = 493.88,
});
