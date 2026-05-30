const std = @import("std");
const zz  = @import("zigzag");

const Model = struct {
    count: i32,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.* = .{ .count = 0 };
        return .none;
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .char => |c| if (c == 'q') return .quit,
                .up => self.count += 1,
                .down => self.count -= 1,
                else => {},
            },
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        _ = self;
        const alloc = ctx.allocator;
        const w: u16 = @intCast(@min(ctx.width, std.math.maxInt(u16)));
        const h: u16 = @intCast(@min(ctx.height, std.math.maxInt(u16)));

        // Main layout
        const main_rows = zz.flex.layout(alloc, w, h, &.{
            .{ .constraint = .fill },
            .{ .constraint = .{ .fixed = 1 } },
        }, .{ .direction = .column, }) catch return "layout error";

        // Outer horizontal layout (left: 30%, right: 70%)
        const outer_cols = zz.flex.layout(alloc, main_rows[0].width, main_rows[0].height, &.{
            .{ .constraint = .{ .percentage = 30 } },
            .{ .constraint = .fill },
        }, .{ .direction = .row, }) catch return "layout error";

        const left_panel = renderBox(alloc, outer_cols[0].width, outer_cols[0].height, zz.Color.cyan, true) catch "Render error";

        // Inner vertical layout of right panel (overview: 20%, lyric: 60%, spectrum: 20%, player: 10%)
        const inner_rows = zz.flex.layout(alloc, outer_cols[1].width, outer_cols[1].height, &.{
            .{ .constraint = .{ .percentage = 10 } },
            .{ .constraint = .fill },
            .{ .constraint = .{ .percentage = 20 } },
            .{ .constraint = .{ .percentage = 10 } },
        }, .{ .direction = .column, }) catch return "layout error";

        const overview_panel = renderBox(alloc, inner_rows[0].width, inner_rows[0].height, zz.Color.red, true) catch "Render error";
        const lyric_panel    = renderBox(alloc, inner_rows[1].width, inner_rows[1].height, zz.Color.green, true) catch "Render error";
        const spectrum_panel = renderBox(alloc, inner_rows[2].width, inner_rows[2].height, zz.Color.yellow, true) catch "Render error";
        const player_panel   = renderBox(alloc, inner_rows[3].width, inner_rows[3].height, zz.Color.magenta, true) catch "Render error";

        const right_panel = zz.join.vertical(alloc, .center, &.{ overview_panel, lyric_panel, spectrum_panel, player_panel }) catch "Render error";

        const body = zz.join.horizontal(alloc, .middle, &.{ left_panel, right_panel }) catch "Render error";

        var help_style = zz.Style{};
        help_style = help_style.fg(zz.Color.gray(12));
        help_style = help_style.inline_style(true);
        const help = help_style.render(
            alloc,
            "s: Search  q: Quit  f: Open file browser  Arrow keys: Play Control",
        ) catch "";

        const centered_help = zz.place.place(ctx.allocator, main_rows[1].width, main_rows[1].height, .center, .top, help) catch help;

        const content = zz.join.vertical(alloc, .center, &.{ body, centered_help }) catch "Render error";

        return zz.place.place(
            alloc,
            w,
            h,
            .center,
            .middle,
            content,
        ) catch content;
    }

    fn renderBox(alloc: std.mem.Allocator, w: u16, h: u16, border_color: zz.Color, highlight: bool) ![]const u8 {
        var result: std.Io.Writer.Allocating = .init(alloc);
        const writer = &result.writer;

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
        s = s.width(inner_w);
        s = s.height(inner_h);

        // Filling with breaklines
        for (0..inner_h) |index| {
            if (index > 0) try writer.writeByte('\n');
        }
        const content = result.toOwnedSlice() catch "Sucks";

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
