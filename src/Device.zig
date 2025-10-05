const std = @import("std");
const Allocator = std.mem.Allocator;

const pa = @import("pulseaudio");

const Synth = @import("main.zig").Synth;

pub const sample_format: pa.sample_format_t = pa.sample_format_t.FLOAT32LE;
pub const sample_rate: u32 = 48000;
pub const num_channels: u8 = 2;

const Device = @This();

main_loop: *pa.threaded_mainloop,
context: *pa.context,
context_state: pa.context.state_t,

stream: ?*pa.stream,
stream_state: pa.stream.state_t,

synth: ?*Synth,

pub fn create(gpa: Allocator) !*Device {
    const main_loop = try pa.threaded_mainloop.new();
    errdefer pa.threaded_mainloop.free(main_loop);

    const props = try pa.proplist.new();
    defer props.free();

    try props.sets("media.role", "music");
    try props.sets("media.software", "zynth");

    const context = try pa.context.new_with_proplist(
        main_loop.get_api(),
        "zynth",
        props,
    );
    errdefer context.unref();

    const self = try gpa.create(Device);
    errdefer gpa.destroy(self);

    self.* = .{
        .main_loop = main_loop,
        .context = context,
        .context_state = .UNCONNECTED,
        .stream = null,
        .stream_state = .UNCONNECTED,
        .synth = null,
    };

    try self.context.connect(null, .{}, null);
    errdefer self.context.disconnect();

    self.context.set_state_callback(contextStateCallback, self);

    try main_loop.start();
    errdefer main_loop.stop();

    {
        // Block until ready
        main_loop.lock();
        defer main_loop.unlock();

        while (true) {
            main_loop.wait();
            switch (self.context_state) {
                .READY => break,
                .FAILED => return error.ContextFailed,
                .TERMINATED => return error.ContextTerminated,
                else => continue,
            }
        }
    }

    return self;
}
pub fn destroy(self: *Device, gpa: Allocator) void {
    {
        self.main_loop.lock();
        defer self.main_loop.unlock();
        if (self.stream) |stream| {
            _ = stream.disconnect();
            stream.unref();
        }
    }
    _ = self.context.disconnect();
    self.context.unref();
    self.main_loop.stop();
    self.main_loop.free();
    gpa.destroy(self);
}

pub fn setSynth(self: *Device, synth: *Synth) !void {
    // Create output stream
    self.main_loop.lock();
    defer self.main_loop.unlock();

    self.synth = synth;

    const sample_spec: pa.sample_spec = .{
        .format = sample_format,
        .rate = sample_rate,
        .channels = num_channels,
    };

    comptime if (num_channels != 2) {
        @compileError("pls fix");
    };

    const channel_map: pa.channel_map = .{
        .channels = num_channels,
        .map = .{ .LEFT, .RIGHT } ++ .{.INVALID} ** 30,
    };

    const stream = try pa.stream.new_with_proplist(
        self.context,
        "main",
        &sample_spec,
        &channel_map,
        null,
    );
    errdefer stream.unref();

    self.stream = stream;

    stream.set_state_callback(streamStateCallback, self);
    stream.set_write_callback(streamWriteCallback, self);

    try stream.connect_playback(null, null, .{
        .START_CORKED = true,
        .INTERPOLATE_TIMING = true,
        .AUTO_TIMING_UPDATE = true,
        .FIX_FORMAT = true,
        .FIX_RATE = true,
        .FIX_CHANNELS = true,
    }, null, null);
    errdefer _ = stream.disconnect();

    while (true) {
        self.main_loop.wait();
        switch (self.stream_state) {
            .READY => break,
            .FAILED => return error.StreamFailed,
            .TERMINATED => return error.StreamTerminated,
            else => continue,
        }
    }

    // Lets go!
    const cork_op = try stream.cork(0, null, null);
    cork_op.unref();
}

fn contextStateCallback(context: *pa.context, userdata: ?*anyopaque) callconv(.c) void {
    const dev: *Device = @ptrCast(@alignCast(userdata));
    dev.context_state = context.get_state();

    switch (dev.context_state) {
        .UNCONNECTED, .CONNECTING, .AUTHORIZING, .SETTING_NAME => return,
        .READY, .FAILED, .TERMINATED => dev.main_loop.signal(0),
    }
}

fn streamStateCallback(stream: *pa.stream, userdata: ?*anyopaque) callconv(.c) void {
    const dev: *Device = @ptrCast(@alignCast(userdata));
    dev.stream_state = stream.get_state();
    switch (dev.stream_state) {
        .UNCONNECTED, .CREATING => return,
        .READY, .FAILED, .TERMINATED => dev.main_loop.signal(0),
    }
}

fn streamWriteCallback(
    stream: *pa.stream,
    requested_bytes: usize,
    userdata: ?*anyopaque,
) callconv(.c) void {
    comptime if (sample_format != .FLOAT32LE) {
        @compileError("pls fix");
    };

    const dev: *Device = @ptrCast(@alignCast(userdata));
    if (dev.synth) |synth| {
        var remaining_bytes = requested_bytes;
        while (remaining_bytes > 0) {
            var ptr_len: usize = remaining_bytes;
            var opt_ptr: ?[*]u8 = null;
            stream.begin_write(@ptrCast(&opt_ptr), &ptr_len) catch @panic("error");
            const ptr = opt_ptr orelse @panic("error");
            const write_bytes = @min(ptr_len, remaining_bytes);

            synth.render(ptr[0..write_bytes]);

            stream.write(ptr, write_bytes, null, 0, .RELATIVE) catch @panic("error");
            remaining_bytes -= write_bytes;
        }
    }
}
