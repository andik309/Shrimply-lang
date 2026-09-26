const std = @import("std");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");
const utils = @import("utils.zig");

const Span = @import("utils.zig").Span;
const Instruction = @import("lowerer.zig").Instruction;



pub const TypeInfo = union(enum) {
    @"int": Int,
    @"void": void,

    @"type": void,

    @"struct": Struct,

    pub const Int = struct {
        bits: u16,
        signedness: Signedness,

        pub const Signedness = enum(u1) { signed = 0, unsigned = 1 };


    };

    pub const Struct = struct {
        /// pos in instructions where it was defined,
        /// its used for `eql` function
        source: usize,

        inlined_decls: []InlinedDecls,
        decls: []StaticDecl,

        // fields: []const Field,

        // pub const Field = struct { name: []const u8, ty: u32 };

        pub fn deinit(self: Struct, allocator: std.mem.Allocator) void {
            for (self.decls) |decl| decl.deinit(allocator);
            allocator.free(self.decls);

            for (self.inlined_decls) |inlined_decl| inlined_decl.deinit(allocator);
            allocator.free(self.inlined_decls);
        }
    };

    pub const StaticDecl = struct {
        name: []const u8, static_value_index: usize,

        pub fn deinit(self: StaticDecl, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
        }
    };

    pub fn deinit(self: TypeInfo, allocator: std.mem.Allocator) void {
        switch (self) {
            .@"int" => {},
            .@"void" => {},

            .@"type" => {},

            .@"struct" => |d| d.deinit(allocator),
        }
    }
};
pub const InlinedDecls = union(enum) {
    /// index of namespaced type
    static_decls: usize,
    // subst_params: []const struct{ name: []const u8, ValueContainer },

    pub fn deinit(self: InlinedDecls, allocator: std.mem.Allocator) void {
        _ = allocator;

        switch (self) {
            .static_decls => {},
        }
    }
};



