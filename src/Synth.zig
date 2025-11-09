const std = @import("std");

const Device = @import("Device.zig");

const Synth = @This();

pub const State = struct {
    key: ?Key = null,
    cutoff_hz: f32 = 1200.0,
    resonance: f32 = 0.8,
};

const Voice = struct {
    phase: f32 = 0.0,
    phase_inc: f32 = 0.0,
    gate: bool = false,

    fn noteOn(self: *Voice, frequency: f32) void {
        self.phase_inc = frequency / Device.sample_rate;
        self.gate = true;
    }

    fn noteOff(self: *Voice) void {
        self.gate = false;
    }

    fn sample(self: *Voice) f32 {
        if (!self.gate or self.phase_inc == 0.0) {
            return 0.0;
        }

        self.phase += self.phase_inc;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return if (self.phase < 0.5) 1.0 else -1.0;
    }
};

const LowPassFilter = struct {
    b0: f32 = 0.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    z1: f32 = 0.0,
    z2: f32 = 0.0,

    fn init() LowPassFilter {
        var filter: LowPassFilter = .{};
        filter.setParams(1200.0, 0.8);
        return filter;
    }

    fn setParams(self: *LowPassFilter, cutoff_hz: f32, resonance: f32) void {
        const sr = Device.sample_rate;
        const fc = std.math.clamp(cutoff_hz, 20.0, sr * 0.45);
        const q = std.math.clamp(resonance, 0.1, 10.0);

        const omega = std.math.tau * fc / sr;
        const sin_w0 = std.math.sin(omega);
        const cos_w0 = std.math.cos(omega);
        const alpha = sin_w0 / (2.0 * q);
        const norm = 1.0 / (1.0 + alpha);

        self.b0 = ((1.0 - cos_w0) * 0.5) * norm;
        self.b1 = (1.0 - cos_w0) * norm;
        self.b2 = self.b0;
        self.a1 = (-2.0 * cos_w0) * norm;
        self.a2 = (1.0 - alpha) * norm;
    }

    fn process(self: *LowPassFilter, sample: f32) f32 {
        const out = sample * self.b0 + self.z1;
        self.z1 = sample * self.b1 + self.z2 - self.a1 * out;
        self.z2 = sample * self.b2 - self.a2 * out;
        return out;
    }
};

state: State = .{},
mutex: std.Thread.Mutex = .{},

voice: Voice = .{},
filter: LowPassFilter = .init(),

pub fn init() Synth {
    return .{};
}
pub fn deinit(self: *Synth) void {
    _ = self;
}

pub fn updateState(self: *Synth, state: State) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.state = state;

    if (state.key) |key| {
        self.voice.noteOn(key_to_freq[@intFromEnum(key)]);
    } else {
        self.voice.noteOff();
    }

    self.filter.setParams(state.cutoff_hz, state.resonance);
}

pub fn render(self: *Synth, buffer: []u8) void {
    comptime if (Device.sample_format != .FLOAT32LE) {
        @compileError("pls fix");
    };

    self.mutex.lock();
    defer self.mutex.unlock();

    const frame_len = @sizeOf(f32) * Device.num_channels;

    var offset: usize = 0;
    while (offset + frame_len <= buffer.len) {
        var sample = 0.2 * self.voice.sample();
        sample = self.filter.process(sample);
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
