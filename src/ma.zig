const std = @import("std");
const ma  = @import("miniaudio");

const Self = @This();

const MaError = error {
    MA_UNKNOWN,
    MA_OOM,
    MA_NOTFOUND,
};

cursor: usize,
length: usize,
engine: ma.ma_engine,
allocator: std.mem.Allocator,
play_list: std.array_list.Managed(*MaSound),

const MaSound = struct {
    duration: i64,
    instance: ma.ma_sound,

    pub fn setDuration(self: *MaSound, duration: i64) void {
        self.duration = duration;
    }

    pub fn getDuration(self: MaSound) i64 {
        return self.duration;
    }

    pub fn getSound(self: *MaSound) *ma.ma_sound {
        return &self.instance;
    }
};

pub fn init(self: *Self, allocator: std.mem.Allocator) MaError!void {
    self.cursor = 0;
    self.length = 0;
    if (ma.ma_engine_init(null, &self.engine) != ma.MA_SUCCESS) {
        return MaError.MA_UNKNOWN;
    }
    self.allocator = allocator;
    self.play_list = std.array_list.Managed(*MaSound).init(allocator);
}

pub fn deinit(self: Self) void {
    for (self.play_list.items) |sound| {
        ma.ma_sound_uninit(sound.getSound());
        self.allocator.destroy(sound);
    }
    self.play_list.deinit();
    ma.ma_engine_uninit(@constCast(&self.engine));
}

pub fn play(self: *Self, cursor: usize) MaError!void {
    if (cursor < self.length) {
        // Reset previous sound
        self.pause(self.cursor);
        self.reset(self.cursor);
        // Non-block invoke
        const sound = self.play_list.items[cursor].getSound();
        _ = ma.ma_sound_start(@constCast(sound));
        // Update current sound cursor
        self.cursor = cursor;
        return;
    }

    return MaError.MA_NOTFOUND;
}

pub fn reset(self: Self, cursor: usize) void {
    // Non-block invoke
    const sound = self.play_list.items[cursor].getSound();
    _ = ma.ma_sound_seek_to_pcm_frame(@constCast(sound), 0);
}

pub fn pause(self: Self, cursor: usize) void {
    // Non-block invoke
    const sound = self.play_list.items[cursor].getSound();
    _ = ma.ma_sound_stop(@constCast(sound));
}

pub fn resumePlay(self: Self) void {
    // Non-block invoke
    const sound = self.getCurrentSound().getSound();
    _ = ma.ma_sound_start(@constCast(sound));
}

pub fn isEnd(self: Self) bool {
    const sound = self.getCurrentSound().getSound();
    const res = ma.ma_sound_at_end(@constCast(sound));
    return res == 1;
}

fn getCurrentSound(self: Self) *MaSound {
    return self.play_list.items[self.cursor];
}

pub fn getDuration(self: Self) i64 {
    return self.getCurrentSound().getDuration();
}

pub fn getOffset(self: Self) i64 {
    var offset: f32 = undefined;
    const sound = self.getCurrentSound().getSound();
    if (ma.ma_sound_get_cursor_in_seconds(@constCast(sound), &offset) != ma.MA_SUCCESS) {
        return 0;
    }

    return @intFromFloat(offset);
}

pub fn addToPlayList(self: *Self, path: []const u8) MaError!void {
    const sound: *MaSound = self.allocator.create(MaSound) catch return MaError.MA_OOM;

    const dnuos = sound.getSound();

    if (ma.ma_sound_init_from_file(&self.engine, path.ptr, 0, null, null, @constCast(dnuos)) != ma.MA_SUCCESS) {
        return MaError.MA_UNKNOWN;
    }

    var length: f32 = undefined;
    if (ma.ma_sound_get_length_in_seconds(@constCast(dnuos), &length) != ma.MA_SUCCESS) {
        return MaError.MA_UNKNOWN;
    }

    sound.setDuration(@intFromFloat(length));

    self.play_list.append(sound) catch return MaError.MA_OOM;

    self.length += 1;
}

pub fn getPlayListLength(self: Self) usize {
    return self.length;
}

pub fn getPlayListCursor(self: Self) usize {
    return self.cursor;
}
