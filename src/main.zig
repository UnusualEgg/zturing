const std = @import("std");

const Dir = enum { left, right, center, halt };
const UserRule = struct {
    state: []const u8,
    symbol: u8,

    new_state: []const u8,
    new_symbol: u8,
    direction: Dir,
};
const Rule = struct {
    new_state: usize,
    new_symbol: u8,
    direction: Dir,
};

const blank = '_';

const Machine = struct {
    alloc: std.mem.Allocator,
    rules: std.ArrayList([256]?Rule),
    tape: std.Deque(u8),
    head: usize = 0,
    state: usize,

    fn tick(self: *Machine) !void {
        if (self.head >= self.tape.len) {
            try self.tape.ensureTotalCapacity(self.alloc, self.head + 1);
            for (0..((self.head + 1) - self.tape.len)) |_| {
                self.tape.pushBackAssumeCapacity(blank);
            }
        }

        const current_symbol = self.tape.atPtr(self.head);

        if (self.state >= self.rules.items.len) return error.UnknownRule;
        if (self.rules.items[self.state][current_symbol.*]) |rule| {
            current_symbol.* = rule.new_symbol;
            self.state = rule.new_state;
            switch (rule.direction) {
                .left => {
                    if (self.head == 0) {
                        try self.tape.pushFront(self.alloc, blank);
                        //moves `self.head` left just from `pushBack`
                    } else {
                        self.head -= 1;
                    }
                },
                .right => {
                    self.head += 1;
                    if (self.head >= self.tape.len) {
                        try self.tape.pushBack(self.alloc, blank);
                    }
                },
                .center => {},
                .halt => return error.Halt,
            }
        } else return error.UnknownRule;
    }
    fn display(self: *const Machine, w: *std.Io.Writer) !void {
        try w.print("len: {}/{}\n", .{ self.tape.len, self.tape.buffer.len });
        for (0..self.tape.len) |i| {
            try w.writeByte(self.tape.at(i));
        }
        // try w.writeByte('\n');
        // if (self.tape.head != 0) {
        //     for (self.tape.head..self.tape.buffer.len) |i| {
        //         try w.writeByte(self.tape.buffer[self.tape.buffer.len -| 1 -| i]);
        //     }
        //     try w.printAscii(self.tape.buffer[0 .. self.tape.len - (self.tape.buffer.len -| 1 - self.tape.head)], .{});
        // } else {
        //     try w.printAscii(self.tape.buffer[0..self.tape.len], .{});
        //     for (self.tape.buffer[0..self.tape.len]) |b| {
        //         try w.print("|{}|", .{b});
        //     }
        // }
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    const w = &stdout.interface;
    try w.print("Hello world\n", .{});

    const alloc = std.heap.smp_allocator;

    var rules: std.ArrayList([256]?Rule) = .empty;
    var move_right: [256]?Rule = @splat(null);
    move_right['0'] = Rule{ .new_state = 0, .new_symbol = '0', .direction = .right };
    move_right['1'] = Rule{ .new_state = 0, .new_symbol = '1', .direction = .right };
    move_right[blank] = Rule{ .new_state = 1, .new_symbol = blank, .direction = .left };
    try rules.append(alloc, move_right);

    var count: [256]?Rule = @splat(null);
    count['0'] = Rule{ .new_state = 0, .new_symbol = '1', .direction = .right };
    count['1'] = Rule{ .new_state = 1, .new_symbol = '0', .direction = .left };
    count[blank] = Rule{ .new_state = 1, .new_symbol = '1', .direction = .halt };
    try rules.append(alloc, count);

    var m = Machine{
        .alloc = alloc,
        .rules = rules,
        .tape = .empty,
        .state = 0,
    };
    defer m.rules.deinit(alloc);
    defer m.tape.deinit(alloc);
    const inital_tape = "00000000_";
    try m.tape.ensureTotalCapacity(alloc, 8);
    for (inital_tape) |c| {
        m.tape.pushBackAssumeCapacity(c);
    }
    try m.display(w);

    while (true) {
        m.tick() catch |e| {
            switch (e) {
                error.Halt => break,
                error.UnknownRule => {
                    std.log.err("state: {}, head: {}", .{ m.state, m.head });
                    return e;
                },
                else => return e,
            }
        };
        try m.display(w);
        try w.writeByte('\n');
        try w.print("state: {}, head: {}\n", .{ m.state, m.head });
    }
    try m.display(w);
}
