const std = @import("std");
const builtin = @import("builtin");

const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const saudio = sokol.audio;
const slog = sokol.log;

const c = @import("cimgui.zig").c;

const is_web = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .emscripten;

const GridSize = 24;
const GridHalf = GridSize / 2;
const VoxelSize: f32 = 0.22;
const SphereRadiusVoxels: f32 = 9.2;
const MaxLights = 8;
const FovY: f32 = std.math.pi / 3.1;
const NearPlane: f32 = 0.05;
const FarPlane: f32 = 80.0;
const DragThreshold: f32 = 5.0;
const PinchZoomSensitivity: f32 = 0.012;
const EraseBeepFreqHz: f32 = 920.0;
const EraseBeepDurationSec: f32 = 0.08;
const EraseBeepGain: f32 = 0.12;

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Ray = struct {
    origin: Vec3,
    dir: Vec3,
};

const Light = struct {
    enabled: bool = true,
    position: [3]f32 = .{ 3.2, 2.8, 3.1 },
    color: [3]f32 = .{ 1.0, 0.95, 0.85 },
    intensity: f32 = 1.4,
};

const PointerKind = enum {
    none,
    mouse,
    touch,
};

const AppState = struct {
    pass_action: sg.PassAction = .{},
    scene_pipeline: sgl.Pipeline = .{},

    voxels: [GridSize * GridSize * GridSize]bool = [_]bool{false} ** (GridSize * GridSize * GridSize),
    voxel_count: usize = 0,
    initial_voxel_count: usize = 1,

    lights: [MaxLights]Light = undefined,
    light_count: usize = 0,

    camera_yaw: f32 = 0.75,
    camera_pitch: f32 = 0.5,
    camera_distance: f32 = 7.0,

    pointer_kind: PointerKind = .none,
    pointer_id: usize = 0,
    pointer_active: bool = false,
    pointer_dragging: bool = false,
    pointer_start_x: f32 = 0.0,
    pointer_start_y: f32 = 0.0,
    pointer_last_x: f32 = 0.0,
    pointer_last_y: f32 = 0.0,
    pinch_active: bool = false,
    pinch_id0: usize = 0,
    pinch_id1: usize = 0,
    pinch_last_distance: f32 = 0.0,

    status: [256]u8 = [_]u8{0} ** 256,

    audio_phase: f32 = 0.0,
    audio_sample_rate: f32 = 44100.0,
    audio_erase_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    audio_last_erase_counter: u32 = 0,
    audio_beep_frames_left: i32 = 0,
    audio_beep_total_frames: i32 = 0,
    audio_ready: bool = false,

    initialized: bool = false,

    fn init(self: *AppState) void {
        self.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0.075, .g = 0.08, .b = 0.105, .a = 1.0 },
        };
        self.pass_action.depth = .{
            .load_action = .CLEAR,
            .clear_value = 1.0,
        };

        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });

        const sc = sglue.swapchain();
        sgl.setup(.{
            .color_format = sc.color_format,
            .depth_format = sc.depth_format,
            .sample_count = sc.sample_count,
            .logger = .{ .func = slog.func },
        });
        self.scene_pipeline = sgl.makePipeline(.{
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
        });

        simgui.setup(.{
            .logger = .{ .func = slog.func },
        });
        c.igStyleColorsDark(null);

        saudio.setup(.{
            .stream_userdata_cb = audioStream,
            .user_data = self,
            .logger = .{ .func = slog.func },
        });
        self.audio_ready = saudio.isvalid();
        if (self.audio_ready) {
            const sr_i = saudio.sampleRate();
            if (sr_i > 0) {
                self.audio_sample_rate = @floatFromInt(sr_i);
            }
        }

        self.light_count = 0;
        self.addDefaultLight(.{ 3.2, 2.8, 3.1 }, .{ 1.0, 0.95, 0.85 }, 1.4);
        self.addDefaultLight(.{ -2.7, 1.6, -2.9 }, .{ 0.46, 0.74, 1.0 }, 1.0);

        self.resetVoxelSphere();
        self.setStatus("Drag to rotate. Click/tap to erase a voxel.");
        self.initialized = true;
    }

    fn cleanup(self: *AppState) void {
        if (self.scene_pipeline.id != 0) {
            sgl.destroyPipeline(self.scene_pipeline);
            self.scene_pipeline = .{};
        }
        if (self.audio_ready) {
            saudio.shutdown();
            self.audio_ready = false;
        }
        simgui.shutdown();
        sgl.shutdown();
        sg.shutdown();
    }

    fn frame(self: *AppState) void {
        if (!self.initialized) return;

        var dt: f32 = @floatCast(sapp.frameDuration());
        if (!(dt > 0.0 and dt < 0.25)) dt = 1.0 / 60.0;

        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = dt,
            .dpi_scale = sapp.dpiScale(),
        });

        self.drawUi();

        sg.beginPass(.{
            .action = self.pass_action,
            .swapchain = sglue.swapchain(),
        });

        self.drawScene();
        sgl.draw();

        simgui.render();
        sg.endPass();
        sg.commit();
    }

    fn handleEvent(self: *AppState, ev: sapp.Event) void {
        const consumed = simgui.handleEvent(ev);

        switch (ev.type) {
            .MOUSE_DOWN => {
                if (ev.mouse_button == .LEFT) {
                    self.pointerDown(.mouse, 0, ev.mouse_x, ev.mouse_y, consumed);
                }
            },
            .MOUSE_MOVE => {
                self.pointerMove(.mouse, 0, ev.mouse_x, ev.mouse_y);
            },
            .MOUSE_UP => {
                if (ev.mouse_button == .LEFT) {
                    self.pointerUp(.mouse, 0, ev.mouse_x, ev.mouse_y, consumed);
                }
            },
            .MOUSE_SCROLL => {
                if (!consumed) self.zoomBy(-ev.scroll_y * 0.35);
            },
            .TOUCHES_BEGAN => self.handleTouchBegan(ev, consumed),
            .TOUCHES_MOVED => self.handleTouchMoved(ev),
            .TOUCHES_ENDED, .TOUCHES_CANCELLED => self.handleTouchEnded(ev, consumed),
            .KEY_DOWN => {
                if (!ev.key_repeat) {
                    switch (ev.key_code) {
                        .SPACE => self.resetVoxelSphere(),
                        .L => _ = self.addLight(),
                        .BACKSPACE => self.removeLight(),
                        .R => self.resetCamera(),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn drawUi(self: *AppState) void {
        const viewport_w = @max(1.0, sapp.widthf());
        const viewport_h = @max(1.0, sapp.heightf());
        const is_compact = viewport_w <= 900.0 or viewport_h <= 640.0;
        const is_portrait = viewport_h > viewport_w;
        const margin: f32 = if (is_compact) 8.0 else 14.0;

        if (is_compact) {
            const max_w: f32 = if (is_portrait)
                viewport_w - margin * 2.0
            else
                @min(420.0, viewport_w * 0.48);
            const panel_w = std.math.clamp(max_w, 250.0, viewport_w - margin * 2.0);
            const desired_h: f32 = if (is_portrait) viewport_h * 0.56 else viewport_h - margin * 2.0;
            const max_h = viewport_h - margin * 2.0;
            const panel_h = std.math.clamp(desired_h, @min(230.0, max_h), max_h);

            c.igSetNextWindowPos(v2(margin, margin), c.ImGuiCond_Always, v2(0.0, 0.0));
            c.igSetNextWindowSize(v2(panel_w, panel_h), c.ImGuiCond_Always);
        } else {
            c.igSetNextWindowPos(v2(14.0, 14.0), c.ImGuiCond_FirstUseEver, v2(0.0, 0.0));
            c.igSetNextWindowSize(v2(390.0, 680.0), c.ImGuiCond_FirstUseEver);
        }

        const compact_flags: c.ImGuiWindowFlags = if (is_compact)
            c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoResize
        else
            0;
        const window_flags: c.ImGuiWindowFlags = c.ImGuiWindowFlags_NoCollapse | compact_flags;

        _ = c.igBegin("Voxel Editor", null, window_flags);
        defer c.igEnd();

        uiText("Targets: desktop + android + ios + web", .{});
        uiText("Renderer: sokol + imgui + wasm/webgl", .{});
        uiText("Audio: sokol_audio ({s})", .{if (self.audio_ready) "enabled" else "unavailable"});
        if (is_web and self.audio_ready and saudio.suspended()) {
            uiText("WebAudio suspended: tap/click scene once.", .{});
        }
        c.igSeparator();

        const content_w = @max(140.0, c.igGetContentRegionAvail().x);
        const two_cols = content_w >= 320.0;
        const row_btn_w: f32 = if (two_cols) (content_w - 8.0) * 0.5 else content_w;

        if (c.igButton("Reset Sphere [Space]", v2(row_btn_w, 0.0))) self.resetVoxelSphere();
        if (two_cols) c.igSameLine(0.0, 8.0);
        if (c.igButton("Reset Camera [R]", v2(row_btn_w, 0.0))) self.resetCamera();

        if (c.igButton("Add Light [L]", v2(row_btn_w, 0.0))) {
            if (!self.addLight()) self.setStatus("Max lights reached.");
        }
        if (two_cols) c.igSameLine(0.0, 8.0);
        if (c.igButton("Remove Light [Backspace]", v2(row_btn_w, 0.0))) self.removeLight();

        c.igSeparator();
        uiText("Controls", .{});
        uiText("- Drag (mouse/finger): rotate sphere", .{});
        uiText("- Click/tap: erase one voxel", .{});
        uiText("- Two-finger pinch: zoom", .{});
        uiText("- Mouse wheel: zoom", .{});
        uiText("- Audio: plays only on voxel erase", .{});
        uiText("Voxels remaining: {d}/{d}", .{ self.voxel_count, self.initial_voxel_count });
        uiText("Lights: {d}/{d}", .{ self.light_count, MaxLights });

        c.igSeparator();
        for (self.lights[0..self.light_count], 0..) |*light, i| {
            c.igPushID_Int(@intCast(i));
            defer c.igPopID();

            var label_buf: [48]u8 = undefined;
            const label_z = std.fmt.bufPrintZ(&label_buf, "Light {d}", .{i + 1}) catch continue;
            if (c.igCollapsingHeader_TreeNodeFlags(label_z.ptr, c.ImGuiTreeNodeFlags_DefaultOpen)) {
                _ = c.igCheckbox("Enabled", &light.enabled);
                _ = c.igSliderFloat3("Position", &light.position, -6.0, 6.0, "%.2f", 0);
                _ = c.igColorEdit3("Color", &light.color, 0);
                _ = c.igSliderFloat("Intensity", &light.intensity, 0.0, 4.0, "%.2f", 0);
            }
        }

        c.igSeparator();
        uiText("Status", .{});
        c.igTextUnformatted(self.status[0..].ptr, null);
    }

    fn drawScene(self: *AppState) void {
        const w = @max(1.0, sapp.widthf());
        const h = @max(1.0, sapp.heightf());
        const aspect = w / h;

        const camera = self.cameraPosition();

        sgl.defaults();
        sgl.matrixModeProjection();
        sgl.loadIdentity();
        sgl.perspective(FovY, aspect, NearPlane, FarPlane);

        sgl.matrixModeModelview();
        sgl.loadIdentity();
        sgl.lookat(camera.x, camera.y, camera.z, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0);

        sgl.pushPipeline();
        defer sgl.popPipeline();
        if (self.scene_pipeline.id != 0) {
            sgl.loadPipeline(self.scene_pipeline);
        }

        self.drawAxes();
        self.drawVoxels();
        self.drawLightMarkers();
    }

    fn drawAxes(self: *AppState) void {
        _ = self;
        sgl.beginLines();

        sgl.c4f(1.0, 0.42, 0.42, 1.0);
        sgl.v3f(-3.0, 0.0, 0.0);
        sgl.v3f(3.0, 0.0, 0.0);

        sgl.c4f(0.45, 1.0, 0.45, 1.0);
        sgl.v3f(0.0, -3.0, 0.0);
        sgl.v3f(0.0, 3.0, 0.0);

        sgl.c4f(0.45, 0.64, 1.0, 1.0);
        sgl.v3f(0.0, 0.0, -3.0);
        sgl.v3f(0.0, 0.0, 3.0);

        sgl.end();
    }

    fn drawLightMarkers(self: *AppState) void {
        sgl.pointSize(8.0);
        sgl.beginPoints();
        for (self.lights[0..self.light_count]) |*light| {
            if (!light.enabled) continue;
            sgl.c4f(light.color[0], light.color[1], light.color[2], 1.0);
            sgl.v3f(light.position[0], light.position[1], light.position[2]);
        }
        sgl.end();
    }

    fn drawVoxels(self: *AppState) void {
        const h = VoxelSize * 0.5;
        sgl.beginTriangles();
        for (0..GridSize) |z| {
            for (0..GridSize) |y| {
                for (0..GridSize) |x| {
                    if (!self.isVoxelFilled(x, y, z)) continue;

                    const center = self.voxelCenter(x, y, z);
                    const base = self.baseColor(y);

                    if (!self.isVoxelFilledOffset(x, y, z, 1, 0, 0)) {
                        self.emitFace(
                            base,
                            v3(1.0, 0.0, 0.0),
                            v3(center.x + h, center.y, center.z),
                            v3(center.x + h, center.y - h, center.z - h),
                            v3(center.x + h, center.y + h, center.z - h),
                            v3(center.x + h, center.y + h, center.z + h),
                            v3(center.x + h, center.y - h, center.z + h),
                        );
                    }
                    if (!self.isVoxelFilledOffset(x, y, z, -1, 0, 0)) {
                        self.emitFace(
                            base,
                            v3(-1.0, 0.0, 0.0),
                            v3(center.x - h, center.y, center.z),
                            v3(center.x - h, center.y - h, center.z + h),
                            v3(center.x - h, center.y + h, center.z + h),
                            v3(center.x - h, center.y + h, center.z - h),
                            v3(center.x - h, center.y - h, center.z - h),
                        );
                    }
                    if (!self.isVoxelFilledOffset(x, y, z, 0, 1, 0)) {
                        self.emitFace(
                            base,
                            v3(0.0, 1.0, 0.0),
                            v3(center.x, center.y + h, center.z),
                            v3(center.x - h, center.y + h, center.z - h),
                            v3(center.x - h, center.y + h, center.z + h),
                            v3(center.x + h, center.y + h, center.z + h),
                            v3(center.x + h, center.y + h, center.z - h),
                        );
                    }
                    if (!self.isVoxelFilledOffset(x, y, z, 0, -1, 0)) {
                        self.emitFace(
                            base,
                            v3(0.0, -1.0, 0.0),
                            v3(center.x, center.y - h, center.z),
                            v3(center.x - h, center.y - h, center.z + h),
                            v3(center.x - h, center.y - h, center.z - h),
                            v3(center.x + h, center.y - h, center.z - h),
                            v3(center.x + h, center.y - h, center.z + h),
                        );
                    }
                    if (!self.isVoxelFilledOffset(x, y, z, 0, 0, 1)) {
                        self.emitFace(
                            base,
                            v3(0.0, 0.0, 1.0),
                            v3(center.x, center.y, center.z + h),
                            v3(center.x + h, center.y - h, center.z + h),
                            v3(center.x + h, center.y + h, center.z + h),
                            v3(center.x - h, center.y + h, center.z + h),
                            v3(center.x - h, center.y - h, center.z + h),
                        );
                    }
                    if (!self.isVoxelFilledOffset(x, y, z, 0, 0, -1)) {
                        self.emitFace(
                            base,
                            v3(0.0, 0.0, -1.0),
                            v3(center.x, center.y, center.z - h),
                            v3(center.x - h, center.y - h, center.z - h),
                            v3(center.x - h, center.y + h, center.z - h),
                            v3(center.x + h, center.y + h, center.z - h),
                            v3(center.x + h, center.y - h, center.z - h),
                        );
                    }
                }
            }
        }
        sgl.end();
    }

    fn emitFace(
        self: *AppState,
        base: Vec3,
        normal: Vec3,
        face_center: Vec3,
        a: Vec3,
        b: Vec3,
        c0: Vec3,
        d: Vec3,
    ) void {
        const lit = self.litColor(base, normal, face_center);
        emitTri(a, b, c0, lit);
        emitTri(a, c0, d, lit);
    }

    fn litColor(self: *AppState, base: Vec3, normal: Vec3, world_pos: Vec3) Vec3 {
        var color = scale(base, 0.18);

        for (self.lights[0..self.light_count]) |light| {
            if (!light.enabled) continue;

            const light_pos = v3(light.position[0], light.position[1], light.position[2]);
            const to_light = sub(light_pos, world_pos);
            const dist2 = dot(to_light, to_light) + 0.08;
            const inv_dist = 1.0 / @sqrt(dist2);
            const light_dir = scale(to_light, inv_dist);
            const ndotl = @max(0.0, dot(normal, light_dir));
            if (ndotl <= 0.0) continue;

            const atten = light.intensity / (1.0 + dist2 * 0.35);
            const light_rgb = v3(light.color[0], light.color[1], light.color[2]);
            color = add(color, scale(hadamard(base, light_rgb), ndotl * atten));
        }

        return clamp01(color);
    }

    fn resetVoxelSphere(self: *AppState) void {
        @memset(&self.voxels, false);
        self.voxel_count = 0;

        const r2 = SphereRadiusVoxels * SphereRadiusVoxels;
        for (0..GridSize) |z| {
            const fz = @as(f32, @floatFromInt(@as(i32, @intCast(z)) - @as(i32, GridHalf))) + 0.5;
            for (0..GridSize) |y| {
                const fy = @as(f32, @floatFromInt(@as(i32, @intCast(y)) - @as(i32, GridHalf))) + 0.5;
                for (0..GridSize) |x| {
                    const fx = @as(f32, @floatFromInt(@as(i32, @intCast(x)) - @as(i32, GridHalf))) + 0.5;
                    const d2 = fx * fx + fy * fy + fz * fz;
                    if (d2 <= r2) {
                        const idx = self.voxelIndex(x, y, z);
                        self.voxels[idx] = true;
                        self.voxel_count += 1;
                    }
                }
            }
        }

        self.initial_voxel_count = self.voxel_count;
        self.setStatusFmt("Sphere reset: {d} voxels.", .{self.voxel_count});
    }

    fn resetCamera(self: *AppState) void {
        self.camera_yaw = 0.75;
        self.camera_pitch = 0.5;
        self.camera_distance = 7.0;
    }

    fn addDefaultLight(self: *AppState, pos: [3]f32, color: [3]f32, intensity: f32) void {
        if (self.light_count >= MaxLights) return;
        self.lights[self.light_count] = .{
            .enabled = true,
            .position = pos,
            .color = color,
            .intensity = intensity,
        };
        self.light_count += 1;
    }

    fn addLight(self: *AppState) bool {
        if (self.light_count >= MaxLights) return false;

        const idx = self.light_count;
        const angle = @as(f32, @floatFromInt(idx)) * 0.85;
        const r: f32 = 3.4;

        self.lights[idx] = .{
            .enabled = true,
            .position = .{ @cos(angle) * r, 1.7 + @sin(angle * 0.9), @sin(angle) * r },
            .color = .{
                std.math.clamp(0.45 + 0.55 * @cos(angle * 1.1), 0.1, 1.0),
                std.math.clamp(0.45 + 0.55 * @sin(angle * 1.7 + 1.2), 0.1, 1.0),
                std.math.clamp(0.45 + 0.55 * @cos(angle * 0.7 + 0.8), 0.1, 1.0),
            },
            .intensity = 1.15,
        };

        self.light_count += 1;
        self.setStatusFmt("Added light #{d}.", .{self.light_count});
        return true;
    }

    fn removeLight(self: *AppState) void {
        if (self.light_count <= 1) {
            self.setStatus("At least one light is kept.");
            return;
        }
        self.light_count -= 1;
        self.setStatusFmt("Removed light. {d} remaining.", .{self.light_count});
    }

    fn pointerDown(self: *AppState, kind: PointerKind, id: usize, x: f32, y: f32, consumed: bool) void {
        if (consumed or self.pointer_active or self.pinch_active) return;

        self.pointer_active = true;
        self.pointer_dragging = false;
        self.pointer_kind = kind;
        self.pointer_id = id;
        self.pointer_start_x = x;
        self.pointer_start_y = y;
        self.pointer_last_x = x;
        self.pointer_last_y = y;
    }

    fn pointerMove(self: *AppState, kind: PointerKind, id: usize, x: f32, y: f32) void {
        if (!self.pointerMatches(kind, id)) return;

        const dx = x - self.pointer_last_x;
        const dy = y - self.pointer_last_y;

        if (!self.pointer_dragging) {
            const sx = x - self.pointer_start_x;
            const sy = y - self.pointer_start_y;
            if ((sx * sx + sy * sy) >= (DragThreshold * DragThreshold)) {
                self.pointer_dragging = true;
            }
        }

        if (self.pointer_dragging) {
            self.camera_yaw += dx * 0.012;
            self.camera_pitch = std.math.clamp(self.camera_pitch + dy * 0.012, -1.42, 1.42);
        }

        self.pointer_last_x = x;
        self.pointer_last_y = y;
    }

    fn pointerUp(self: *AppState, kind: PointerKind, id: usize, x: f32, y: f32, consumed: bool) void {
        if (!self.pointerMatches(kind, id)) return;

        const is_click = !self.pointer_dragging;
        self.pointer_active = false;
        self.pointer_dragging = false;
        self.pointer_kind = .none;

        if (is_click and !consumed) {
            if (self.eraseVoxelAtScreen(x, y)) {
                self.triggerEraseBeep();
                self.setStatusFmt("Erased voxel. Remaining: {d}", .{self.voxel_count});
            } else {
                self.setStatus("No voxel hit.");
            }
        }
    }

    fn pointerMatches(self: *AppState, kind: PointerKind, id: usize) bool {
        return self.pointer_active and self.pointer_kind == kind and self.pointer_id == id;
    }

    fn zoomBy(self: *AppState, delta: f32) void {
        self.camera_distance = std.math.clamp(self.camera_distance + delta, 3.0, 18.0);
    }

    fn handleTouchBegan(self: *AppState, ev: sapp.Event, consumed: bool) void {
        if (consumed) return;

        const n: usize = @intCast(@max(ev.num_touches, 0));
        if (n >= 2) {
            self.beginPinch(ev);
            return;
        }
        if (self.pointer_active) return;

        for (ev.touches[0..n]) |t| {
            if (!t.changed) continue;
            self.pointerDown(.touch, t.identifier, t.pos_x, t.pos_y, false);
            break;
        }
    }

    fn handleTouchMoved(self: *AppState, ev: sapp.Event) void {
        if (self.pinch_active) {
            var x0: f32 = 0.0;
            var y0: f32 = 0.0;
            var x1: f32 = 0.0;
            var y1: f32 = 0.0;

            if (findTouchById(ev, self.pinch_id0, &x0, &y0) and findTouchById(ev, self.pinch_id1, &x1, &y1)) {
                const dist = touchDistance(x0, y0, x1, y1);
                if (dist > 0.0 and self.pinch_last_distance > 0.0) {
                    const delta = dist - self.pinch_last_distance;
                    self.zoomBy(-delta * PinchZoomSensitivity);
                }
                self.pinch_last_distance = dist;
                return;
            }

            const n: usize = @intCast(@max(ev.num_touches, 0));
            if (n >= 2) {
                self.beginPinch(ev);
            } else {
                self.endPinch();
            }
            return;
        }

        if (!self.pointer_active or self.pointer_kind != .touch) return;

        const n: usize = @intCast(@max(ev.num_touches, 0));
        for (ev.touches[0..n]) |t| {
            if (t.identifier == self.pointer_id) {
                self.pointerMove(.touch, t.identifier, t.pos_x, t.pos_y);
                break;
            }
        }
    }

    fn handleTouchEnded(self: *AppState, ev: sapp.Event, consumed: bool) void {
        if (self.pinch_active) {
            const n: usize = @intCast(@max(ev.num_touches, 0));
            if (n >= 2 and self.continuePinchFromEnded(ev)) {
                return;
            }
            self.endPinch();
            return;
        }

        if (!self.pointer_active or self.pointer_kind != .touch) return;

        const n: usize = @intCast(@max(ev.num_touches, 0));
        for (ev.touches[0..n]) |t| {
            if (t.identifier == self.pointer_id) {
                self.pointerUp(.touch, t.identifier, t.pos_x, t.pos_y, consumed);
                break;
            }
        }
    }

    fn beginPinch(self: *AppState, ev: sapp.Event) void {
        const n: usize = @intCast(@max(ev.num_touches, 0));
        if (n < 2) return;

        const t0 = ev.touches[0];
        const t1 = ev.touches[1];

        self.pointer_active = false;
        self.pointer_dragging = false;
        self.pointer_kind = .none;

        self.pinch_active = true;
        self.pinch_id0 = t0.identifier;
        self.pinch_id1 = t1.identifier;
        self.pinch_last_distance = touchDistance(t0.pos_x, t0.pos_y, t1.pos_x, t1.pos_y);
    }

    fn continuePinchFromEnded(self: *AppState, ev: sapp.Event) bool {
        const n: usize = @intCast(@max(ev.num_touches, 0));
        if (n < 2) return false;

        var found: usize = 0;
        var id0: usize = 0;
        var id1: usize = 0;
        var x0: f32 = 0.0;
        var y0: f32 = 0.0;
        var x1: f32 = 0.0;
        var y1: f32 = 0.0;

        for (ev.touches[0..n]) |t| {
            if (t.changed) continue;
            if (found == 0) {
                id0 = t.identifier;
                x0 = t.pos_x;
                y0 = t.pos_y;
                found = 1;
            } else {
                id1 = t.identifier;
                x1 = t.pos_x;
                y1 = t.pos_y;
                found = 2;
                break;
            }
        }
        if (found < 2) return false;

        self.pinch_active = true;
        self.pinch_id0 = id0;
        self.pinch_id1 = id1;
        self.pinch_last_distance = touchDistance(x0, y0, x1, y1);
        return true;
    }

    fn endPinch(self: *AppState) void {
        self.pinch_active = false;
        self.pinch_last_distance = 0.0;
    }

    fn eraseVoxelAtScreen(self: *AppState, sx: f32, sy: f32) bool {
        const ray = self.screenRay(sx, sy);

        var best_t = std.math.inf(f32);
        var best_index: ?usize = null;

        for (0..GridSize) |z| {
            for (0..GridSize) |y| {
                for (0..GridSize) |x| {
                    if (!self.isVoxelFilled(x, y, z)) continue;

                    const center = self.voxelCenter(x, y, z);
                    const h = VoxelSize * 0.5;
                    const bmin = v3(center.x - h, center.y - h, center.z - h);
                    const bmax = v3(center.x + h, center.y + h, center.z + h);

                    var t_hit: f32 = 0.0;
                    if (rayIntersectsAabb(ray, bmin, bmax, &t_hit) and t_hit < best_t) {
                        best_t = t_hit;
                        best_index = self.voxelIndex(x, y, z);
                    }
                }
            }
        }

        if (best_index) |idx| {
            self.voxels[idx] = false;
            self.voxel_count -|= 1;
            return true;
        }
        return false;
    }

    fn screenRay(self: *AppState, sx: f32, sy: f32) Ray {
        const width = @max(sapp.widthf(), 1.0);
        const height = @max(sapp.heightf(), 1.0);
        const aspect = width / height;

        const ndc_x = (sx / width) * 2.0 - 1.0;
        const ndc_y = 1.0 - (sy / height) * 2.0;

        const cam = self.cameraPosition();
        const forward = normalize(scale(cam, -1.0));
        const world_up = v3(0.0, 1.0, 0.0);
        const right = normalize(cross(forward, world_up));
        const up = normalize(cross(right, forward));

        const tan_half_fov = @tan(FovY * 0.5);
        const dir = normalize(add(
            forward,
            add(
                scale(right, ndc_x * aspect * tan_half_fov),
                scale(up, ndc_y * tan_half_fov),
            ),
        ));

        return .{ .origin = cam, .dir = dir };
    }

    fn cameraPosition(self: *AppState) Vec3 {
        const cp = @cos(self.camera_pitch);
        return v3(
            self.camera_distance * cp * @sin(self.camera_yaw),
            self.camera_distance * @sin(self.camera_pitch),
            self.camera_distance * cp * @cos(self.camera_yaw),
        );
    }

    fn baseColor(self: *AppState, y: usize) Vec3 {
        _ = self;
        const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(GridSize - 1));
        return v3(0.28 + 0.34 * t, 0.54 - 0.18 * t, 0.9 - 0.46 * t);
    }

    fn voxelCenter(self: *AppState, x: usize, y: usize, z: usize) Vec3 {
        _ = self;
        const xf = @as(f32, @floatFromInt(@as(i32, @intCast(x)) - @as(i32, GridHalf))) + 0.5;
        const yf = @as(f32, @floatFromInt(@as(i32, @intCast(y)) - @as(i32, GridHalf))) + 0.5;
        const zf = @as(f32, @floatFromInt(@as(i32, @intCast(z)) - @as(i32, GridHalf))) + 0.5;
        return v3(xf * VoxelSize, yf * VoxelSize, zf * VoxelSize);
    }

    fn voxelIndex(self: *AppState, x: usize, y: usize, z: usize) usize {
        _ = self;
        return x + y * GridSize + z * GridSize * GridSize;
    }

    fn isVoxelFilled(self: *AppState, x: usize, y: usize, z: usize) bool {
        return self.voxels[self.voxelIndex(x, y, z)];
    }

    fn isVoxelFilledOffset(self: *AppState, x: usize, y: usize, z: usize, ox: i32, oy: i32, oz: i32) bool {
        const nx = @as(i32, @intCast(x)) + ox;
        const ny = @as(i32, @intCast(y)) + oy;
        const nz = @as(i32, @intCast(z)) + oz;

        if (nx < 0 or ny < 0 or nz < 0) return false;
        if (nx >= GridSize or ny >= GridSize or nz >= GridSize) return false;

        return self.isVoxelFilled(@intCast(nx), @intCast(ny), @intCast(nz));
    }

    fn setStatus(self: *AppState, msg: []const u8) void {
        self.setStatusFmt("{s}", .{msg});
    }

    fn setStatusFmt(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        @memset(&self.status, 0);
        const out = std.fmt.bufPrint(self.status[0 .. self.status.len - 1], fmt, args) catch {
            const fallback = "status formatting error";
            @memcpy(self.status[0..fallback.len], fallback);
            return;
        };
        self.status[out.len] = 0;
    }

    fn triggerEraseBeep(self: *AppState) void {
        _ = self.audio_erase_counter.fetchAdd(1, .monotonic);
    }
};

var app: AppState = .{};

fn findTouchById(ev: sapp.Event, id: usize, out_x: *f32, out_y: *f32) bool {
    const n: usize = @intCast(@max(ev.num_touches, 0));
    for (ev.touches[0..n]) |t| {
        if (t.identifier != id) continue;
        out_x.* = t.pos_x;
        out_y.* = t.pos_y;
        return true;
    }
    return false;
}

fn touchDistance(x0: f32, y0: f32, x1: f32, y1: f32) f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    return @sqrt(dx * dx + dy * dy);
}

fn rayIntersectsAabb(ray: Ray, bmin: Vec3, bmax: Vec3, t_hit: *f32) bool {
    var tmin: f32 = -std.math.inf(f32);
    var tmax: f32 = std.math.inf(f32);

    const eps: f32 = 0.00001;

    inline for ([_]u8{ 0, 1, 2 }) |axis| {
        const ro = component(ray.origin, axis);
        const rd = component(ray.dir, axis);
        const mn = component(bmin, axis);
        const mx = component(bmax, axis);

        if (@abs(rd) < eps) {
            if (ro < mn or ro > mx) return false;
        } else {
            const inv = 1.0 / rd;
            var t1 = (mn - ro) * inv;
            var t2 = (mx - ro) * inv;
            if (t1 > t2) std.mem.swap(f32, &t1, &t2);
            tmin = @max(tmin, t1);
            tmax = @min(tmax, t2);
            if (tmax < tmin) return false;
        }
    }

    if (tmax < 0.0) return false;
    t_hit.* = if (tmin >= 0.0) tmin else tmax;
    return true;
}

fn component(v: Vec3, axis: u8) f32 {
    return switch (axis) {
        0 => v.x,
        1 => v.y,
        else => v.z,
    };
}

fn emitTri(a: Vec3, b: Vec3, c0: Vec3, color: Vec3) void {
    sgl.c4f(color.x, color.y, color.z, 1.0);
    sgl.v3f(a.x, a.y, a.z);
    sgl.v3f(b.x, b.y, b.z);
    sgl.v3f(c0.x, c0.y, c0.z);
}

fn audioStream(buffer: [*c]f32, num_frames: i32, num_channels: i32, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null or num_frames <= 0 or num_channels <= 0) return;

    const self: *AppState = @ptrCast(@alignCast(user_data.?));
    const frames: usize = @intCast(num_frames);
    const channels: usize = @intCast(num_channels);
    const out = buffer[0 .. frames * channels];

    const sr = self.audio_sample_rate;
    if (sr <= 0.0) return;

    const current_counter = self.audio_erase_counter.load(.monotonic);
    if (current_counter != self.audio_last_erase_counter) {
        self.audio_last_erase_counter = current_counter;
        const beep_frames_f = sr * EraseBeepDurationSec;
        var beep_frames: i32 = @intFromFloat(beep_frames_f);
        if (beep_frames < 1) beep_frames = 1;
        self.audio_beep_total_frames = beep_frames;
        self.audio_beep_frames_left = beep_frames;
        self.audio_phase = 0.0;
    }

    const step = (std.math.pi * 2.0 * EraseBeepFreqHz) / sr;
    var phase = self.audio_phase;

    for (0..frames) |frame_idx| {
        var sample: f32 = 0.0;
        if (self.audio_beep_frames_left > 0 and self.audio_beep_total_frames > 0) {
            const t = @as(f32, @floatFromInt(self.audio_beep_frames_left)) /
                @as(f32, @floatFromInt(self.audio_beep_total_frames));
            const env = t * t;
            sample = @sin(phase) * env * EraseBeepGain;
            self.audio_beep_frames_left -= 1;
        }
        phase += step;
        if (phase > std.math.pi * 2.0) phase -= std.math.pi * 2.0;

        const base = frame_idx * channels;
        for (0..channels) |ch| {
            out[base + ch] = sample;
        }
    }

    self.audio_phase = phase;
}

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

fn scale(v: Vec3, s: f32) Vec3 {
    return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
}

fn hadamard(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

fn normalize(v: Vec3) Vec3 {
    const l2 = dot(v, v);
    if (l2 <= 0.000001) return v3(0.0, 0.0, 0.0);
    return scale(v, 1.0 / @sqrt(l2));
}

fn clamp01(v: Vec3) Vec3 {
    return .{
        .x = std.math.clamp(v.x, 0.0, 1.0),
        .y = std.math.clamp(v.y, 0.0, 1.0),
        .z = std.math.clamp(v.z, 0.0, 1.0),
    };
}

fn v2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

fn uiText(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c.igTextUnformatted(z.ptr, null);
}

export fn init() void {
    app.init();
}

export fn frame() void {
    app.frame();
}

export fn cleanup() void {
    app.cleanup();
}

export fn input(ev: [*c]const sapp.Event) void {
    app.handleEvent(ev.*);
}

fn appDesc() sapp.Desc {
    return .{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = input,
        .width = 1360,
        .height = 860,
        .window_title = "Voxel Editor",
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
        .high_dpi = !is_web,
        .enable_clipboard = true,
        .clipboard_size = 1024,
    };
}

export fn voxel_editor_ios_run() callconv(.c) void {
    sapp.run(appDesc());
}

pub fn main() void {
    sapp.run(appDesc());
}
