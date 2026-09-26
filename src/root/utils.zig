const std = @import("std");

pub fn StaticArrayList(comptime T: type, comptime n: usize) type {
    return struct{
        const Self = @This();

        items_: [n]T,
        used_: usize,

        pub fn asSlice(self: *const Self) []const T {
            return self.items_[0..self.used_];
        }

        pub fn asSliceMut(self: *Self) []T {
            return self.items_[0..self.used_];
        }

        pub fn append(self: *Self, item: T) error{ NoSpaceLeft }!void {
            if (self.used_+1 > n) return error.NoSpaceLeft;
            self.items_[self.used_] = item;
        }

        pub fn pop(self: *Self) ?T {
            if (self.used_ < 1) return null;

            const val = self.items_[self.used_ - 1];
            self.items_[self.used_ - 1] = undefined;
            self.used_ -= 1;
            return val;
        }

        pub fn insert(self: *Self, index: usize, items: []const T) error{ NoSpaceLeft, IncorrectIndex }!void {
            const dest = try addManyAt(self, index, items.len);
            @memcpy(dest, items);
        }

        pub fn addManyAt(self: *Self, index: usize, count: usize) error{ NoSpaceLeft, IncorrectIndex }![]T {
            if (self.used_+count > n) return error.NoSpaceLeft;
            if (self.used_ < index) return error.IncorrectIndex;

            const next_items_count = self.used_-index;
            self.used_ += count;
            @memmove(self.items_[index+count..][0..next_items_count], self.items_[index..][0..next_items_count]);

            return self.items_[index..][0..count];
        }
    };
}

pub const Span = struct {
    start: usize, end: usize,

    pub fn len(self: Span) usize {
        return self.end-self.start;
    }

    pub fn isCorrect(self: Span) bool {
        return self.end>=self.start;
    }

    pub fn withLen1(pos: usize) Span { 
        return .{ .start = pos, .end = pos+1 };
    }

    pub fn shiftMut(self: *Span, value: usize, direction: Direction) void {
        const op = direction.to_op();

        self.start = op(self.start, value); 
        self.end = op(self.end, value); 
    }
};

pub const Direction = enum { 
    forward, backward,
    
    pub fn to_op(self: Direction) *const fn(usize, usize) usize {
        return switch (self) {
            .forward => &add,
            .backward => &sub,
        };
    }

    fn add(lhs: usize, rhs: usize) usize {
        return lhs+rhs;
    }

    fn sub(lhs: usize, rhs: usize) usize {
        return lhs-rhs;
    }
};

pub fn highlightCode(code: [:0]const u8, file_path: []const u8, span: Span, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(span.isCorrect());

    if (span.len()==0) {
        const start_row_col = getRowColUsingPos(code, span.start);
        const code_region = getLineStartEndUsingPos(code, span.start);

        std.debug.print("{s}:{} - ", .{ file_path, start_row_col.row });

        std.debug.print(fmt++"\n", args);
        std.debug.print("{s}\n", .{ code[code_region.start..code_region.end] });
    } else {
        const start_row_col = getRowColUsingPos(code, span.start);
        const end_row_col = getRowColUsingPos(code, span.end-1);

        const code_region_start = getLineStartEndUsingPos(code, span.start);
        const code_region_end = getLineStartEndUsingPos(code, span.end-1);

        if      (start_row_col.row == end_row_col.row and start_row_col.col == end_row_col.col) std.debug.print("{s}:{}:{} - ", .{ file_path, start_row_col.row, start_row_col.col })
        else if (start_row_col.row == end_row_col.row and start_row_col.col != end_row_col.col) std.debug.print("{s}:{}:[{}-{}] - ", .{ file_path, start_row_col.row, start_row_col.col, end_row_col.col })
        else                                                                                    std.debug.print("{s}:[{}:{}-{}:{}] - ", .{ file_path, start_row_col.row, start_row_col.col, end_row_col.row, end_row_col.col });

        std.debug.print(fmt++"\n", args);
        std.debug.print("{s}\n", .{ code[code_region_start.start..code_region_end.end] });

        for (0..span.start-code_region_start.start) |_| std.debug.print(" ", .{});
        for (span.start..span.end) |i| std.debug.print("^{s}", .{ if (code[i] == '\n' and i != span.end-1) "\n" else "" });
        std.debug.print("\n\n", .{});
    }
}

pub fn getLineStartEndUsingPos(code: [:0]const u8, pos: usize) Span {
    return .{ .start = if (std.mem.findScalarLast(u8, code[0..pos], '\n')) |p| p+1 else 0, .end = std.mem.findScalarPos(u8, code, pos, '\n') orelse code.len };
}

pub fn getRowColUsingPos(code: [:0]const u8, pos: usize) struct { row: usize, col: usize } {
    return .{ 
        .row = std.mem.countScalar(u8, code[0..pos], '\n'), 
        .col = pos - if (std.mem.findScalarLast(u8, code[0..pos], '\n')) |i| i+1 else 0 
    };
}


pub fn createAndCopy(comptime T: type, allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!*T {
    const ptr = try allocator.create(T);
    ptr.* = value;
    return ptr;
}
pub fn createAndCopyOptional(comptime T: type, allocator: std.mem.Allocator, value: ?T) std.mem.Allocator.Error!?*T {
    return if (value == null) null else try createAndCopy(T, allocator, value.?);
}

pub fn convertBetweenEnumsByName(comptime From: type, comptime To: type, from: From) To {
    comptime if (@typeInfo(From) != .@"enum") @compileError("`From` - expected enum, found '" ++ @typeName(From) ++ "'");
    comptime if (@typeInfo(To) != .@"enum")   @compileError("`To` - expected enum, found '"   ++ @typeName(To)   ++ "'");

    return switch (from) {
        inline else => |tag| if (std.meta.fieldIndex(To, @tagName(tag))) |index| @enumFromInt(index) else unreachable,
    };
}

pub fn MergeEnums(comptime A: type, comptime B: type) type {
    const info_a = @typeInfo(A).@"enum";
    const info_b = @typeInfo(B).@"enum";

    const TagInt = std.math.IntFittingRange(0, info_a.fields.len + info_b.fields.len - 1);

    var field_names: [info_a.fields.len + info_b.fields.len][]const u8 = undefined;
    var field_values: [info_a.fields.len + info_b.fields.len]TagInt = std.simd.iota(TagInt, info_a.fields.len + info_b.fields.len);

    for (info_a.fields, 0..) |field, i| field_names[i] = field.name;

    for (info_b.fields, 0..) |field, i| field_names[info_a.fields.len + i] = field.name;

    return @Enum(TagInt, .exhaustive, &field_names, &field_values);
}

/// expected to use with std.fmt.Alt
/// return type which contains `format`
pub fn formatMany(comptime T: type, comptime fmt: []const u8) type {
    return struct {
        pub fn format(self: []const T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (self, 0..) |elem, i| {
                try writer.print(fmt, .{ elem });
                if (i != self.len-1) try writer.print(", ", .{});
            }
        }
    };
}

/// expected to use with std.fmt.Alt
pub fn formatRawString(self: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (self) |ch| switch (ch) {
        0x00 => try writer.print("\\0", .{}),
        0x09 => try writer.print("\\t", .{}),
        0x0A => try writer.print("\\n", .{}),
        0x0D => try writer.print("\\r", .{}),

        0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try writer.print("\\x{X:0>2}", .{ ch }),

        else => try writer.writeByte(ch),
    };
}




pub fn todo() noreturn { std.debug.panic("todo", .{}); }