pub const TypePool = struct {
    pool: std.ArrayList(PoolTypeInfo),

    // self owns the result
    pub fn get(self: TypePool, index: u32) TypeInfo {
        return switch (index) {
            0...65535      => .{ .@"int" = .{ .bits = @truncate(index-0),     .signedness = .signed   } },
            65536...131071 => .{ .@"int" = .{ .bits = @truncate(index-65536), .signedness = .unsigned } },
            131072 => .@"void",
            131073 => .@"type",

            else => {
                switch (self.pool.items[index-131074]) {
                    .@"struct" => |d| return .{ .@"struct" = d },
                }
            },
        };
    }

    // callee owns `info`
    pub fn put(self: *TypePool, info: TypeInfo, gpa: std.mem.Allocator) !u32 {
        switch (info) {
            .@"int" => |d| return @as(u32, @intFromEnum(d.signedness))*65536 + @as(u32, d.bits),
            .@"void" => return 131072,

            .@"type" => return 131073,

            .@"struct" => |d| {
                for (self.pool.items, 0..) |pool_type_info, i| {
                    if (pool_type_info == .@"struct" and d.source == pool_type_info.@"struct".source) {
                        info.deinit(gpa);
                        return @truncate(i);
                    }
                }

                const result = self.pool.items.len;

                try self.pool.append(gpa, .{ .@"struct" = d });
                return @truncate(result);
            },
        }
    }

    pub const PoolTypeInfo = union(enum) {
        @"struct": TypeInfo.Struct,
    };
};
pub const Inliner = struct {
    cwd: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,

    pool: TypePool = .{ .pool = .empty },
    static_values: std.ArrayList(StaticValue) = .empty,
    cached_files: std.ArrayList(struct { file_path: []const u8, file_code: []const u8, type_index: u32, span: Span }) = .empty,

    instructions: std.ArrayList(Instruction) = .empty,

    pub const StaticValue = union(enum) {
        unevaluated: struct { ty: ?Span, value: Span },
        evaluated: ValueContainer,
    };

    pub fn deinit(self: Inliner) void {
        self.cwd.close(self.io);
        // utils.todo();
    }

    pub fn import(self: *Inliner, file_path: []const u8) !u32 {
        for (self.cached_files.items) |cached_file| if (std.mem.eql(u8, file_path, cached_file.file_path)) return cached_file.type_index;


        const file_code = try self.cwd.readFileAllocOptions(self.io, file_path, self.gpa, .unlimited, .fromByteUnits(@alignOf(u8)), 0);

        const file_tokens = try lexer.lexFile(file_code, "<unknown>", self.gpa, .only_invalid);

        const file_node, var arena = try parser.parseFile(file_code, file_tokens, "<unknown>", self.gpa);
        self.gpa.free(file_tokens);

        const file_ir = try lowerer.lowerFile(file_code, "<unknown>", file_node, self.gpa);
        _ = arena.reset(.free_all);


        var instructions_span: Span = .{ .start = self.instructions.items.len, .end = undefined };
        for (file_ir) |*instr| instr.tag.shiftMut(instructions_span.start, .forward);
        try self.instructions.appendSlice(self.gpa, file_ir);
        instructions_span.end = self.instructions.items.len;
        self.gpa.free(file_ir);


        var it_interpretator: InlineTimeInterpretator = .{
            .inliner = self,
        };

        try it_interpretator.jobs.append(it_interpretator.inliner.gpa, .{
            .parent = 0,
            .specific = .{ .start = .{} }
        });
        try it_interpretator.jobs.append(it_interpretator.inliner.gpa, .{
            .parent = 0,
            .specific = .{ .compute = .{
                .index = instructions_span.start,
            } }
        });

        var type_index: ValueContainer = undefined;
        defer type_index.deinit(self.gpa);

        while (true) {
            try it_interpretator.step();

            switch (it_interpretator.jobs.getLast().specific) {
                .start => |d| { type_index = d.result; break; },
                else => {},
            }
        }

        const result = type_index.toInt(u32) catch unreachable;

        try self.cached_files.append(self.gpa, .{
            .file_path = try self.gpa.dupe(u8, file_path),
            .file_code = file_code,
            .type_index = result,
            .span = instructions_span,
        });

        return result;
    }
};
pub const InlineTimeInterpretator = struct {
    inliner: *Inliner,
    jobs: std.ArrayList(Job) = .empty,

    pub const Job = struct {
        parent: usize,
        specific: Specific,

        pub const Specific = union(enum) {
            start: Start,
            compute: Compute,

            pub const Start = struct {
                result: ValueContainer = undefined,
            };

            pub const Compute = struct {
                values: std.ArrayList(ValueContainer) = .empty,
                index: usize,

                state: State = .asking_for_values,

                pub const State = union(enum) {
                    asking_for_values,
                    computing,
                };
            };
        };
    };

    pub fn step(self: *InlineTimeInterpretator) !void {
        const job_index = self.jobs.items.len-1;

        switch (self.jobs.items[job_index].specific) {
            .start => {
                _ = self.jobs.pop();
            },

            .compute => |*d| {
                const instruction = self.inliner.instructions.items[d.index];

                switch (d.state) {
                    .asking_for_values => {
                        switch (instruction.tag) {
                            .identifier => utils.todo(),
                            .int => utils.todo(),

                            .decl => utils.todo(),
                            .assign => utils.todo(),
                            .ret => utils.todo(),

                            .block => utils.todo(),

                            .field => utils.todo(),
                            .struct_def => {
                                d.state = .computing;
                            },

                            .func_def => utils.todo(),
                        }
                    },

                    .computing => {
                        switch (instruction.tag) {
                            .identifier => utils.todo(),
                            .int => utils.todo(),

                            .decl => utils.todo(),
                            .assign => utils.todo(),
                            .ret => utils.todo(),

                            .block => utils.todo(),

                            .field => utils.todo(),
                            .struct_def => |instruction_d| {
                                if (instruction_d.fields.len != 0) utils.todo();

                                const result: TypeInfo.Struct = .{
                                    .source = d.index,
                                    .decls = try self.inliner.gpa.alloc(TypeInfo.StaticDecl, instruction_d.decls.len),
                                    .inlined_decls = try self.inliner.gpa.alloc(InlinedDecls, 0), // utils.todo();
                                };

                                for (instruction_d.decls, result.decls) |decl, *out| {
                                    out.name = try self.inliner.gpa.dupe(u8, decl.name);

                                    out.static_value_index = self.inliner.static_values.items.len;
                                    try self.inliner.static_values.append(self.inliner.gpa, .{ .unevaluated = .{ .ty = decl.ty, .value = decl.value } });
                                }

                                const type_index = try self.inliner.pool.put(.{ .@"struct" = result }, self.inliner.gpa);

                                try self.putValueToParentJob(self.jobs.items[job_index].parent, try .fromInt(u32, type_index, self.inliner.gpa));

                                _ = self.jobs.pop();
                            },

                            .func_def => utils.todo(),
                        }
                    },
                }
            },
        }
    }

    fn putValueToParentJob(self: *InlineTimeInterpretator, parent: usize, value: ValueContainer) !void {
        switch (self.jobs.items[parent].specific) {
            .start => |*d| {
                d.result = value;
            },

            .compute => |*d| {
                try d.values.append(self.inliner.gpa, value);
            },
        }
    }
};

pub const ValueContainer = struct {
    data: []u8, ty: u32,

    pub fn deinit(self: ValueContainer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn fromInt(comptime T: type, value: T, allocator: std.mem.Allocator) !ValueContainer {
        const byte_count = comptime (std.math.ceilPowerOfTwo(usize, std.math.divCeil(usize, @typeInfo(T).int.bits, 8) catch unreachable) catch unreachable);
        const data = try allocator.alloc(u8, byte_count);

        std.mem.writeInt(T, @ptrCast(data), value, .native);

        return .{
            .data = data,
            .ty = switch (@typeInfo(T).int.signedness) { .signed => 0, .unsigned => 65536 } + @as(u32, @typeInfo(T).int.bits),
        };
    }

    pub fn toInt(self: ValueContainer, comptime T: type) !T {
        if (self.ty != switch (@typeInfo(T).int.signedness) { .signed => 0, .unsigned => 65536 } + @as(u32, @typeInfo(T).int.bits)) return error.MismatchedType;

        const byte_count = comptime (std.math.ceilPowerOfTwo(usize, std.math.divCeil(usize, @typeInfo(T).int.bits, 8) catch unreachable) catch unreachable);

        const result = std.mem.readInt(T, self.data[0..byte_count], .native);

        return result;
    }
};



pub fn inlineFile(cwd: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !void {
    var inliner: Inliner = .{
        .cwd = cwd,
        .io = io,
        .gpa = gpa,
    };
    defer inliner.deinit();

    const type_index = try inliner.import(file_path);

    std.debug.print("{}\n", .{ type_index });
}
