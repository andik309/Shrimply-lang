const std = @import("std");
const utils = @import("utils.zig");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const Span = utils.Span;

const ASTNode = parser.ASTNode;

pub const Instruction = struct {
    loc: Span,
    tag: Tag,

    pub const Tag = union(enum) {
        identifier: Identifier,
        int: Int,

        decl: Decl,
        assign: Assign,
        ret: Ret,

        call: Call,

        block: Block,

        struct_def: StructDef,

        func_def: FuncDef,


        pub const Identifier = []const u8;
        pub const Int = []const u8;

        pub const Decl = struct { name: []const u8, ty: ?Span, value: Span };
        pub const Assign = struct { target: Span, value: Span };
        pub const Ret = struct { operand: ?Span };

        pub const Call = struct { callee: Span, args: []Span };

        pub const Block = struct { body: []Span };

        pub const StructDef = struct { decls: []Decl, fields: []Field };
        pub const Field = struct { name: []const u8, ty: ?Span, value: ?Span };

        pub const FuncDef = struct { params: []Param, ret_ty: Span, body: Span };
        pub const Param = struct { name: []const u8, ty: Span };


        pub fn deinit(self: Tag, allocator: std.mem.Allocator) void {
            switch (self) {
                .identifier => |d| {
                    allocator.free(d);
                },
                .int => |d| {
                    allocator.free(d);
                },

                .decl => |d| {
                    allocator.free(d.name);
                },
                .assign => {},
                .ret => {},

                .call => |d| {
                    allocator.free(d.args);
                },

                .block => |d| {
                    allocator.free(d.body);
                },

                .struct_def => |d| {
                    for (d.fields) |field| {
                        allocator.free(field.name);
                    }
                    allocator.free(d.fields);

                    for (d.decls) |decl| {
                        allocator.free(decl.name);
                    }
                    allocator.free(d.decls);
                },

                .func_def => |d| {
                    for (d.params) |param| {
                        allocator.free(param.name);
                    }
                    allocator.free(d.params);
                },
            }
        }

        pub fn shiftMut(self: *Tag, dist: usize, direction: utils.Direction) void {
            switch (self.*) {
                .identifier => {},
                .int => {},

                .decl => |*d| {
                    if (d.ty) |*ty| ty.shiftMut(dist, direction);
                    d.value.shiftMut(dist, direction);
                },
                .assign => |*d| {
                    d.target.shiftMut(dist, direction);
                    d.value.shiftMut(dist, direction);
                },
                .ret => |*d| {
                    if (d.operand) |*operand| operand.shiftMut(dist, direction);
                },

                .call => |*d| {
                    d.callee.shiftMut(dist, direction);
                    for (d.args) |*arg| arg.shiftMut(dist, direction);
                },

                .block => |d| {
                    for (d.body) |*body_part| body_part.shiftMut(dist, direction);
                },

                .struct_def => |d| {
                    for (d.decls) |*decl| {
                        if (decl.ty) |*ty| ty.shiftMut(dist, direction);
                        decl.value.shiftMut(dist, direction);
                    }
                    for (d.fields) |*field| {
                        if (field.ty) |*ty| ty.shiftMut(dist, direction);
                    }
                },

                .func_def => |*d| {
                    for (d.params) |*param| param.ty.shiftMut(dist, direction);
                    d.ret_ty.shiftMut(dist, direction);
                    d.body.shiftMut(dist, direction);
                },
            }
        }
    };
};

pub const Lowerer = struct {
    instructions: std.ArrayList(Instruction) = .empty,
    gpa: std.mem.Allocator,

    pub fn lowerNode(self: *Lowerer, node: *const ASTNode) anyerror!Span {
        var result_span: Span = .{
            .start = self.instructions.items.len,
            .end = undefined,
        };

        switch (node.tag) {
            .identifier => |d| {
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = .{ .identifier = try self.gpa.dupe(u8, d) } });
            },
            .string => try utils.todoAsError(),
            .char => try utils.todoAsError(),
            .int => |d| {
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = .{ .int = try self.gpa.dupe(u8, d) } });
            },

            .decl => |d| {
                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.Decl = .{
                    .name = try self.gpa.dupe(u8, d.name),
                    .ty = try self.lowerOptionalNode(d.ty),
                    .value = try self.lowerNode(d.value),
                };

                self.instructions.items[result_index].tag = .{ .decl = result };
            },
            .assign => |d| {
                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.Assign = .{
                    .target = try self.lowerNode(d.target),
                    .value = try self.lowerNode(d.value),
                };

                self.instructions.items[result_index].tag = .{ .assign = result };
            },
            .ret => |d| {
                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.Ret = .{
                    .operand = try self.lowerOptionalNode(d.operand),
                };

                self.instructions.items[result_index].tag = .{ .ret = result };
            },

            .call => |d| {
                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.Call = .{
                    .callee = try self.lowerNode(d.callee),
                    .args = try self.gpa.alloc(Span, d.args.len),
                };

                for (d.args, result.args) |*arg, *out| {
                    out.* = try self.lowerNode(arg);
                }

                self.instructions.items[result_index].tag = .{ .call = result };
            },

            .block => |d| {
                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.Block = .{
                    .body = try self.gpa.alloc(Span, d.body.len),
                };

                for (d.body, result.body) |body_part, *out| {
                    out.* = try self.lowerNode(&body_part);
                }

                self.instructions.items[result_index].tag = .{ .block = result };
            },

            .struct_def => |d| {
                if (d.fields.len != 0) try utils.todoAsError();
                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.StructDef = .{
                    .fields = try self.gpa.alloc(Instruction.Tag.Field, 0),
                    .decls = try self.gpa.alloc(Instruction.Tag.Decl, d.decls.len),
                };

                for (d.decls, result.decls) |decl, *out| {
                    out.name = try self.gpa.dupe(u8, decl.tag.decl.name);
                    out.ty = try self.lowerOptionalNode(decl.tag.decl.ty);
                    out.value = try self.lowerNode(decl.tag.decl.value);
                }

                self.instructions.items[result_index].tag = .{ .struct_def = result };
            },
            .field => unreachable,

            .func_def => |d| {
                if (d.params.len != 0) try utils.todoAsError();

                const result_index = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .loc = node.loc, .tag = undefined });

                const result: Instruction.Tag.FuncDef = .{
                    .params = try self.gpa.alloc(Instruction.Tag.Param, d.params.len),
                    .ret_ty = try self.lowerNode(d.ret_ty),
                    .body = try self.lowerNode(d.body),
                };

                self.instructions.items[result_index].tag = .{ .func_def = result };
            },
            .param => unreachable,
        }

        result_span.end = self.instructions.items.len;

        return result_span;
    }

    pub fn lowerOptionalNode(self: *Lowerer, optional_node: ?*const ASTNode) anyerror!?Span {
        return if (optional_node) |node| try self.lowerNode(node) else null;
    }
};

pub fn lowerFile(code: [:0]const u8, file_path: []const u8, file_node: *ASTNode, gpa: std.mem.Allocator) ![]Instruction {
    var lowerer: Lowerer = .{
        .gpa = gpa,
    };

    _ = code;
    _ = file_path;

    _ = try lowerer.lowerNode(file_node);

    return lowerer.instructions.toOwnedSlice(lowerer.gpa);
}
