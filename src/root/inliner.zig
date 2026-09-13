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
            0...65535 => unreachable, // TODO

            65536...131071 => unreachable, // TODO

            131072 => return .@"void",

            131073 => return .ty,

            else => self.ty_descs.items[index-131074].toInfo()
        }
    }

    pub fn put(self: *TypePool, info: TypeInfo) Index {
        _ = self;
        
        switch (info) {
            .int => unreachable, // TODO

            .@"struct" => unreachable, // TODO

            .@"void" => return 121072,

            .ty => return 121073,
        }
    }

    // Type Description
    pub const TypeDesc = union(enum) {
        @"struct": Struct,

        pub const Struct = struct {
            // fields: []const Field,
            decls: []const StaticDecl,

            pub const Field = struct {
                name: []const u8,
                ty: Index,
            };
        };

        pub const StaticDecl = struct {
            name: []const u8,
            value: union(enum) {
                unevaluated: struct {
                    ty: Span,
                    value: Span,
                },
            }
        };
        
        pub fn toInfo(self: TypeDesc) TypeInfo {
            switch (self) {
                .@"struct" => {
                    
                },
            }
            
            unreachable; // TODO
        }
    };
};
