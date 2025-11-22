const std = @import("std");

const Device = @import("Device.zig");

const Synth = @This();

pub const EnvelopeParams = struct {
    attack_ms: f32 = 5.0,
    release_ms: f32 = 150.0,
};

pub const Waveform = enum(usize) {
    sine,
    saw,
    square,
    triangle,
};

pub const State = struct {
    key: ?Key = null,
    waveform1: Waveform = .square,
    waveform2: Waveform = .square,
    shift_st: f32 = 0.0,
    octave: i32 = 4,
    cutoff_hz: f32 = 1200.0,
    resonance: f32 = 0.8,
    env: EnvelopeParams = .{},
};

const Voice = struct {
    phase: f32 = 0.0,
    phase_inc: f32 = 0.0,
    gate: bool = false,
    waveform: Waveform = .square,

    fn noteOn(self: *Voice, frequency: f32) void {
        self.phase_inc = frequency / Device.sample_rate;
        self.gate = true;
    }

    fn noteOff(self: *Voice) void {
        self.gate = false;
    }

    fn sample(self: *Voice) f32 {
        if (self.phase_inc == 0.0) {
            return 0.0;
        }

        self.phase += self.phase_inc;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return switch (self.waveform) {
            .sine => @sin(std.math.tau * self.phase),
            .saw => 2.0 * self.phase - 1.0,
            .square => if (self.phase < 0.5) 1.0 else -1.0,
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5),
        };
    }
};

const Envelope = struct {
    params: EnvelopeParams,
    attack_step: f32,
    release_step: f32,
    value: f32,

    fn init() Envelope {
        return .{
            .params = .{},
            .attack_step = 1.0,
            .release_step = 1.0,
            .value = 0.0,
        };
    }

    fn setParams(self: *Envelope, params: EnvelopeParams) void {
        self.params = params;
        self.attack_step = timeToStep(self.params.attack_ms);
        self.release_step = timeToStep(self.params.release_ms);
    }

    fn process(self: *Envelope, target: f32) f32 {
        if (target > self.value) {
            self.value = @min(self.value + self.attack_step, target);
        } else {
            self.value = @max(self.value - self.release_step, target);
        }
        return self.value;
    }

    fn timeToStep(ms: f32) f32 {
        if (ms <= 0.0) return 1.0;

        const samples = @as(f32, @floatFromInt(Device.sample_rate)) * ms / std.time.ms_per_s;
        if (samples <= 1.0) return 1.0;

        return 1.0 / samples;
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

state: State,
mutex: std.Thread.Mutex,

voice1: Voice,
voice2: Voice,
filter: LowPassFilter,
env: Envelope,

prev_shift: f32,

pub fn init() Synth {
    return .{
        .state = .{},
        .mutex = .{},
        .voice1 = .{},
        .voice2 = .{},
        .filter = .init(),
        .env = .init(),
        .prev_shift = 0.0,
    };
}
pub fn deinit(self: *Synth) void {
    _ = self;
}

pub fn updateState(self: *Synth, state: State) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.state = state;

    if (state.key) |key| {
        // A bit hacky but its to sync the phase when removing the shift
        if (state.shift_st == 0.0 and self.prev_shift != 0.0) {
            self.voice2.phase = self.voice1.phase;
        }
        self.prev_shift = state.shift_st;

        const base_freq = keyFrequency(key, state.octave);
        self.voice1.noteOn(base_freq);
        self.voice2.noteOn(base_freq * std.math.pow(f32, 2.0, state.shift_st / 12.0));
    } else {
        self.voice1.noteOff();
        self.voice2.noteOff();
    }
    self.voice1.waveform = state.waveform1;
    self.voice2.waveform = state.waveform2;

    self.filter.setParams(state.cutoff_hz, state.resonance);
    self.env.setParams(state.env);
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
        const s1 = self.voice1.sample();
        const s2 = self.voice2.sample();

        var sample = self.filter.process((s1 + s2) * 0.5);

        const env_value = self.env.process(if (self.voice1.gate) 1.0 else 0.0);
        if (!self.voice1.gate and env_value <= 0.0001) {
            self.voice1.phase_inc = 0.0;
            self.voice2.phase_inc = 0.0;
        }

        sample = 0.2 * env_value * sample;
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
    c,
    cs,
    d,
    ds,
    e,
    f,
    fs,
    g,
    gs,
    a,
    as,
    b,
};

const key_to_freq = std.enums.directEnumArray(Key, f32, 0, .{
    .c = 261.63,
    .cs = 277.18,
    .d = 293.66,
    .ds = 311.13,
    .e = 329.63,
    .f = 349.23,
    .fs = 369.99,
    .g = 392.00,
    .gs = 415.30,
    .a = 440.00,
    .as = 466.16,
    .b = 493.88,
});

fn keyFrequency(key: Key, octave: i32) f32 {
    const base = key_to_freq[@intFromEnum(key)];
    const octave_offset = octave - 4;
    if (octave_offset == 0) return base;
    return base * std.math.pow(f32, 2.0, @floatFromInt(octave_offset));
}
