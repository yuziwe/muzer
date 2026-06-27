const std = @import("std");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buf: []T,

        // Producer writes head.
        // Consumer writes tail.
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),

        const Self = @This();

        const MqError = error{
            FULL_QUEUE,
            EMPTY_QUEUE,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            capacity: usize,
        ) !Self {
            // We use one empty slot to distinguish full vs empty.
            // So usable capacity is capacity, internal buffer is capacity + 1.
            const buf = try allocator.alloc(T, capacity + 1);
            return .{
                .allocator = allocator,
                .buf = buf,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }

        /// Producer only.
        pub fn tryPush(self: *Self, item: T) ?void {
            const head = self.head.load(.monotonic);
            const next = self.nextIndex(head);

            // Acquire pairs with consumer's release-store to tail.
            const tail = self.tail.load(.acquire);

            if (next == tail) {
                return null;
            }

            self.buf[head] = item;

            // Release makes buf[head] visible before head is published.
            self.head.store(next, .release);
        }

        /// Consumer only.
        pub fn tryPop(self: *Self) ?*T {
            const tail = self.tail.load(.monotonic);

            // Acquire pairs with producer's release-store to head.
            const head = self.head.load(.acquire);

            if (tail == head) {
                return null;
            }

            const item = &self.buf[tail];

            // Release lets producer observe the freed slot.
            self.tail.store(self.nextIndex(tail), .release);

            return item;
        }

        pub fn empty(self: *Self) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            return tail == head;
        }

        fn nextIndex(self: *const Self, i: usize) usize {
            const next = i + 1;
            return if (next == self.buf.len) 0 else next;
        }
    };
}
