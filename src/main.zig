const std = @import("std");
const Allocator = std.mem.Allocator;

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

var gpa_instance: std.heap.DebugAllocator(.{}) = .{};

const keyboard_keys = [_]struct { key: Synth.Key, label: []const u8 }{
    .{ .key = .c4, .label = "C" },
    .{ .key = .cs4, .label = "C#" },
    .{ .key = .d4, .label = "D" },
    .{ .key = .ds4, .label = "D#" },
    .{ .key = .e4, .label = "E" },
    .{ .key = .f4, .label = "F" },
    .{ .key = .fs4, .label = "F#" },
    .{ .key = .g4, .label = "G" },
    .{ .key = .gs4, .label = "G#" },
    .{ .key = .a4, .label = "A" },
    .{ .key = .as4, .label = "A#" },
    .{ .key = .b4, .label = "B" },
};

pub fn drawGui(gui: *Gui, state: *Synth.State) bool {
    if (gui.display_size[0] == 0 or gui.display_size[1] == 0) {
        return false;
    }
    var changed: bool = false;

    gui.beginPanel("root", .{
        .padding = .{ 24.0, 24.0 },
        .spacing = 18.0,
    });
    defer gui.endPanel();

    gui.label("Zynth", .{ .size = 40, .color = gui.style.accent_color });

    {
        gui.beginPanel("filter_panel", .{ .direction = .horizontal, .spacing = 16.0 });
        defer gui.endPanel();

        {
            gui.beginPanel("Cutoff", .{ .direction = .vertical, .spacing = 4.0 });
            defer gui.endPanel();

            if (gui.knob("cutoff", &state.cutoff_hz, 20.0, 2000.0, .{})) {
                changed = true;
            }
            gui.labelFmt("Cutoff\n{d:.0} Hz", .{state.cutoff_hz}, .{});
        }

        {
            gui.beginPanel("Q", .{ .direction = .vertical, .spacing = 4.0 });
            defer gui.endPanel();

            if (gui.knob("q", &state.resonance, 0.0, 10.0, .{})) {
                changed = true;
            }
            gui.labelFmt("Q\n{d:.2}", .{state.resonance}, .{});
        }
    }

    changed |= drawKeyboard(gui, state);

    return changed;
}

