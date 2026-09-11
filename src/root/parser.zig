const std = @import("std");
const utils = @import("utils.zig");

const lexer = @import("lexer.zig");

const Span = utils.Span;
const Token = lexer.Token;

pub const ASTNode = struct {
    loc: Span,
    tag: Tag,

    pub const Tag = union(enum) {
        identifier: Identifier,
        string: String,
        char: Char,
        int: Int,

        // add: Add,
        // sub: Sub,
        // mul: Mul,
        // div: Div,

        decl: Decl,
        assign: Assign,
        ret: Ret,

        block: Block,

        field: Field,
        struct_def: StructDef,

        func_def: FuncDef,


        pub const Identifier = []const u8;
        pub const String = []const u8;
        pub const Char = []const u8;
        pub const Int = []const u8;

        // pub const Add = struct { rhs: *ASTNode, lhs: *ASTNode };
        // pub const Sub = struct { rhs: *ASTNode, lhs: *ASTNode };
        // pub const Mul = struct { rhs: *ASTNode, lhs: *ASTNode };
        // pub const Div = struct { rhs: *ASTNode, lhs: *ASTNode };

        pub const Decl = struct { name: []const u8, ty: ?*ASTNode, value: *ASTNode };
        pub const Assign = struct { target: *ASTNode, value: *ASTNode };
        pub const Ret = struct { operand: ?*ASTNode };

        pub const Block = struct { body: []ASTNode };

        pub const Field = struct { name: []const u8, ty: ?*ASTNode, value: ?*ASTNode };
        pub const StructDef = struct { decls: []ASTNode, fields: []ASTNode };

        pub const FuncDef = struct { params: []ASTNode, ret_ty: *ASTNode, body: *ASTNode };
    };

    pub const cac = cacNode;
    pub const caco = cacoNode;
};

pub fn cacNode(node: ASTNode, allocator: std.mem.Allocator) std.mem.Allocator.Error!*ASTNode {
    return try utils.createAndCopy(ASTNode, allocator, node);
}
pub fn cacoNode(node: ?ASTNode, allocator: std.mem.Allocator) std.mem.Allocator.Error!?*ASTNode {
    return try utils.createAndCopyOptional(ASTNode, allocator, node);
}

