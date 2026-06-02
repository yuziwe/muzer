const std = @import("std");
const zz  = @import("zigzag");
const mpv = @import("mpv");

const Model = struct {
    idx: u32,
    cwd: [256]u8 = undefined,
    persistent_allocator: std.mem.Allocator,
    mpv_ctx: *mpv.mpv_handle,
    play_list: zz.List(Music),
    play_status: PlayStatus = PlayStatus.FINISHED,
    owned_file_paths: std.array_list.Managed([]const u8),
    file_picker: zz.components.FilePicker,
    open_file_picker: bool,

    const AudioFormat = enum {
        MP3,
        FLAC,
    };

    const PlayStatus = enum {
        PLAYING,
        PAUSED,
        FINISHED,
    };

    const support_exts = std.StaticStringMap(AudioFormat).initComptime(.{
        .{ ".mp3" , AudioFormat.MP3  },
        .{ ".flac", AudioFormat.FLAC },
    });

    const Music = struct {
        id: u32,
        resource_path: []const u8,
        lyric_path: ?[]const u8 = null,
        duration: u32 = 0,
        offset: u32 = 0,
    };

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.idx = 0;

        _ = std.process.currentPath(ctx.io, self.cwd[0..]) catch {
            ctx.log("get current path failed", .{});
            return .quit;
        };

        self.persistent_allocator = ctx.persistent_allocator;

        self.mpv_ctx = mpv.mpv_create() orelse unreachable;
        if (mpv.mpv_initialize(self.mpv_ctx) < 0) {
            ctx.log("mpv initilize failed", .{});
            return .quit;
        }

        self.play_list = zz.List(Music).init(ctx.persistent_allocator);
        self.play_list.multi_select = false;
        self.play_list.height = 20;

        self.owned_file_paths = std.array_list.Managed([]const u8).init(ctx.persistent_allocator);

        self.file_picker = zz.components.FilePicker.init(ctx.persistent_allocator);
        self.file_picker.height = ctx.height -| 10;
        self.file_picker.dir_only = true;
        self.file_picker.show_hidden = false;
        self.file_picker.setHomePath(ctx.home_dir);
        self.file_picker.navigateHome(ctx.io) catch {
            self.file_picker.navigate(ctx.io, "/") catch {};
        };

        self.open_file_picker = false;

        return .none;
    }

    pub fn deinit(self: *Model) void {
        for (self.owned_file_paths.items) |path| {
            self.persistent_allocator.free(path);
        }
        self.owned_file_paths.deinit();
        mpv.mpv_terminate_destroy(self.mpv_ctx);
        self.play_list.deinit();
        self.file_picker.deinit();
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                if (self.open_file_picker) {
                    _ = self.file_picker.handleKey(ctx.io, k) catch false;

                    // Recalculate the height based on current context height
                    self.file_picker.height = ctx.height -| 10;

                    switch (k.key) {
                        .escape => self.open_file_picker = false,
                        .char => |c| if (c == 's') {
                            self.open_file_picker = false;
                            return self.scan_files(ctx);
                        },
                        else => {}
                    }

                    return .none;
                }

                switch (k.key) {
                    .enter => {
                        if (self.play_status == PlayStatus.PAUSED) {
                            mpv_pause(self.mpv_ctx);
                        }
                        const song = if (self.play_list.selectedValue()) |v| v.resource_path else "None";
                        mpv_play(self.mpv_ctx, song);
                        self.play_status = PlayStatus.PLAYING;
                        return .none;
                    },
                    .right => {
                        if (self.play_status == PlayStatus.PAUSED) {
                            mpv_pause(self.mpv_ctx);
                        }
                        self.play_list.cursorDown();
                        const song = if (self.play_list.selectedValue()) |v| v.resource_path else "None";
                        mpv_play(self.mpv_ctx, song);
                        self.play_status = PlayStatus.PLAYING;
                        return .none;
                    },
                    .left => {
                        if (self.play_status == PlayStatus.PAUSED) {
                            mpv_pause(self.mpv_ctx);
                        }
                        self.play_list.cursorUp();
                        const song = if (self.play_list.selectedValue()) |v| v.resource_path else "None";
                        mpv_play(self.mpv_ctx, song);
                        self.play_status = PlayStatus.PLAYING;
                        return .none;
                    },
                    .char => |c| switch (c) {
                        'q' => return .quit,
                        'f' => {
                            self.open_file_picker = true;
                            return .none;
                        },
                        's' => {
                            // TODO: Internet search
                            return .none;
                        },
                        ' ' => {
                            // TODO: Space was recognized as type char.
                            // It is need to fix upstream branch code.
                            mpv_pause(self.mpv_ctx);

                            // Cycle pause
                            self.play_status = if (self.play_status == PlayStatus.PAUSED) PlayStatus.PLAYING else PlayStatus.PAUSED;
                        },
                        else => {},
                    },
                    else => {},
                }
                self.play_list.handleKey(k);
            },
        }
        return .none;
    }

    fn scan_files(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        // Scan files in current path
        const scan_path = self.file_picker.current_path.items;
        var target_dir = std.Io.Dir.openDirAbsolute(ctx.io, scan_path, .{ .iterate = true }) catch {
            ctx.log("open {s} directory failed", .{ scan_path });
            return .none;
        };
        defer target_dir.close(ctx.io);

        const Item = zz.List(Music).Item;

        var iter = target_dir.iterate();
        while (iter.next(ctx.io) catch null) |entry| {
            // Skip hidden files
            const is_hidden = entry.name.len > 0 and entry.name[0] == '.';
            if (is_hidden) continue;

            // Skil sub directories
            if (entry.kind == .directory) continue;

            // Skip duplicate items
            if (self.is_duplicated(entry.name)) continue;

            const ext_name = std.fs.path.extension(entry.name);
            const ext_format = support_exts.get(ext_name);
            if (ext_format) |_| {
                self.idx += 1;
                const file_path = std.fs.path.join(ctx.persistent_allocator, &.{ scan_path, entry.name }) catch {
                    ctx.log("join error", .{});
                    return .none;
                };
                const file_name = std.fs.path.basename(file_path);
                self.play_list.addItem(Item.init(.{ .id = self.idx, .resource_path = file_path }, file_name)) catch {
                    ctx.log("add item error", .{});
                    ctx.persistent_allocator.free(file_path);
                    return .none;
                };
                self.owned_file_paths.append(file_path) catch {
                    ctx.log("add owned slice error", .{});
                    ctx.persistent_allocator.free(file_path);
                    return .none;
                };
            } else {
                ctx.log("Not support yet: {s}", .{ ext_name });
            }
        }

        return .none;
    }

    fn is_duplicated(self: *const Model, file_name: []const u8) bool {
        for (self.owned_file_paths.items) |path| {
            if (std.mem.eql(u8, std.fs.path.basename(path), file_name)) {
                return true;
            }
        }
        return false;
    }

    fn mpv_play(mpv_ctx: *mpv.mpv_handle, song: []const u8) void {
        const args = [_:null]?[*]const u8{
            "loadfile",
            song.ptr,
        };

        _ = mpv.mpv_command(mpv_ctx, @constCast(&args));
    }

    fn mpv_pause(mpv_ctx: *mpv.mpv_handle) void {
        const args = [_:null]?[*]const u8{
            "cycle",
            "pause",
        };
        
        _ = mpv.mpv_command(mpv_ctx, @constCast(&args));
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const alloc = ctx.allocator;
        const w: u16 = @intCast(@min(ctx.width, std.math.maxInt(u16)));
        const h: u16 = @intCast(@min(ctx.height, std.math.maxInt(u16)));

        if (self.open_file_picker)
        {
            return self.file_picker.view(alloc) catch "Error file picker";
        }

        const safe_area: u16 = ~(h % 2) & 0x0001;

        // Main layout
        const main_rows = zz.flex.layout(alloc, w, h - safe_area, &.{
            .{ .constraint = .fill },
            .{ .constraint = .{ .fixed = 1 } },
        }, .{ .direction = .column, }) catch return "layout error";

        // Outer horizontal layout (left: 30%, right: 70%)
        const outer_cols = zz.flex.layout(alloc, main_rows[0].width, main_rows[0].height, &.{
            .{ .constraint = .{ .percentage = 30 } },
            .{ .constraint = .fill },
        }, .{ .direction = .row, }) catch return "layout error";

        const list_view = self.play_list.view(alloc) catch "Empty list";
        const left_panel = renderBox(alloc, list_view, outer_cols[0].width, outer_cols[0].height, zz.Color.cyan, true, .left, .top) catch "Render error";

        // Inner vertical layout of right panel (overview: 5%, lyric: 70%, spectrum: 20%, player: 5%)
        const inner_rows = zz.flex.layout(alloc, outer_cols[1].width, outer_cols[1].height, &.{
            .{ .constraint = .{ .percentage = 5 } },
            .{ .constraint = .fill },
            .{ .constraint = .{ .percentage = 20 } },
            .{ .constraint = .{ .percentage = 5 } },
        }, .{ .direction = .column, }) catch return "layout error";

        const music_name = if (self.play_list.selectedItem()) |v| v.title else "None";

        const overview_panel = renderBox(alloc, music_name, inner_rows[0].width, inner_rows[0].height, zz.Color.red, true, .center, .middle) catch "Render error";
        const lyric_panel    = renderBox(alloc, "None", inner_rows[1].width, inner_rows[1].height, zz.Color.green, true, .center, .middle) catch "Render error";
        const spectrum_panel = renderBox(alloc, "None", inner_rows[2].width, inner_rows[2].height, zz.Color.yellow, true, .center, .middle) catch "Render error";
        const player_panel   = renderBox(alloc, "None", inner_rows[3].width, inner_rows[3].height, zz.Color.magenta, true, .center, .middle) catch "Render error";

        const right_panel = zz.join.vertical(alloc, .center, &.{ overview_panel, lyric_panel, spectrum_panel, player_panel }) catch "Render error";

        const body = zz.join.horizontal(alloc, .middle, &.{ left_panel, right_panel }) catch "Render error";

        var help_style = zz.Style{};
        help_style = help_style.fg(zz.Color.gray(12));
        help_style = help_style.inline_style(true);
        const help = help_style.render(
            alloc,
            "q: Quit f: Local scan Arrow keys: Play Control",
        ) catch "";

        const help_content = zz.place.place(ctx.allocator, main_rows[1].width, main_rows[1].height, .left, .bottom, help) catch help;

        const content = zz.join.vertical(alloc, .center, &.{ body, help_content }) catch "Render error";

        return zz.place.place(alloc, w, h, .center, .middle, content) catch content;
    }

    fn renderBox(
        alloc: std.mem.Allocator, 
        content: []const u8, 
        w: u16, 
        h: u16, 
        border_color: zz.Color, 
        highlight: bool, 
        hAlign: zz.style.Align,
        vAlign: zz.style.VAlign) ![]const u8 {
        // Style first
        var s = zz.Style{};
        s = s.borderAll(zz.Border.rounded);
        if (highlight) {
            s = s.borderForeground(border_color);
        } else {
            s = s.borderForeground(zz.Color.gray(6));
        }

        // Account for border (2 cells each side)
        const inner_w: u16 = if (w > 4) w - 4 else 1;
        const inner_h: u16 = if (h > 2) h - 2 else 1;
        s = s.width(inner_w).height(inner_h).alignH(hAlign);

        const content_height: u16 = @intCast(@min(zz.measure.height(content), std.math.maxInt(u16)));

        // Padding for veritical direction
        const padding_top = switch (vAlign) {
            .top => 0,
            .middle => (inner_h - content_height) / 2,
            .bottom => inner_h - content_height,
        };
        const padding_bottom = switch (vAlign) {
            .top => inner_h - content_height,
            .middle => (inner_h - content_height) / 2,
            .bottom => 0,
        };
        s = s.paddingTop(padding_top).paddingBottom(padding_bottom);

        return s.render(alloc, content) catch "Render error";
    }
};

pub fn main(init: std.process.Init) !void {
    var program = zz.Program(Model).initWithOptions(
        init.gpa, init.io, init.environ_map,
        .{
            .fps = 60,
            .mouse = false,
            .cursor = false,
            .alt_screen = true,
            .bracketed_paste = false,
            .title = "muzer",
            .log_file = "debug.log",
            .unicode_width_strategy = null,
            .suspend_enabled = false,
        }
    );
    defer program.deinit();
    try program.run();
}