/// Draws an interactive keyboard
fn drawKeyboard(gui: *Gui, state: *Synth.State) bool {
    const Color = sgui.Color;
    const Rect = sgui.Rect;
    const Interact = enum {
        none,
        hover,
        held,
    };

    const white_base: Color = .rgb(245, 245, 245);
    const white_hover: Color = .rgb(255, 255, 255);
    const black_base: Color = .rgb(20, 20, 20);
    const black_hover: Color = .rgb(60, 60, 60);

    const next_pos = gui.nextPosition();
    const mouse_position = gui.input.mouse_position;

    const label_size = 14;

    const keyboard_rect = gui.reserveRect(.{
        gui.display_size[0] - 48.0,
        gui.display_size[1] - next_pos[1] - 24.0,
    });
    gui.main_commands.append(gui.gpa, .{
        .rect = .{
            .rect = keyboard_rect,
            .color = gui.style.panel_background_color,
        },
    }) catch @panic("oom");

    var changed: bool = false;

    if (state.key != null and !gui.input.mouse_left_down) {
        state.key = null;
        changed = true;
    }

    const white_indices = .{ 0, 2, 4, 5, 7, 9, 11 };
    const black_indices = .{ 1, 3, 6, 8, 10 };

    const white_width = keyboard_rect.width / @as(f32, @floatFromInt(white_indices.len));
    const black_width = white_width * 0.6;
    const black_shift = .{ 1, 2, 4, 5, 6 };

    var hovered_key: ?Synth.Key = null;

    // Gather input first to ensure black keys get prio
    inline for (0.., black_indices) |i, key_idx| {
        const rect: Rect = .{
            .x = keyboard_rect.x + white_width * black_shift[i] - 0.5 * black_width,
            .y = keyboard_rect.y,
            .width = black_width,
            .height = keyboard_rect.height * 0.6,
        };

        if (hovered_key == null and rect.containsPoint(mouse_position)) {
            hovered_key = keyboard_keys[key_idx].key;
        }
    }
    inline for (0.., white_indices) |i, key_idx| {
        const rect: Rect = .{
            .x = keyboard_rect.x + white_width * @as(f32, @floatFromInt(i)),
            .y = keyboard_rect.y,
            .width = white_width,
            .height = keyboard_rect.height,
        };

        if (hovered_key == null and rect.containsPoint(mouse_position)) {
            hovered_key = keyboard_keys[key_idx].key;
        }
    }

    if (gui.input.mouse_left_down and hovered_key != state.key) {
        state.key = hovered_key;
        changed = true;
    }

    // Draw keys

    // Add padding for drawing only, for input we want uninterrupted sliding between keys
    const key_padding = 2;

    inline for (0.., white_indices) |i, key_idx| {
        const rect: Rect = .{
            .x = keyboard_rect.x + white_width * @as(f32, @floatFromInt(i)),
            .y = keyboard_rect.y,
            .width = white_width - 2.0 * key_padding,
            .height = keyboard_rect.height,
        };

        var interact: Interact = .none;
        if (hovered_key) |hovered| {
            if (hovered == keyboard_keys[key_idx].key) {
                interact = if (gui.input.mouse_left_down)
                    .held
                else
                    .hover;
            }
        }

        const label = keyboard_keys[key_idx].label;

        const text_size = gui.measureText(label, .{ .size = label_size });
        gui.main_commands.appendSlice(gui.gpa, &.{
            .{
                .rect = .{
                    .rect = rect,
                    .color = switch (interact) {
                        .none => white_base,
                        .hover => white_hover,
                        .held => gui.style.accent_color,
                    },
                },
            },
            .{
                .text = .{
                    .position = .{
                        rect.x + (rect.width - text_size[0]) * 0.5,
                        rect.y + rect.height - label_size - 6.0,
                    },
                    .text = label,
                    .color = .rgb(40, 40, 40),
                    .size = label_size,
                },
            },
        }) catch @panic("oom");
    }

    inline for (0.., black_indices) |i, key_idx| {
        const rect: Rect = .{
            .x = keyboard_rect.x + white_width * black_shift[i] - 0.5 * black_width + key_padding,
            .y = keyboard_rect.y,
            .width = black_width - 2.0 * key_padding,
            .height = keyboard_rect.height * 0.6,
        };

        var interact: Interact = .none;
        if (hovered_key) |hovered| {
            if (hovered == keyboard_keys[key_idx].key) {
                interact = if (gui.input.mouse_left_down)
                    .held
                else
                    .hover;
            }
        }

        const label = keyboard_keys[key_idx].label;

        const text_size = gui.measureText(label, .{ .size = label_size });
        gui.main_commands.appendSlice(gui.gpa, &.{
            .{
                .rect = .{
                    .rect = rect,
                    .color = switch (interact) {
                        .none => black_base,
                        .hover => black_hover,
                        .held => gui.style.accent_color,
                    },
                },
            },
            .{
                .text = .{
                    .position = .{
                        rect.x + (rect.width - text_size[0]) * 0.5,
                        rect.y + rect.height - label_size - 6.0,
                    },
                    .text = label,
                    .color = .white,
                    .size = label_size,
                },
            },
        }) catch @panic("oom");
    }

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

    var synth: Synth = .init();
    defer synth.deinit();

    var state: Synth.State = .{};
    synth.updateState(state);

    try dev.setSource(synth.interface());

    var window: Window = try .init(gpa, "zynth");
    defer window.deinit(gpa);

    const gpu: *Gpu = try .create(
        gpa,
        .{
            .display = window.display,
            .surface = window.surface,
        },
        .{ 800, 500 },
    );
    defer gpu.destroy();

    const gui: *Gui = try .create(gpa);
    defer gui.destroy();

    var input: Gui.InputState = .{};
    window.setMouseListener(?*Gui.InputState, mouseListener, &input);

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
}

fn mouseListener(state: ?*Gui.InputState, event: Window.MouseEvent) void {
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