const Parser = struct {
    code: [:0]const u8,
    file_path: []const u8,

    tokens: []const Token,
    pos: usize = 0,

    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,

    pub fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    pub fn take(self: *Parser) Token {
        const token = self.peek();
        self.pos += 1;
        return token;
    }

    pub fn eat(self: *Parser, expected_tag: Token.Tag) !Span {
        const taken = self.take();

        if (taken.tag != expected_tag) {
            utils.highlightCode(self.code, self.file_path, taken.loc, "parser error: expected {f}, found {f}", .{ expected_tag, taken.tag });
            return error.EatingFailed;
        } else return taken.loc;
    }

    pub fn accept(self: *Parser, expected_tag: Token.Tag) ?Span {
        const peeked = self.peek();

        if (peeked.tag == expected_tag) {
            self.pos += 1;
            return peeked.loc;
        } else {
            return null;
        }
    }

    pub fn parseFile(self: *Parser) !ASTNode {
        var decls: std.ArrayList(ASTNode) = .empty;
        defer decls.deinit(self.gpa);

        while (self.peek().tag != .eof) {
            const decl = try self.parseDeclaration();
            _ = try self.eat(.@"punct ;");

            try decls.append(self.gpa, decl);
        }

        return .{
            .loc = .{
                .start = 0,
                .end = 1,
            },
            .tag = .{ .struct_def = .{
                .fields = try self.gpa.alloc(ASTNode, 0),
                .decls = try self.arena.allocator().dupe(ASTNode, decls.items),
            } },
        };
    }
    // <file> ::= (<declaration>)*

    pub fn parseFullStatement(self: *Parser) anyerror!ASTNode {
        const result = try self.parseStatement();
        _ = try self.eat(.@"punct ;");

        return result;
    }
    // <full_statement> ::= <statement> ";"

    pub fn parseStatement(self: *Parser) anyerror!ASTNode {
        switch (self.peek().tag) {
            .@"keyword let" => return try self.parseDeclaration(),
            else => {
                var result = try self.parseFullExpression();

                if (self.accept(.@"op =")) |loc| {
                    const value = try (try self.parseFullExpression()).cac(self.arena.allocator());

                    result = ASTNode{
                        .loc = loc,
                        .tag = .{ .assign = .{
                            .target = try result.cac(self.arena.allocator()),
                            .value = value,
                        } },
                    };
                }

                return result;
            }
        }
    }
    // <statement> ::= <declaration>
    //               | <full_expression> "=" <full_expression>
    //               | <full_expression>

    pub fn parseDeclaration(self: *Parser) anyerror!ASTNode {
        const loc = try self.eat(.@"keyword let");

        const name = self.parseIdentifier(try self.eat(.identifier)) catch |err| switch (err) {
            error.InvalidString => {
                utils.highlightCode(self.code, self.file_path, self.tokens[self.pos-1].loc, "parser error: invalid string literal", .{});
                return err;
            },
            else => return err,
        };

        const ty = if (self.peek().tag == .@"punct :") blk: {
            self.pos += 1;
            break :blk try (try self.parseFullExpression()).cac(self.arena.allocator());
        } else null;

        _ = try self.eat(.@"op =");

        const value = try (try self.parseFullExpression()).cac(self.arena.allocator());

        return .{
            .loc = loc,
            .tag = .{ .decl = .{
                .name = name,
                .ty = ty,
                .value = value,
            } },
        };
    }
    // <declaration> ::= "let" <identifier> (":" <full_statement>)? "=" <full_expression>

    pub fn parseFullExpression(self: *Parser) anyerror!ASTNode {
        if (self.peek().tag == .@"keyword return") {
            const loc = self.take().loc;

            if (self.peek().tag == .@"punct ;") {
                return .{
                    .loc = loc,
                    .tag = .{ .ret = .{
                        .operand = null,
                    } },
                };
            } else {
                const operand = try (try self.parseFullExpression()).cac(self.arena.allocator());

                return .{
                    .loc = loc,
                    .tag = .{ .ret = .{
                        .operand = operand,
                    } },
                };
            }
        }
        else return try self.parseExprLogicOr();
    }
    // <full_expression> ::= <expr_logic_logic_or>
    //                     | "return" (<full_expression>)?

    pub fn parseExprLogicOr(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprLogicXor();
        return result;
    }
    pub fn parseExprLogicXor(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprLogicAnd();
        return result;
    }
    pub fn parseExprLogicAnd(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprBitwise();
        return result;
    }
    // <expr_logic_or>  ::= <expr_logic_logic_xor> ("||" <expr_logic_logic_xor>)*
    // <expr_logic_xor> ::= <expr_logic_logic_and> ("^^" <expr_logic_logic_and>)*
    // <expr_logic_and> ::= <expr_bitwise> ("&&" <expr_bitwise>)*

    pub fn parseExprBitwise(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprEquality();
        return result;
    }
    // <expr_bitwise>  ::= <expr_equality> (("|" | "^" | "&") <expr_equality>)*

    pub fn parseExprEquality(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprComparison();
        return result;
    }
    pub fn parseExprComparison(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprShift();
        return result;
    }
    // <expr_equality> ::= <expr_comparison> (("==" | "!=") <expr_comparison>)*
    // <expr_comparison> ::= <expr_shift> (("<" | "<=" | ">" | ">=") <expr_shift>)*

    pub fn parseExprShift(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprAdditive();
        return result;
    }
    pub fn parseExprAdditive(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprMultiplicative();
        return result;
    }
    pub fn parseExprMultiplicative(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprPrefix();
        return result;
    }
    // <expr_shift> ::= <expr_additive> (("<<" | ">>") <expr_additive>)*
    // <expr_additive> ::= <expr_multiplicative> (("+" | "-") <expr_multiplicative>)*
    // <expr_multiplicative> ::= <expr_prefix> (("*" | "/" | "%") <expr_prefix>)*

    pub fn parseExprPrefix(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprPostfix();
        return result;
    }
    // <expr_prefix> ::= <expr_postfix>
    //                 | "-" <expr_prefix>
    //                 | "+" <expr_prefix>
    //                 | "~" <expr_prefix>
    //                 | "!" <expr_prefix>
    //                 | "&" <expr_prefix>

    pub fn parseExprPostfix(self: *Parser) anyerror!ASTNode {
        // TODO
        const result = try self.parseExprPrimary();
        return result;
    }
    // <expr_postfix> ::= <expr_primary>
    //                  | <expr_postfix> "(" (<full_expression> ("," <full_expression>)* ","?)? ")"
    //                  | <expr_postfix> "[" <full_expression> "]"
    //                  | <expr_postfix> "." <identifier>
    //                  | <expr_postfix> ".*"
    //                  | <expr_postfix> ".?"
    //                  | <expr_postfix> ".!"

    pub fn parseExprPrimary(self: *Parser) anyerror!ASTNode {
        const taken = self.take();

        switch (taken.tag) {
            .identifier => {
                const content = try self.parseIdentifier(taken.loc);

                return .{
                    .loc = taken.loc,
                    .tag = .{ .identifier = content },
                };
            },
            .int => {
                const content = try self.arena.allocator().dupe(u8, self.code[taken.loc.start..taken.loc.end]);

                return .{
                    .loc = taken.loc,
                    .tag = .{ .int = content },
                };
            },
            .str => {
                const content = try unescapeString(self.code[taken.loc.start+1..taken.loc.end-1], self.gpa);
                defer self.gpa.free(content);

                return .{
                    .loc = taken.loc,
                    .tag = .{ .string = try self.arena.allocator().dupe(u8, content) },
                };
            },
            .char => {
                const content = try unescapeString(self.code[taken.loc.start+1..taken.loc.end-1], self.gpa);
                defer self.gpa.free(content);

                return .{
                    .loc = taken.loc,
                    .tag = .{ .char = try self.arena.allocator().dupe(u8, content) },
                };
            },

            .@"delim {" => {
                var body: std.ArrayList(ASTNode) = .empty;
                defer body.deinit(self.gpa);

                while (self.accept(.@"delim }") == null) {
                    const body_part = try self.parseFullStatement();
                    try body.append(self.gpa, body_part);
                }

                return .{
                    .loc = taken.loc,
                    .tag = .{ .block = .{
                        .body = try self.arena.allocator().dupe(ASTNode, body.items),
                     } },
                };
            },

            .@"keyword func" => {
                var params: std.ArrayList(ASTNode) = .empty;

                _ = try self.eat(.@"delim (");

                while (self.peek().tag != .@"delim )") {
                    const param = try self.parseFuncParam();
                    try params.append(self.gpa, param.*);

                    if (self.accept(.@"punct ,") == null) break;
                }

                _ = try self.eat(.@"delim )");

                const ret_ty = try (try self.parseFullExpression()).cac(self.arena.allocator());

                const body = try (try self.parseStatement()).cac(self.arena.allocator());

                return .{
                    .loc = taken.loc,
                    .tag = .{ .func_def = .{
                        .params = try params.toOwnedSlice(self.gpa),
                        .ret_ty = ret_ty,
                        .body = body,
                    } },
                };
            },

            else => {
                utils.highlightCode(self.code, self.file_path, taken.loc, "parser error: found unexpected token - {f}", .{ taken.tag });
                return error.ParsingError;
            }
        }
    }
    // <expr_primary> ::= <identifier>
    //                  | <string_literal>
    //                  | <int_literal>
    //                  | "(" <full_expression> ")"
    //                  | "{" <full_statement>* "}"
    //                  | "if" "(" <full_expression> ")" <statement> ("else" <statement>)?
    //                  | "switch" "(" <full_expression> ")" "{" "}"
    //                  | "while" "(" <full_expression> ")" "|" "|" "{" "}" ("else" <statement>)
    //                  | "for" "(" <full_expression> ")" (".." <full_expression>) "|" "|" "{" "}" ("else" <statement>)
    //                  | "func" "(" (<func_param> ("," <func_param>)* ","?)? ")" ":" <full_expression> <statement>
    //                  | "fn" "(" (<full_expression> ("," <full_expression>)* ","?)? ")" ":" <full_expression>
    //                  | "struct" "{" ((pub)? <declaration>)*  "}"
    //                  | "." (<full_expression>)?  "{" value "}"  // tuple init
    //                  | "." (<full_expression>)?  "{" .field = value "}"  // struct init
    //                  | ":" "(" ")" // tuple

    pub fn parseFuncParam(self: *Parser) !*ASTNode {
        _ = self;
        unreachable; // TODO
    }
    // <func_param> ::= <identifier> ":" <full_expression>

    pub fn parseIdentifier(self: *Parser, loc: Span) ![]const u8 {
        return switch (self.code[loc.start]) {
            '@' => blk: {
                const unescaped = try unescapeString(self.code[loc.start+2..loc.end-1], self.gpa);
                defer self.gpa.free(unescaped);

                break :blk try self.arena.allocator().dupe(u8, unescaped);
            },
            else => try self.arena.allocator().dupe(u8, self.code[loc.start..loc.end]),
        };
    }
};

pub fn parseFile(code: [:0]const u8, file_tokens: []const Token, file_path: []const u8, gpa: std.mem.Allocator) !struct { *ASTNode, std.heap.ArenaAllocator } {
    var parser: Parser = .{
        .code = code,
        .file_path = file_path,

        .tokens = file_tokens,

        .arena = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
    };
    errdefer _ = parser.arena.reset(.free_all);

    return .{ try (try parser.parseFile()).cac(parser.arena.allocator()), parser.arena };
}

pub fn unescapeString(str: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(str)) return error.InvalidString;

    var ret: std.ArrayList(u8) = .empty;

    var pos: usize = 0;
    while (pos != str.len) switch (str[pos]) {
        '\\' => {
            try ret.append(allocator, switch (str[pos+1]) {
                '0' => 0, 't' => 11, 'n' => 10, 'r' => 13,
                else => unreachable,
            });
            pos += 2;
        },
        else => |ch| {
            try ret.append(allocator, ch);
            pos += 1;
        },
    };

    return try ret.toOwnedSlice(allocator);
}
