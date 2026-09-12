const std = @import("std");

const utils = @import("utils.zig");

const Span = utils.Span;
const Instruction = @import("lowerer.zig").Instruction;

pub const Inliner = struct {
    source_instruction: []const Instruction,
    executable_instructions: std.ArrayList(Instruction),

    files: std.StringHashMap(usize),

    ty_defs: std.ArrayList(TypeDef),
    static_values: std.ArrayList(ValueContainer),

    pub const TypeDef = union(enum) {
        struct_def: StructDef,

        pub const StructDef = struct {
            // filds: []const Field,
            decls: []Decl,

            pub const Decl = struct {
                name: []const u8,

                value: union(enum) {
                    unevaluated: struct {
                        type: Span,
                        value: Span,
                    },
                    evaluated: usize,
                },
            };
        };
    };

    pub fn sizeOf(self: Inliner, ty: Type) usize {
        return 1;
    }

    pub fn alignOf(self: Inliner, ty: Type) usize {
        return 1;
    }
};

pub const ValueContainer = struct { 
    value: []const u8,
    ty: Type,

    pub fn deinit(self: ValueContainer, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.ty.deinit(allocator);
    }
};

pub const Type = union(enum) {
    int_literal: void,
    int: Int,

    defined: usize,

    reference: *Type,
    ty: void,

    pub const Int = struct {
        bit_count: u16,
        signedness: Signedness,

        pub const Signedness = enum {
            signed,
            unsigned,
        };
    };

    pub fn deinit(self: Type, allocator: std.mem.Allocator) void {
        switch (self) {
            .int_literal => {},
            .int => {},

            .defined => {},

            .reference => |d| {
                d.deinit(allocator);
                allocator.destroy(d);
            },

            .ty => {},
        }
    }

    pub fn clone(self: Type, allocator: std.mem.Allocator) !Type {
        switch (self) {
            .int_literal => return self,
            .int => return self,

            .defined => return self,

            .reference => |d| return .{ .reference = try utils.createAndCopy(Type, allocator, try d.clone(allocator)) },
            .ty => return self,
        }
    }

    pub fn removeReference(self: Type) Type {
        return switch (self) {
            .reference => |d| d.*,
            else => self,
        };
    }
};

pub fn inlineFile() void {}
