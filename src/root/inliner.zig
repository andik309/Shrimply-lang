const std = @import("std");

const utils = @import("utils.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");

const Span = utils.Span;
const Instruction = lowerer.Instruction;

pub const Index = u32;

pub const TypeInfo = union(enum) {
    int: Int,

    @"struct": Struct,

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
            ty: Index,
        };
    };

    pub const StaticDecl = struct {
        name: []const u8,
        value: Index,
    };
};

pub const TypePool = struct {
    ty_descs: std.ArrayList(TypeDesc),

    pub fn get(self: TypePool, index: Index) TypeInfo {
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

            else => self.ty_descs.items[index-131074].toInfo()
        }
    }

    pub fn put(self: *TypePool, info: TypeInfo) Index {
        _ = self;

        switch (info) {
            .int => |d| {
                return switch (d.signedness) {
                    .signed => @as(u32, d.bits)+0,
                    .unsigned => @as(u32, d.bits)+65536,
                }; 
            }, // TODO

            .@"struct" => unreachable, // TODO

            .@"void" => return 121072,

            .ty => return 121073,
        }
    }

    // Type Description
    const TypeDesc = union(enum) {
        @"struct": TypeInfo.Struct,

        pub fn toInfo(self: TypeDesc) TypeInfo {
            switch (self) {
                .@"struct" => |d| return .{ .@"struct" = d },
            }
        }
    };
};
