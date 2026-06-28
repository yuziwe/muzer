const std = @import("std");
const ma = @import("miniaudio");
const Mq = @import("mq");
const fft = @import("fft");

const Self = @This();

const MaError = error{
    MA_UNKNOWN,
    MA_OOM,
    MA_NOTFOUND,
    MA_NODEVICE,
    MA_DEVINIT,
};

mq: *Mq.RingBuffer(fft.Result),
cursor: usize,
length: usize,
engine: ma.ma_engine,
device: ma.ma_device,
allocator: std.mem.Allocator,
play_list: std.array_list.Managed(*MaSound),
engine_config: ma.ma_engine_config,
device_config: ma.ma_device_config,
engine_context: ma.ma_context,
userdata: UserData,

const MaSound = struct {
    duration: usize,
    instance: ma.ma_sound,

    pub const empty: MaSound = .{ .duration = 0, .instance = undefined };

    pub fn setDuration(self: *MaSound, duration: usize) void {
        self.duration = duration;
    }

    pub fn getDuration(self: MaSound) usize {
        return self.duration;
    }

    pub fn getSound(self: *MaSound) *ma.ma_sound {
        return &self.instance;
    }
};

const UserData = struct {
    ins: *Self,
    engine: *ma.ma_engine,
    mq: *Mq.RingBuffer(fft.Result),

    pub fn init(engine: *ma.ma_engine, mq: *Mq.RingBuffer(fft.Result), ins: *Self) UserData {
        return .{
            .engine = engine,
            .mq = mq,
            .ins = ins,
        };
    }
};

fn progressTrack(device: [*c]ma.ma_device, output: ?*anyopaque, _: ?*const anyopaque, frame_count: ma.ma_uint32) callconv(.c) void {
    const userdata: *UserData = @ptrCast(@alignCast(device[0].pUserData));
    if (ma.ma_engine_read_pcm_frames(userdata.engine, output, frame_count, null) != ma.MA_SUCCESS) return;
    // TODO: FFT
    if (fft.fft(userdata.ins.allocator, @ptrCast(@alignCast(output)), frame_count)) |res| {
        // Push
        userdata.mq.tryPush(res) orelse return;
    }
}

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    mq: *Mq.RingBuffer(fft.Result),
) MaError!void {
    self.mq = mq;
    self.cursor = 0;
    self.length = 0;
    if (ma.ma_context_init(null, 0, null, &self.engine_context) != ma.MA_SUCCESS) {
        return MaError.MA_UNKNOWN;
    }
    // Get output device
    var playback_infos: [*c]ma.ma_device_info = undefined;
    var playback_count: ma.ma_uint32 = undefined;
    if (ma.ma_context_get_devices(&self.engine_context, &playback_infos, &playback_count, null, null) != ma.MA_SUCCESS) {
        return MaError.MA_NODEVICE;
    }

    if (playback_count == 0) {
        return MaError.MA_NODEVICE;
    }

    self.userdata = UserData.init(&self.engine, self.mq, self);

    self.device_config = ma.ma_device_config_init(ma.ma_device_type_playback);
    // Use the first deivce by default
    self.device_config.playback.pDeviceID = &playback_infos[0].id;
    // NOTE: This config also important
    self.device_config.playback.format = ma.ma_format_f32;
    self.device_config.playback.channels = 0;
    // NOTE: we need to set sample rate
    // othetwise we will sound a piece of shit
    self.device_config.sampleRate = 48000;
    self.device_config.dataCallback = progressTrack;
    self.device_config.pUserData = &self.userdata;

    if (ma.ma_device_init(&self.engine_context, &self.device_config, &self.device) != ma.MA_SUCCESS) {
        return MaError.MA_DEVINIT;
    }

    self.engine_config = ma.ma_engine_config_init();
    // NOTE: Specify the device we wanna use,
    // otherwise it will not trigger our data callback!
    self.engine_config.pDevice = &self.device;
    self.engine_config.noAutoStart = ma.MA_TRUE;
    if (ma.ma_engine_init(&self.engine_config, &self.engine) != ma.MA_SUCCESS) {
        return MaError.MA_UNKNOWN;
    }

    self.allocator = allocator;
    self.play_list = std.array_list.Managed(*MaSound).init(allocator);
}

pub fn deinit(self: *Self) void {
    for (self.play_list.items) |sound| {
        const dnuos = sound.getSound();
        ma.ma_sound_uninit(@constCast(dnuos));
        self.allocator.destroy(sound);
    }
    self.play_list.deinit();
    ma.ma_engine_uninit(@constCast(&self.engine));
    ma.ma_device_uninit(@constCast(&self.device));
    _ = ma.ma_context_uninit(@constCast(&self.engine_context));
}

pub fn play(self: *Self, cursor: usize) MaError!void {
    if (cursor < self.length) {
        // Reset previous sound
        self.pause(self.cursor);
        self.reset(self.cursor);

        // NOTE: Start engine manually,
        // otherwise it will trigger our data callback at first and crash because SIGSEV!
        if (ma.ma_engine_start(&self.engine) != ma.MA_SUCCESS) {
            return MaError.MA_UNKNOWN;
        }

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

pub fn pause(self: *Self, cursor: usize) void {
    // NOTE: Start engine manually,
    // otherwise it will trigger our data callback at first and crash because SIGSEV!
    if (ma.ma_engine_stop(&self.engine) != ma.MA_SUCCESS) {
        return;
    }

    // Non-block invoke
    const sound = self.play_list.items[cursor].getSound();
    _ = ma.ma_sound_stop(@constCast(sound));
}

pub fn resumePlay(self: *Self) void {
    // NOTE: Start engine manually,
    // otherwise it will trigger our data callback at first and crash because SIGSEV!
    if (ma.ma_engine_start(&self.engine) != ma.MA_SUCCESS) {
        return;
    }

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

pub fn getDuration(self: Self) usize {
    return self.getCurrentSound().getDuration();
}

pub fn getOffset(self: Self) usize {
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
