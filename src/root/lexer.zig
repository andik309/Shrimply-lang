const std = @import("std");
const utils = @import("utils.zig");

pub const Span = utils.Span;

pub const Token = struct {
    tag: Tag,
    loc: Span,

    pub const Tag = enum {
        identifier,

        str,
        char,
        int,

        invalid,

        @"builtin @min",
        @"builtin @max",
        
        @"macro #alignOf",
        @"macro #sizeOf",
        
        @"macro #subst",
        @"macro #import",

        @"keyword struct",
        @"keyword func",
        @"keyword let",
        @"keyword const",
        @"keyword mut",
        @"keyword fn",
        @"keyword false",
        @"keyword true",
        @"keyword if",
        @"keyword while",
        @"keyword return",

        @"op +=",
        @"op -=",
        @"op *=",
        @"op /=",
        @"op %=",
        @"op |=",
        @"op &=",
        @"op ^=",
        @"op <<=",
        @"op >>=",
        @"op ||=",
        @"op &&=",
        @"op ^^=",
        @"op +",
        @"op -",
        @"op *",
        @"op /",
        @"op %",
        @"op |",
        @"op &",
        @"op ^",
        @"op <<",
        @"op >>",
        @"op ||",
        @"op &&",
        @"op ^^",
        @"op ==",
        @"op !=",
        @"op <=",
        @"op >=",
        @"op <",
        @"op >",
        @"op .*",
        @"op .?",
        @"op .!",
        @"op ~",
        @"op !",
        @"op =",

        @"punct .",
        @"punct ,",
        @"punct :",
        @"punct ;",

        @"delim (",
        @"delim )",
        @"delim [",
        @"delim ]",
        @"delim {",
        @"delim }",

        eof,

        pub fn format(self: Tag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{s}", .{ @tagName(self) });
        }

        pub const stringToKeywordTagMap = generating_map: {
            const kw_count = counting_kw: {
                var keyword_count = 0;
                for (@typeInfo(Tag).@"enum".fields) |field| if (std.mem.startsWith(u8, field.name, "keyword ")) {
                    keyword_count += 1;
                };
                break :counting_kw keyword_count;
            };

            var kvs: [kw_count]struct { []const u8, Tag } = undefined;
            var curr_kv = 0;

            for (@typeInfo(Tag).@"enum".fields) |field| if (std.mem.startsWith(u8, field.name, "keyword ")) {
                kvs[curr_kv].@"0" = field.name["keyword ".len..];
                kvs[curr_kv].@"1" = @enumFromInt(field.value);
                curr_kv += 1;
            };

            const map = std.StaticStringMap(Tag).initComptime(kvs);
            break :generating_map map;
        };

        pub const stringToBuiltinTagMap = generating_map: {
            const kw_count = counting_kw: {
                var keyword_count = 0;
                for (@typeInfo(Tag).@"enum".fields) |field| if (std.mem.startsWith(u8, field.name, "builtin ")) {
                    keyword_count += 1;
                };
                break :counting_kw keyword_count;
            };

            var kvs: [kw_count]struct { []const u8, Tag } = undefined;
            var curr_kv = 0;

            for (@typeInfo(Tag).@"enum".fields) |field| if (std.mem.startsWith(u8, field.name, "builtin ")) {
                kvs[curr_kv].@"0" = field.name["builtin ".len..];
                kvs[curr_kv].@"1" = @enumFromInt(field.value);
                curr_kv += 1;
            };

            const map = std.StaticStringMap(Tag).initComptime(kvs);
            break :generating_map map;
        };

        pub const stringToMacroTagMap = generating_map: {
            const kw_count = counting_kw: {
                var keyword_count = 0;
                for (@typeInfo(Tag).@"enum".fields) |field| if (std.mem.startsWith(u8, field.name, "macro ")) {
                    keyword_count += 1;
                };
                break :counting_kw keyword_count;
            };

            var kvs: [kw_count]struct { []const u8, Tag } = undefined;
            var curr_kv = 0;

            for (@typeInfo(Tag).@"enum".fields) |field| if (std.mem.startsWith(u8, field.name, "macro ")) {
                kvs[curr_kv].@"0" = field.name["macro ".len..];
                kvs[curr_kv].@"1" = @enumFromInt(field.value);
                curr_kv += 1;
            };

            const map = std.StaticStringMap(Tag).initComptime(kvs);
            break :generating_map map;
        };
    };
};

