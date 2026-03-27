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

fn skipWS(reader: *std.Io.Reader, byte_offset: *usize) std.Io.Reader.Error!void {
    while (std.ascii.isWhitespace(try reader.peek(1))) {
        reader.toss(1);
        byte_offset.* += 1;
    }
}

const Machine = struct {
    alloc: std.mem.Allocator,
    rules: [][256]?Rule,
    tape: std.Deque(u8),
    head: usize = 0,
    state: usize,
    state_map: ?[][]u8 = null,
    tape_len_limit: ?usize = 100,

    fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader, byte_offset: *usize) !Machine {
        var rules: std.ArrayList([256]?Rule) = .empty;
        errdefer rules.deinit(allocator);
        var rules_map: std.StringArrayHashMap(usize) = .init(allocator);
        defer rules_map.deinit(allocator);
        byte_offset.* = 0;

        const init_tape_str = "tape:";
        const init_tape = if (reader.peek(init_tape_str.len)) |init_str| tape: {
            if (std.mem.eql(u8, init_tape_str, init_str)) {
                byte_offset.* += init_tape_str.len;
                reader.toss(init_tape_str.len);

                try skipWS(reader, byte_offset);
                const init_buffer = if (try reader.takeDelimiter('\n')) |symbol| symbol else return error.UnexpectedEOF;
                byte_offset.* += init_buffer.len;
                var tape = try std.Deque(u8).initCapacity(allocator, init_buffer.len);
                for (init_buffer) |byte| {
                    tape.pushBackAssumeCapacity(byte);
                }

                break :tape tape;
            }
        } else |_| std.Deque(u8).empty;
        errdefer init_tape.deinit(allocator);

        const init_state_str = "state:";
        const init_state = if (reader.peek(init_state_str.len)) |init_str| state: {
            if (std.mem.eql(u8, init_state_str, init_str)) {
                byte_offset.* += init_state_str.len;
                reader.toss(init_state_str.len);

                try skipWS(reader, byte_offset);
                const init_buffer = if (try reader.takeDelimiter('\n')) |symbol| symbol else return error.UnexpectedEOF;
                byte_offset.* += init_buffer.len;

                break :state try allocator.dupe(u8, init_buffer);
            }
        } else |_| null;
        errdefer if (init_state) |s| allocator.free(s);

        while (true) {
            const state = if (try reader.takeDelimiter(',')) |state| state else break;
            byte_offset.* += state.len;
            try skipWS(reader, byte_offset);
            const symbol = if (try reader.takeDelimiter('\n')) |symbol| symbol else return error.UnexpectedEOF;
            if (symbol.len > 1) return error.InvalidSymbolLen;
            byte_offset.* += symbol.len;

            const new_state = if (try reader.takeDelimiter(',')) |new_state| new_state else return error.UnexpectedEOF;
            byte_offset.* += new_state.len;
            try skipWS(reader, byte_offset);

            const new_symbol = if (try reader.takeDelimiter(',')) |new_symbol| new_symbol else return error.UnexpectedEOF;
            if (new_symbol.len != 1) return error.InvalidSymbolLen;
            byte_offset.* += new_symbol.len;
            try skipWS(reader, byte_offset);

            const new_direction = if (try reader.takeDelimiter('\n')) |new_direction| new_direction else return error.UnexpectedEOF;
            if (new_direction.len > 4) return error.InvalidDirection;
            const new_direction_enum: Dir = switch (new_direction[0]) {
                '<' => Dir.left,
                '>' => Dir.right,
                '_' => Dir.center,
                else => {
                    var lower_buf: [4]u8 = undefined;
                    const lower_string = std.ascii.lowerString(&lower_buf, new_direction);
                    if (std.mem.eql(u8, lower_string, "halt")) break Dir.halt;
                    return error.InvalidDirection;
                },
            };
            if (new_direction_enum == .halt and new_direction.len > 1) return error.InvalidDirection;
            byte_offset.* += new_direction.len;

            var result = try rules_map.getOrPut(state);
            const state_int = if (!result.found_existing) state: {
                const new_index = rules_map.count();
                result.value_ptr.* = new_index;
                @memset(try rules.addOne(allocator), null);
                break :state new_index;
            } else state: {
                break :state result.value_ptr.*;
            };

            result = try rules_map.getOrPut(new_state);
            const new_state_int = if (!result.found_existing) state: {
                const new_index = rules_map.count();
                result.value_ptr.* = new_index;
                @memset(try rules.addOne(allocator), null);
                break :state new_index;
            } else state: {
                break :state result.value_ptr.*;
            };

            rules.items[state_int][symbol[0]] = Rule{
                .direction = new_direction_enum,
                .new_state = new_state_int,
                .new_symbol = new_symbol[0],
            };
        }
        var state_map = try allocator.alloc(u8, rules_map.count());
        errdefer allocator.free(state_map);

        for (rules_map.keys(), rules_map.values()) |name, state_index| {
            state_map[state_index] = try allocator.dupe(u8, name);
        }

        return Machine{
            .alloc = allocator,
            .rules = try rules.toOwnedSlice(allocator),
            .tape = init_tape,
            .state_map = state_map,
            .state = if (init_state) |s| rules_map.get(s) orelse return error.UnlistedState else 0,
        };
    }
    fn deinit(self: *Machine) void {
        self.alloc.free(self.rules);
        if (self.state_map) |map| self.alloc.free(map);
        self.tape.deinit(self.alloc);
    }

    const TickError = error{ TapeTooLong, UnknownRule, Halt } || std.mem.Allocator.Error;
    fn tick(self: *Machine) TickError!void {
        if (self.head >= self.tape.len) {
            if (self.tape_len_limit) |limit|
                if (self.tape.len + 1 >= limit) return error.TapeTooLong;
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

    // var rules: std.ArrayList([256]?Rule) = .empty;
    // var move_right: [256]?Rule = @splat(null);
    // move_right['0'] = Rule{ .new_state = 0, .new_symbol = '0', .direction = .right };
    // move_right['1'] = Rule{ .new_state = 0, .new_symbol = '1', .direction = .right };
    // move_right[blank] = Rule{ .new_state = 1, .new_symbol = blank, .direction = .left };
    // try rules.append(alloc, move_right);

    // var count: [256]?Rule = @splat(null);
    // count['0'] = Rule{ .new_state = 0, .new_symbol = '1', .direction = .right };
    // count['1'] = Rule{ .new_state = 1, .new_symbol = '0', .direction = .left };
    // count[blank] = Rule{ .new_state = 1, .new_symbol = '1', .direction = .halt };
    // try rules.append(alloc, count);

    // var m = Machine{
    //     .alloc = alloc,
    //     .rules = rules,
    //     .tape = .empty,
    //     .state = 0,
    // };
    // defer m.rules.deinit(alloc);
    // defer m.tape.deinit(alloc);
    // const inital_tape = "00000000_";
    // try m.tape.ensureTotalCapacity(alloc, 8);
    // for (inital_tape) |c| {
    //     m.tape.pushBackAssumeCapacity(c);
    // }
    // try m.display(w);

    {
        var arg_iter = try init.minimal.args.iterateAllocator(alloc);
        defer arg_iter.deinit();

        _ = arg_iter.skip();
        if (arg_iter.next()) |filename| {
            std.Io.Dir.openFile(std.Io.Dir.cwd(), init.io, filename, .{});
        }
    }
    // var m = Machine.parse(allocator: Allocator, reader: *Reader, byte_offset: *usize)

    // while (true) {
    //     m.tick() catch |e| {
    //         switch (e) {
    //             error.Halt => break,
    //             error.UnknownRule => {
    //                 std.log.err("state: {}, head: {}", .{ m.state, m.head });
    //                 return e;
    //             },
    //             else => return e,
    //         }
    //     };
    //     try m.display(w);
    //     try w.writeByte('\n');
    //     try w.print("state: {}, head: {}\n", .{ m.state, m.head });
    // }
    // try m.display(w);
}
