const mpv = @import("mpv);

const Self = @This();

const MpvError = error {
    OOM,
    UNKNOWN,
};

ctx: *mpv.mpv_handle,

pub fn init(self: *Self) MpvError!void {
    self.ctx = if (mpv.mpv_create()) |v| v else return MpvError.OOM;
    if (mpv.mpv_initialize(self.ctx) < 0) {
        return MpvError.UNKNOWN;
    }
}

pub fn deinit(self: *const Self) void {
    mpv.mpv_terminate_destroy(self.ctx);
}

fn mpvCommand(self: *const Self, cmd: anytype) i32 {
    return @as(i32, mpv.mpv_command(self.ctx, @constCast(&cmd)));
}

pub fn mpvPlay(self: *const Self, song: []const u8) void {
    const args = [_:null]?[*]const u8{
        "loadfile",
        song.ptr,
    };

    _ = mpvCommand(self.ctx, args);
}

pub fn mpvPause(self: *const Self) void {
    const args = [_:null]?[*]const u8{
        "cycle",
        "pause",
    };
    
    _ = mpvCommand(self.ctx, args);
}

fn mpvGetProperty(self: *const Self, name: []const u8, format: mpv.mpv_format, data: anytype) i32 {
    return @as(i32, mpv.mpv_get_property(self.ctx, name.ptr, format, data));
}

pub fn mpvGetDuration(self: *const Self) i64 {
    var data: i64 = undefined;
    _ = mpvGetProperty(self.ctx, "duration", mpv.MPV_FORMAT_INT64, &data);
    return data;
}

pub fn mpvGetOffset(self: *const Self) i64 {
    var data: i64 = undefined;
    _ = mpvGetProperty(self.ctx, "time-pos", mpv.MPV_FORMAT_INT64, &data);
    return data;
}
