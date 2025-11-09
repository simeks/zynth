const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const print = std.debug.print;
const posix = std.posix;

const smath = @import("smath");
const sgui = @import("sgui");
const sgpu = @import("sgpu");
const sos = @import("sos");

const Gpu = sgpu.Gpu;
const Gui = sgui.Gui;
const Window = sos.Window;
const Vec2 = smath.Vec2;

const Device = @import("Device.zig");
const Synth = @import("Synth.zig");
const Sampler = @import("Sampler.zig");

var gpa_instance: std.heap.DebugAllocator(.{}) = .{};

pub fn drawGui(gui: *Gui, state: *Synth.State) bool {
    var changed: bool = false;

    gui.beginPanel("root", .{});
    gui.label("hello world!", .{});
    if (gui.button("A", .{})) {
        changed = true;
        state.on = .a4;
    }
    if (gui.button("B", .{})) {
        changed = true;
        state.on = .b4;
    }
    if (gui.button("Off", .{})) {
        changed = true;
        state.on = null;
    }

    if (gui.knob("LP", &state.lp_cutoff, 0, 1000, .{})) {
        changed = true;
    }
    gui.endPanel();

    return changed;
}

pub fn main() !void {
    const gpa = gpa_instance.allocator();
    defer _ = gpa_instance.deinit();

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();

    const dev = try Device.create(gpa);
    defer dev.destroy(gpa);

    var state: Synth.State = .{};

    var synth: Synth = .init();
    defer synth.deinit();

    try dev.setSource(synth.interface());

    var window: Window = try .init(gpa, "boxelvox");
    defer window.deinit(gpa);

    const gpu: *Gpu = try .create(
        gpa,
        .{
            .display = window.display,
            .surface = window.surface,
        },
        .{ 800, 600 },
    );
    defer gpu.destroy();

    const gui: *Gui = try .create(gpa);
    defer gui.destroy();

    var input: Gui.InputState = .{};
    window.setMouseListener(?*Gui.InputState, handleMouse, &input);

    const gui_pass: GuiPass = try .init(arena, gpu, gui);
    defer gui_pass.deinit(gpu);

    while (window.isOpen()) {
        _ = arena_instance.reset(.retain_capacity);

        window.poll();

        const window_size = window.getSize();
        {
            gui.beginFrame(.{ @floatFromInt(window_size[0]), @floatFromInt(window_size[1]) }, input);
            defer gui.endFrame();

            if (drawGui(gui, &state)) {
                synth.updateState(state);
            }
        }

        const frame = try gpu.beginFrame(.{
            @intCast(window_size[0]),
            @intCast(window_size[1]),
        });

        const cmd = try gpu.beginCommandEncoder();

        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = frame.texture,
                .before = .undefined,
                .after = .color_attachment,
                .aspect = .{ .color = true },
            },
        } });

        gui_pass.render(gpu, cmd, frame, gui);

        cmd.barrier(&.{ .textures = &.{
            .{
                .texture = frame.texture,
                .before = .color_attachment,
                .after = .present,
                .aspect = .{ .color = true },
            },
        } });

        cmd.end();
        try gpu.submit(cmd);
        try gpu.present();
    }
    // const gui: Gui = try .init();
    // defer gui.deinit();

    // var sampler: Sampler = try .init(gpa, "gc.wav");
    // defer sampler.deinit(gpa);
    // try dev.setSource(sampler.interface());

    // var buf: [1]u8 = undefined;
    //
    // while (true) {
    //     const n = try posix.read(posix.STDIN_FILENO, &buf);
    //     if (n > 0) {
    //         if (buf[0] == 'q') {
    //             break;
    //         }
    //
    //         if (buf[0] == ' ') {
    //             synth.keyOff();
    //             continue;
    //         }
    //
    //         const key: Synth.Key = switch (buf[0]) {
    //             'a' => .c4,
    //             'w' => .cs4,
    //             's' => .d4,
    //             'e' => .ds4,
    //             'd' => .e4,
    //             'f' => .f4,
    //             't' => .fs4,
    //             'g' => .g4,
    //             'y' => .gs4,
    //             'h' => .a4,
    //             'u' => .as4,
    //             'j' => .b4,
    //             else => continue,
    //         };
    //         synth.keyOn(key);
    //     }
    //     try std.Thread.yield();
    // }
}

fn handleMouse(state: ?*Gui.InputState, event: Window.MouseEvent) void {
    if (state) |s| {
        switch (event) {
            .enter => |enter| {
                s.mouse_position = .{
                    @floatCast(enter.x),
                    @floatCast(enter.y),
                };
            },
            .leave => {
                s.mouse_left_down = false;
            },
            .motion => |motion| {
                s.mouse_position = .{
                    @floatCast(motion.x),
                    @floatCast(motion.y),
                };
            },
            .button => |button| {
                if (button.button == .left) {
                    s.mouse_left_down = button.state == .pressed;
                }
            },
        }
    }
}

