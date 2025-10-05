const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;
const posix = std.posix;

const Device = @import("Device.zig");
const wav = @import("wav.zig");

var gpa_instance: std.heap.DebugAllocator(.{}) = .{};

pub fn main() !void {
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    const dev = try Device.create(gpa);
    defer dev.destroy(gpa);

    const term: UncookedTerminal = try .init();
    defer term.deinit();

    var synth: Synth = .{};

    var sampler: Sampler = try .init(gpa, "gc.wav");
    defer sampler.deinit(gpa);

    try dev.setSource(sampler.interface());

    var buf: [1]u8 = undefined;

    // Ugly hack to detect keyboard releases, gotta do this proper because
    // now it's dependent on keyboard delay and repeat rate
    var last_t = try std.time.Timer.start();

    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n > 0) {
            if (buf[0] == 'q') {
                break;
            }

            const key: Key = switch (buf[0]) {
                'a' => .c4,
                'w' => .cs4,
                's' => .d4,
                'e' => .ds4,
                'd' => .e4,
                'f' => .f4,
                't' => .fs4,
                'g' => .g4,
                'y' => .gs4,
                'h' => .a4,
                'u' => .as4,
                'j' => .b4,
                else => continue,
            };
            last_t = try std.time.Timer.start();
            synth.keyOn(key);
        } else {
            if (last_t.read() > 100 * std.time.ns_per_ms) {
                synth.keyOff();
                last_t = try std.time.Timer.start();
            }
        }

        try std.Thread.yield();
    }
}

/// Puts the terminal into uncooked mode, allowing for keyboard inputs
/// Restores terminal state on deinit()
const UncookedTerminal = struct {
    original: posix.termios,
    original_flags: usize,

    pub fn init() !UncookedTerminal {
        // https://zig.news/lhp/want-to-create-a-tui-application-the-basics-of-uncooked-terminal-io-17gm

        const original: posix.termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        errdefer {
            // Restore original termios
            posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch @panic("ouch");
        }
        var raw: posix.termios = original;

        // Disable Ctrl-S and Ctrl-Q
        raw.iflag.IXON = false;
        // Disable conversion of carriage returns to newline
        raw.iflag.ICRNL = false;

        // Disable output processing
        raw.oflag.OPOST = false;

        // Don't display presed keys
        raw.lflag.ECHO = false;
        // Disable cooked input mode
        raw.lflag.ICANON = false;
        // Disable signals for Ctrl-C and Ctrl-Z
        // raw.lflag.ISIG = false;
        // Disable input preprocessing
        raw.lflag.IEXTEN = false;

        // Set to non-blocking
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);

        const original_flags: usize = try posix.fcntl(posix.STDIN_FILENO, posix.F.GETFL, 0);
        errdefer {
            // Restore flags
            _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, original_flags) catch @panic("ouch");
        }

        // SET O_NONBLOCK
        var flags: usize = original_flags;
        flags |= @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"));
        _ = try posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, flags);

        return .{
            .original = original,
            .original_flags = original_flags,
        };
    }
    pub fn deinit(self: UncookedTerminal) void {
        // Restore flags
        _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, self.original_flags) catch
            @panic("ouch");
        // Restore original termios
        posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch
            @panic("ouch");
    }
};

const Key = enum {
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

pub const Synth = struct {
    on: ?Key = null,
    mutex: std.Thread.Mutex = .{},

    phase: f32 = 0.0,

    pub fn keyOn(self: *Synth, key: Key) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.on = key;
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
            if (self.on) |note| {
                const freq = key_to_freq[@intFromEnum(note)];
                const phase_inc = 2.0 * std.math.pi * freq / @as(f32, @floatFromInt(Device.sample_rate));
                self.phase += phase_inc;
                if (self.phase >= 2.0 * std.math.pi) {
                    self.phase -= 2.0 * std.math.pi;
                }
            } else {
                self.phase = 0;
            }

            const sample: f32 = 0.6 * @sin(self.phase);
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
};

pub const Sampler = struct {
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
};
