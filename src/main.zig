const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;
const posix = std.posix;

const Device = @import("Device.zig");
const Synth = @import("Synth.zig");
const wav = @import("wav.zig");

var gpa_instance: std.heap.DebugAllocator(.{}) = .{};

pub fn main() !void {
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    const dev = try Device.create(gpa);
    defer dev.destroy(gpa);

    const term: UncookedTerminal = try .init();
    defer term.deinit();

    var synth: Synth = .init();
    defer synth.deinit();

    try dev.setSource(synth.interface());

    // var sampler: Sampler = try .init(gpa, "gc.wav");
    // defer sampler.deinit(gpa);
    // try dev.setSource(sampler.interface());

    var buf: [1]u8 = undefined;

    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n > 0) {
            if (buf[0] == 'q') {
                break;
            }

            if (buf[0] == ' ') {
                synth.keyOff();
                continue;
            }

            const key: Synth.Key = switch (buf[0]) {
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
            synth.keyOn(key);
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