pub const GuiPass = struct {
    const ShaderInput = extern struct {
        vbuf: sgpu.DeviceAddress,
        ibuf: sgpu.DeviceAddress,
        texture_index: u32,
        sampler_index: u32,
    };

    const Vertex = extern struct {
        position: smath.Vec4,
        color: smath.Vec4,
        uv: smath.Vec2,
    };

    vs: sgpu.Shader,
    fs: sgpu.Shader,

    pipeline: sgpu.RenderPipeline,
    atlas_texture: sgpu.Texture,
    atlas_view: sgpu.TextureView,
    sampler: sgpu.Sampler,

    pub fn init(
        arena: Allocator,
        gpu: *Gpu,
        gui: *const Gui,
    ) !GuiPass {
        const vs = try loadShader(arena, gpu, "gui.vert.spv");
        errdefer gpu.releaseShader(vs);

        const fs = try loadShader(arena, gpu, "gui.frag.spv");
        errdefer gpu.releaseShader(fs);

        const pipeline = try gpu.createRenderPipeline(&.{
            .vertex_shader = vs,
            .fragment_shader = fs,
            .color_attachments = .init(&.{
                .{
                    .format = gpu.surfaceFormat(),
                    .blend_enabled = true,
                    .blend_color = .{
                        .src_factor = .src_alpha,
                        .dst_factor = .one_minus_src_alpha,
                        .op = .add,
                    },
                    .blend_alpha = .{
                        .src_factor = .one,
                        .dst_factor = .one_minus_src_alpha,
                        .op = .add,
                    },
                },
            }),
            .push_constant_size = @sizeOf(ShaderInput),
        });
        errdefer gpu.releaseRenderPipeline(pipeline);

        const atlas_texture = try gpu.createTexture(&.{
            .label = "gui_atlas",
            .type = .d2,
            .usage = .{ .sampled = true },
            .size = .{
                .width = gui.atlas.width,
                .height = gui.atlas.height,
            },
            .format = .r8_unorm,
        });
        errdefer gpu.releaseTexture(atlas_texture);

        const atlas_view = try gpu.createTextureView(atlas_texture, &.{
            .label = "gui_atlas",
            .type = .d2,
            .format = .r8_unorm,
        });
        errdefer gpu.releaseTextureView(atlas_view);

        const sampler = try gpu.createSampler(&.{
            .label = "gui_sampler",
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer gpu.releaseSampler(sampler);

        try gpu.uploadTexture(atlas_texture, gui.atlas.pixels);

        return .{
            .vs = vs,
            .fs = fs,
            .pipeline = pipeline,
            .atlas_texture = atlas_texture,
            .atlas_view = atlas_view,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *const GuiPass, gpu: *Gpu) void {
        gpu.releaseTextureView(self.atlas_view);
        gpu.releaseTexture(self.atlas_texture);
        gpu.releaseSampler(self.sampler);
        gpu.releaseRenderPipeline(self.pipeline);
        gpu.releaseShader(self.vs);
        gpu.releaseShader(self.fs);
    }

    pub fn render(
        self: *const GuiPass,
        gpu: *Gpu,
        cmd: *sgpu.CommandEncoder,
        frame: sgpu.Frame,
        gui: *const Gui,
    ) void {
        var pass = cmd.beginRenderPass(&.{
            .label = "gui",
            .color_attachments = &.{
                .{
                    .view = frame.view,
                    .load_op = .clear,
                    .clear_value = .{ 0, 0, 0, 1 },
                },
            },
        });
        defer cmd.endRenderPass(pass);

        pass.bindPipeline(self.pipeline);

        const frame_size = gpu.frameSize();
        pass.setViewport(.{
            .width = @floatFromInt(frame_size.width),
            .height = @floatFromInt(frame_size.height),
        });

        pass.setScissor(.{
            .x = 0,
            .y = 0,
            .width = frame_size.width,
            .height = frame_size.height,
        });

        const draw_data = gui.getDrawData();
        if (draw_data.indices.len == 0) {
            return;
        }

        const vertex_alloc = gpu.tempAlloc(draw_data.vertices.len * @sizeOf(Vertex), @alignOf(Vertex));
        const vertices = std.mem.bytesAsSlice(Vertex, vertex_alloc.data);

        const index_alloc = gpu.tempAlloc(draw_data.indices.len * @sizeOf(u32), @alignOf(u32));
        const indices = std.mem.bytesAsSlice(u32, index_alloc.data);
        std.mem.copyForwards(u32, indices, draw_data.indices);

        for (draw_data.vertices, 0..) |src, i| {
            const x_ndc = 2.0 * src.position[0] / draw_data.display_size[0] - 1.0;
            const y_ndc = 2.0 * src.position[1] / draw_data.display_size[1] - 1.0;
            vertices[i] = .{
                .position = .{ x_ndc, y_ndc, 0.0, 1.0 },
                .color = src.color.toFloat(),
                .uv = src.uv,
            };
        }

        const shader_input: ShaderInput = .{
            .vbuf = vertex_alloc.device_addr,
            .ibuf = index_alloc.device_addr,
            .texture_index = self.atlas_view.index,
            .sampler_index = self.sampler.index,
        };
        pass.pushConstantsTyped(&shader_input);
        pass.draw(@intCast(draw_data.indices.len), 1, 0, 0);
    }
};

fn loadShader(arena: Allocator, gpu: *Gpu, path: []const u8) !sgpu.Shader {
    const exe_path = try std.fs.selfExeDirPathAlloc(arena);
    defer arena.free(exe_path);

    const shader_path = try std.fs.path.join(arena, &.{ exe_path, path });
    defer arena.free(shader_path);

    const f = try std.fs.openFileAbsolute(shader_path, .{});
    defer f.close();

    const spv = try f.readToEndAllocOptions(arena, 1024 * 1024, null, .@"4", null);
    defer arena.free(spv);

    return try gpu.createShader(&.{
        .data = spv,
        .entry = "main",
    });
}
