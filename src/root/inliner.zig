const std = @import("std");

const utils = @import("utils.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");

const Span = utils.Span;
const Instruction = lowerer.Instruction;

pub const Index = u32;
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
    ty_descs: std.ArrayList(TypeDesc),

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

            else => self.ty_descs.items[index-131074].toInfo()
        }
    }

    pub fn put(self: *TypePool, info: TypeInfo) TypeIndex {
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
};

pub const Inliner = struct {
    source_instructions: std.ArrayList(Instruction),
    executable_instructions: std.ArrayList(Instruction),
    
    ty_pool: TypePool,
    static_values: std.ArrayList(ValueContainer),
    func_defs: FuncDef,

    gpa: std.mem.Allocator,

    

    pub const FuncDef = struct {
        params: []const Param,
        ret_ty: TypeIndex,
        body: Span, // executable instructions
        
        pub const Param = struct {
            name: []const u8,
            ty: TypeIndex,
        };
    };

    pub fn makeInstructionsExecutable(self: *Inliner, source_span: Span) !void {
        var source_pos = source_span.start;
        
        while (source_pos != source_span.end) {
            var instruction = self.source_instructions.items[source_pos];
            instruction.cloneMut(self.gpa);
            
            switch (instruction) {
                .get => {
                    try self.executable_instructions.append(self.gpa, instruction);
                },
                .int => {
                    try self.executable_instructions.append(self.gpa, instruction);
                },
            
                .struct_def => {
                    try self.executable_instructions.append(self.gpa, instruction);
                },
                // func_def: FuncDef,
            
                // decl: Decl,
                // assign: Assign,
            
                // block: Block,
            
                // copy: Copy,

                // static_ref: StaticRef,
                // subst_param: SubstParam,
                
                else => unreachable, // TODO
            }
        }
    }
};