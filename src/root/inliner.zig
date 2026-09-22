const std = @import("std");

const utils = @import("utils.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");

const Span = utils.Span;
const Instruction = lowerer.Instruction;

pub const Index = usize;
pub const TypeIndex = Index;

pub const TypeInfo = union(enum) {
    int: Int,

    @"struct": Struct,
    @"fn": Fn,

    @"void",

    ty,

    pub const Int = struct {
        bits: u16,
        signedness: Signedness,

        pub const Signedness = enum {
            signed,
            unsigned,
        };
    };

    pub const Struct = struct {
        fields: []const Field,
        decls: []const StaticDecl,

        pub const Field = struct {
            name: []const u8,
            ty: TypeIndex,
        };

        pub fn getDecl(self: Struct, name: []const u8) ?Index {
            for (self.decls) |decl| if (std.mem.eql(u8, decl.name, name)) return decl.value;
            return null;
        }
    };
    pub const StaticDecl = struct {
        name: []const u8,
        value: Index,
    };

    pub const Fn = struct {
        params: []const TypeIndex,
        ret_ty: TypeIndex,
    };
};

pub const TypePool = struct {
    ty_descs: std.ArrayList(TypeDesc) = .empty,

    pub fn get(self: TypePool, index: TypeIndex) TypeInfo {
        switch (index) {
            0...65535 => return .{ .int = .{
                .signedness = .signed,
                .bits = @truncate(index-0),
            } },

            65536...131071 => return .{ .int = .{
                .signedness = .unsigned,
                .bits = @truncate(index-65536),
            } },

            131072 => return .@"void",

            131073 => return .ty,

            else => return self.ty_descs.items[index-131074].toInfo()
        }
    }

    pub fn put(self: *TypePool, info: TypeInfo, gpa: std.mem.Allocator) !TypeIndex {
        switch (info) {
            .int => |d| {
                return switch (d.signedness) {
                    .signed => @as(Index, d.bits)+0,
                    .unsigned => @as(Index, d.bits)+65536,
                };
            }, // TODO

            .@"struct" => |d| {
                const index: Index = @truncate(self.ty_descs.items.len+131074);

                try self.ty_descs.append(gpa, .{ .@"struct" = d });

                return index;
            }, // TODO
            .@"fn" => unreachable, // TODO

            .@"void" => return 131072,

            .ty => return 131073,
        }
    }

    // Type Description
    const TypeDesc = union(enum) {
        @"struct": TypeInfo.Struct,
        @"fn": TypeInfo.Fn,

        pub fn toInfo(self: TypeDesc) TypeInfo {
            switch (self) {
                .@"struct" => |d| return .{ .@"struct" = d },
                .@"fn" => |d| return .{ .@"fn" = d },
            }
        }
    };
};



pub const ValueContainer = struct {
    data: []u8,
    ty: TypeIndex,

    pub fn fromInt(comptime Int: type, value: Int, allocator: std.mem.Allocator) !ValueContainer {
        const bit_size = @typeInfo(Int).int.bits;
        const signedness = @typeInfo(Int).int.signedness;
        const alignment = @alignOf(Int);

        const byte_size = comptime (std.math.divCeil(usize, bit_size, 8) catch unreachable);

        var result: ValueContainer = undefined;

        result.data = try allocator.alignedAlloc(u8, .fromByteUnits(alignment), byte_size);
        @as(*Int, @ptrCast(@alignCast(result.data))).* = value;

        result.ty = switch (signedness) {
            .signed => @as(Index, bit_size)+0,
            .unsigned => @as(Index, bit_size)+65536,
        };

        return result;
    }

    pub fn toInt(self: ValueContainer, comptime Int: type) !Int {
        const bit_size = @typeInfo(Int).int.bits;
        const signedness = @typeInfo(Int).int.signedness;

        const expected_ty = switch (signedness) {
            .signed => @as(Index, bit_size)+0,
            .unsigned => @as(Index, bit_size)+65536,
        };

        if (self.ty != expected_ty) return error.MismatchedTypes;

        return @as(*Int, @ptrCast(@alignCast(self.data))).*;
    }
};

pub const Inliner = struct {
    instructions: std.ArrayList(Instruction) = .empty,

    ty_pool: TypePool = .{},
    static_values: std.ArrayList(StaticValue) = .empty,
    func_defs: std.ArrayList(FuncDef) = .empty,

    gpa: std.mem.Allocator,



    pub const StaticValue = union(enum) {
        evaluated: ValueContainer,
        unevaluated: struct { ty: ?Span, value: Span },
        evaluating,
    };

    pub const FuncDef = struct {
        params: []const Param,
        ret_ty: TypeIndex,
        body: Span,

        pub const Param = struct {
            name: []const u8,
            ty: TypeIndex,
        };
    };

    // callee owns `instructions` data
    // caller owns `instructions`
    pub fn putInstructions(self: *Inliner, instructions: []Instruction) !Span {
        var span: Span = .{ .start = self.instructions.items.len, .end = undefined };
        try self.instructions.appendSlice(self.gpa, instructions);
        span.end = self.instructions.items.len;

        return span;
    }
};

pub const InlineTimeInterpretator = struct {
    jobs: std.ArrayList(Job) = .empty,

    inliner: *Inliner,

    pub const Job = struct {
        requested: union(enum) {
            static_value: Index,
            span: Span,
        },
        frames: std.ArrayList(Frame),

        pub const Frame = struct {
            ty: FrameTy,
            pos: usize,
        };

        pub const FrameTy = union(enum) {
            func_check: FuncCheck,
            evaluation: Evaluation,

            pub const FuncCheck = struct {
                instructions: Span,
                pos: usize,
                values: std.AutoHashMap(usize, ValueContainer)
            };

            pub const Evaluation = struct {
                instructions: Span,
                pos: usize,
                values: std.AutoHashMap(usize, ValueContainer)
            };
        };
    };
};

pub fn inlineFile(file_code: [:0]const u8, file_path: []const u8, gpa: std.mem.Allocator) !void {
    const file_tokens = try lexer.lexFile(file_code, file_path, gpa, false);

    const file_node, var arena = try parser.parseFile(file_code, file_tokens, file_path, gpa);
    gpa.free(file_tokens);

    const file_ir = try lowerer.lowerFile(file_node, gpa);
    _ = arena.reset(.free_all);

    var inliner: Inliner = .{
        .gpa = gpa,
    };

    var it_interpretator: InlineTimeInterpretator = .{
        .inliner = inliner,
    };

    const source_span = try inliner.putInstructions(file_ir);
    gpa.free(file_ir);

    it_interpretator.jobs.append(it_interpretator.inliner.gpa, .{ .requested = .{ .span = source_span } });
    
}