pub const Lexer = struct {
    code: [:0]const u8,
    file_path: []const u8,
    
    pos: usize = 0,

    pub const State = enum {
        start, // -> @"+", @"-", @"*", @"/", @"%", @"=", @"@", @"#", int_dec, int_0, identifier, start, invalid

        invalid, // -> end, invalid

        @"+", // -> "+" "+=" "+%",
        @"-", // -> "-" "-=" "-%",
        @"*", // -> "*" "*=" "*%",
        @"/", // -> "=" "/=", @"//..." @"/[..."
        @"%", // -> "%" "%=",

        @"|", // -> "|" "|="
        @"&", // -> "&" "&="
        @"^", // -> "^" "^="

        @"||", // -> "||" "||="
        @"&&", // -> "&&" "&&="
        @"^^", // -> "^^" "^^="

        @"<", // -> "<" "<=", @"<<"
        @">", // -> ">" ">=", @">>"

        @"<<", // -> "<<" "<<="
        @">>", // -> ">>" ">>="

        @"=", // -> "=" "=="
        @"!", // -> "!" "!="

        @"@", // -> str builtin str_identifier invalid
        @"#", // -> macro invalid

        @".", // -> "." ".*" ".?" ".!"

        identifier, // -> identifier, end

        @"//...", // -> @"//...", start

        int_dec, // -> int_dec, end
        int_0, // -> int_bin, int_hex, invalid, end
        int_bin_start, // -> int_bin, invalid
        int_bin, // -> int_bin, end
        int_hex_start, // -> int_hex, invalid
        int_hex, // -> int_hex, end

        @"str", // -> str @"str /" invalid end
        @"char", // -> char @"char /" invalid end
        @"str \\", // -> str invalid end
        @"char \\", // -> char invalid end
    };

    pub fn next(self: *Lexer) Token {
        _ = std.zig.Tokenizer;

        var result: Token = .{
            .tag = .invalid,
            .loc = .{
                .start = self.pos,
                .end = undefined,
            },
        };

        state: switch (State.start) {
            .start => switch (self.code[self.pos]) {
                0 => {
                    if (self.pos == self.code.len) {
                        self.pos += 1;
                        result.tag = .eof;
                    } else {
                        continue :state .invalid;
                    }
                },

                ' ', '\t', '\n', '\r' => {
                    self.pos += 1;
                    result.loc.start = self.pos;
                    continue :state .start;
                },

                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },

                '0' => {
                    continue :state .int_0;
                },
                '1'...'9' => {
                    continue :state .int_dec;
                },

                '=' => continue :state .@"=",
                '!' => continue :state .@"!",

                '+' => continue :state .@"+",
                '-' => continue :state .@"-",
                '*' => continue :state .@"*",
                '/' => continue :state .@"/",
                '%' => continue :state .@"%",

                '|' => continue :state .@"|",
                '&' => continue :state .@"&",
                '^' => continue :state .@"^",

                '~' => {
                    self.pos += 1;
                    result.tag = .@"op ~";
                },

                '<' => continue :state .@"<",
                '>' => continue :state .@">",

                '.' => continue :state .@".",
                ',' => {
                    self.pos += 1;
                    result.tag = .@"punct ,";
                },
                ':' => {
                    self.pos += 1;
                    result.tag = .@"punct :";
                },
                ';' => {
                    self.pos += 1;
                    result.tag = .@"punct ;";
                },

                '(' => {
                    self.pos += 1;
                    result.tag = .@"delim (";
                },
                ')' => {
                    self.pos += 1;
                    result.tag = .@"delim )";
                },

                '[' => {
                    self.pos += 1;
                    result.tag = .@"delim [";
                },
                ']' => {
                    self.pos += 1;
                    result.tag = .@"delim ]";
                },

                '{' => {
                    self.pos += 1;
                    result.tag = .@"delim {";
                },
                '}' => {
                    self.pos += 1;
                    result.tag = .@"delim }";
                },

                '@' => continue :state .@"@",
                '#' => continue :state .@"#",

                '\"' => {
                    result.tag = .str;
                    continue :state .str;
                },
                '\'' => {
                    result.tag = .char;
                    continue :state .char;
                },

                else => continue :state .invalid,
            },

            .invalid => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '\n', 0 => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },

            .@"+" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op +=";
                    },
                    else => result.tag = .@"op +",
                }
            }, // -> "+" "+=" "+%",
            .@"-" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op -=";
                    },
                    else => result.tag = .@"op -",
                }
            }, // -> "-" "-=" "-%",
            .@"*" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op *=";
                    },
                    else => result.tag = .@"op *",
                }
            }, // -> "*" "*=" "*%",
            .@"/" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op /=";
                    },
                    '/' => continue :state .@"//...",
                    else => result.tag = .@"op /",
                }
            }, // -> "=" "/=", @"//..." @"/[..."
            .@"%" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op %=";
                    },
                    else => result.tag = .@"op %",
                }
            }, // -> "%" "%=",

            .@"|" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op |=";
                    },
                    '|' => continue :state .@"||",
                    else => result.tag = .@"op |",
                }
            }, // -> "|" "|="
            .@"&" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op &=";
                    },
                    '&' => continue :state .@"&&",
                    else => result.tag = .@"op &",
                }
            }, // -> "&" "&="
            .@"^" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op ^=";
                    },
                    '^' => continue :state .@"^^",
                    else => result.tag = .@"op ^",
                }
            }, // -> "^" "^="

            .@"||" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op ||=";
                    },
                    else => result.tag = .@"op ||",
                }
            }, // -> "||" "||="
            .@"&&" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op &&=";
                    },
                    else => result.tag = .@"op &&",
                }
            }, // -> "&&" "&&="
            .@"^^" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op ^^=";
                    },
                    else => result.tag = .@"op ^^",
                }
            }, // -> "^^" "^^="

            .@"<" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op <=";
                    },
                    '<' => continue :state .@"<<",
                    else => result.tag = .@"op <",
                }
            }, // -> "<" "<=", @"<<"
            .@">" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op >=";
                    },
                    '>' => continue :state .@">>",
                    else => result.tag = .@"op >",
                }
            }, // -> ">" ">=", @">>"

            .@"<<" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op <<=";
                    },
                    else => result.tag = .@"op <<",
                }
            }, // -> "<<" "<<="
            .@">>" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op >>=";
                    },
                    else => result.tag = .@"op >>",
                }
            }, // -> ">>" ">>="

            .@"=" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op ==";
                    },
                    else => result.tag = .@"op =",
                }
            }, // -> "=" "=="
            .@"!" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '=' => {
                        self.pos += 1;
                        result.tag = .@"op !=";
                    },
                    else => result.tag = .@"op !",
                }
            }, // -> "!" "!="

            .@"@" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '\"' => {
                        result.tag = .identifier;
                        continue :state .str;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        continue :state .identifier;
                    },
                    else => continue :state .invalid,
                }
            }, // -> str builtin str_identifier invalid
            .@"#" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    'a'...'z', 'A'...'Z', '_' => continue :state .identifier,
                    else => continue :state .invalid,
                }
            }, // -> identifier invalid

            .@"." => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '*' => {
                        self.pos += 1;
                        result.tag = .@"op .*";
                    },
                    '?' => {
                        self.pos += 1;
                        result.tag = .@"op .?";
                    },
                    '!' => {
                        self.pos += 1;
                        result.tag = .@"op .!";
                    },
                    else => result.tag = .@"punct .",
                }
            }, // -> "." ".*" ".?" ".!"

            .identifier => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    else => {
                        if (Token.Tag.stringToKeywordTagMap.get(self.code[result.loc.start..self.pos])) |kw| result.tag = kw;
                        if (Token.Tag.stringToBuiltinTagMap.get(self.code[result.loc.start..self.pos])) |bi| result.tag = bi;
                        if (Token.Tag.stringToMacroTagMap.get(self.code[result.loc.start..self.pos])) |m| result.tag = m;
                    },
                }
            },

            .@"//..." => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    0x00...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    '\n' => continue :state .start,
                    else => continue :state .@"//...",
                }
            },

            .int_dec => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '0'...'9' => continue :state .int_dec,
                    'a'...'z', 'A'...'Z' => continue :state .invalid,
                    else => result.tag = .int,
                }
            },
            .int_0 => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '0'...'9',   'a', 'c'...'w', 'y', 'z',   'A', 'C'...'W', 'Y', 'Z' => continue :state .invalid,

                    'b' => continue :state .int_bin_start,
                    'x' => continue :state .int_hex_start,
                    'B' => continue :state .invalid,
                    'X' => continue :state .invalid,

                    else => result.tag = .int,
                }
            },
            .int_bin_start => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '0'...'1' => continue :state .int_bin,
                    '2'...'9', 'a'...'z', 'A'...'Z' => continue :state .invalid,
                    else => result.tag = .invalid,
                }
            },
            .int_bin => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '0'...'1' => continue :state .int_bin,
                    '2'...'9', 'a'...'z', 'A'...'Z' => continue :state .invalid,
                    else => result.tag = .int,
                }
            },
            .int_hex_start => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => continue :state .int_hex,
                    'g'...'z', 'G'...'Z' => continue :state .invalid,
                    else => continue :state .invalid,
                }
            },
            .int_hex => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => continue :state .int_hex,
                    'g'...'z', 'G'...'Z' => continue :state .invalid,
                    else => result.tag = .int,
                }
            },

            .@"str" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    0x00...0x1f, 0x7f => continue :state .invalid,
                    '\\' => continue :state .@"char \\",
                    '\"' => self.pos += 1,
                    else => continue :state .str,
                }
            },
            .@"char" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    0x00...0x1f, 0x7f => continue :state .invalid,
                    '\\' => continue :state .@"char \\",
                    '\'' => self.pos += 1,
                    else => continue :state .@"char",
                }
            },

            .@"str \\" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '\'', '\"', 'n', 'r', 't', '0' => {
                        self.pos += 1;
                        continue :state .@"str";
                    },
                    else => continue :state .invalid,
                }
            },
            .@"char \\" => {
                self.pos += 1;
                switch (self.code[self.pos]) {
                    '\'', '\"', 'n', 'r', 't', '0' => {
                        self.pos += 1;
                        continue :state .@"char";
                    },
                    else => continue :state .invalid,
                }
            },
        }

        result.loc.end = self.pos;
        return result;
    }

    pub fn resolveInvalidToken(self: Lexer, token: Token) TokenError {
        _ = self;
        _ = token;
    }

    pub const TokenError = union(enum) {

    };
};

pub const HighlightingSettings = enum {
    none,
    any,
    only_invalid,
};

pub fn lexFile(code: [:0]const u8, file_path: []const u8, gpa: std.mem.Allocator, highlighting_settings: HighlightingSettings) ![]Token {
    var lexer = Lexer{ 
        .code = code,
        .file_path = file_path,
    };
    var result: std.ArrayList(Token) = .empty;
    errdefer result.deinit(gpa);

    while (true) {
        const token = lexer.next();
        try result.append(gpa, token);

        switch (highlighting_settings) {
            .none => {},
            .any => {
                highlightToken(token, code, file_path);
            },
            .only_invalid => {
                if (token.tag == .invalid) highlightToken(token, code, file_path);
            },
        }

        if (token.tag == .invalid) return error.LexingFailed;
        if (token.tag == .eof) break;
    }

    return result.toOwnedSlice(gpa);
}

pub fn highlightToken(token: Token, code: [:0]const u8, file_path: []const u8) void {
    utils.highlightCode(code, file_path, token.loc, "info: {f}", .{ token.tag });
}
