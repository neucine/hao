const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    SyntaxError,
    UnsupportedFeature,
    OutOfMemory,
};

pub const Diagnostic = struct {
    kind: Kind,
    offset: usize,
    message: []const u8,

    pub const Kind = enum {
        syntax,
        unsupported,
    };
};

pub const Result = struct {
    unit: ast.TranslationUnit,
    diagnostic: ?Diagnostic = null,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Result {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
    };
    const unit = try parser.parseTranslationUnit();
    return .{
        .unit = unit,
        .diagnostic = parser.diagnostic,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    diagnostic: ?Diagnostic = null,

    fn parseTranslationUnit(self: *Parser) ParseError!ast.TranslationUnit {
        var decls = std.ArrayList(ast.Declaration).empty;
        defer decls.deinit(self.allocator);

        try self.skipSpaceAndComments();
        while (!self.eof()) {
            if (self.peekChar() == '#') return self.unsupported("preprocessor directives are not supported");
            if (self.peekKeyword("union")) return self.unsupported("union declarations are not supported");

            if (self.peekKeyword("typedef")) {
                const decl = try self.parseTypeDecl();
                try decls.append(self.allocator, .{ .type_decl = decl });
            } else {
                const func = try self.parseFunctionDecl();
                try decls.append(self.allocator, .{ .function = func });
            }
            try self.skipSpaceAndComments();
        }

        return .{ .declarations = try decls.toOwnedSlice(self.allocator) };
    }

    fn parseTypeDecl(self: *Parser) ParseError!ast.TypeDecl {
        try self.expectKeyword("typedef");
        try self.skipSpaceAndComments();
        if (!self.consumeKeyword("struct")) return self.syntax("expected 'struct' after typedef");
        try self.skipSpaceAndComments();

        if (self.consumeChar('{')) {
            var fields = std.ArrayList(ast.StructField).empty;
            errdefer {
                self.freeStructFieldList(fields.items);
                fields.deinit(self.allocator);
            }
            try self.skipSpaceAndComments();
            while (!self.consumeChar('}')) {
                if (self.eof()) return self.syntax("unterminated struct declaration");
                if (self.peekKeyword("union")) return self.unsupported("union fields are not supported");
                const field = try self.parseStructField();
                try fields.append(self.allocator, field);
                try self.skipSpaceAndComments();
            }
            try self.skipSpaceAndComments();
            const name = try self.parseIdentifierAlloc();
            errdefer self.allocator.free(name);
            try self.skipSpaceAndComments();
            try self.expectChar(';');
            return .{ .pod_struct = .{
                .name = name,
                .fields = try fields.toOwnedSlice(self.allocator),
            } };
        }

        const original_name = try self.parseIdentifierAlloc();
        errdefer self.allocator.free(original_name);
        try self.skipSpaceAndComments();
        const alias_name = try self.parseIdentifierAlloc();
        errdefer self.allocator.free(alias_name);
        try self.skipSpaceAndComments();
        try self.expectChar(';');
        if (!std.mem.eql(u8, original_name, alias_name)) {
            return self.unsupported("opaque typedef aliases must reuse the same struct name");
        }
        self.allocator.free(original_name);
        return .{ .opaque_handle = .{ .name = alias_name } };
    }

    fn parseStructField(self: *Parser) ParseError!ast.StructField {
        const ty = try self.parseTypeExpr();
        errdefer self.freeTypeExpr(ty);
        try self.skipSpaceAndComments();
        const name = try self.parseIdentifierAlloc();
        errdefer self.allocator.free(name);
        try self.skipSpaceAndComments();
        if (self.consumeChar(':')) return self.unsupported("bitfields are not supported");
        try self.expectChar(';');
        return .{
            .name = name,
            .ty = ty,
        };
    }

    fn parseFunctionDecl(self: *Parser) ParseError!ast.FunctionDecl {
        const return_type = try self.parseTypeExpr();
        errdefer self.freeTypeExpr(return_type);
        try self.skipSpaceAndComments();
        if (self.peekChar() == '*') return self.unsupported("function pointer declarations are not supported");
        const name = try self.parseIdentifierAlloc();
        errdefer self.allocator.free(name);
        try self.skipSpaceAndComments();
        try self.expectChar('(');

        var params = std.ArrayList(ast.ParamDecl).empty;
        errdefer {
            self.freeParamList(params.items);
            params.deinit(self.allocator);
        }

        try self.skipSpaceAndComments();
        if (!self.consumeChar(')')) {
            while (true) {
                if (self.peekDotDotDot()) return self.unsupported("variadic functions are not supported");
                if (self.peekChar() == '(') return self.unsupported("function pointer parameters are not supported");
                const param = try self.parseParamDecl();
                try params.append(self.allocator, param);
                try self.skipSpaceAndComments();
                if (self.consumeChar(')')) break;
                try self.expectChar(',');
                try self.skipSpaceAndComments();
            }
        }
        try self.skipSpaceAndComments();
        try self.expectChar(';');

        const params_slice = try params.toOwnedSlice(self.allocator);
        if (params_slice.len == 1 and
            params_slice[0].name.len == 0 and
            params_slice[0].ty.pointer_depth == 0 and
            params_slice[0].ty.base == .primitive and
            params_slice[0].ty.base.primitive == .void)
        {
            self.allocator.free(params_slice[0].name);
            self.allocator.free(params_slice);
            return .{
                .name = name,
                .return_type = return_type,
                .params = &.{},
            };
        }

        return .{
            .name = name,
            .return_type = return_type,
            .params = params_slice,
        };
    }

    fn parseParamDecl(self: *Parser) ParseError!ast.ParamDecl {
        const ty = try self.parseTypeExpr();
        errdefer self.freeTypeExpr(ty);
        try self.skipSpaceAndComments();
        if (self.peekChar() == '(') return self.unsupported("function pointer parameters are not supported");

        if (ty.base == .primitive and ty.base.primitive == .void and ty.pointer_depth == 0) {
            return .{
                .name = try self.allocator.dupe(u8, ""),
                .ty = ty,
            };
        }

        const name = try self.parseIdentifierAlloc();
        return .{
            .name = name,
            .ty = ty,
        };
    }

    fn parseTypeExpr(self: *Parser) ParseError!ast.TypeExpr {
        try self.skipSpaceAndComments();
        if (self.peekKeyword("union")) return self.unsupported("union declarations are not supported");
        if (self.peekKeyword("struct")) return self.unsupported("standalone struct type references are not supported");

        var is_const = false;
        if (self.consumeKeyword("const")) {
            is_const = true;
            try self.skipSpaceAndComments();
        }

        const base = if (try self.parsePrimitiveType()) |primitive|
            ast.BaseType{ .primitive = primitive }
        else blk: {
            const name = try self.parseIdentifierAlloc();
            break :blk ast.BaseType{ .named = name };
        };

        try self.skipSpaceAndComments();
        var pointer_depth: u8 = 0;
        while (self.consumeChar('*')) {
            pointer_depth += 1;
            try self.skipSpaceAndComments();
            if (self.consumeKeyword("const")) {
                try self.skipSpaceAndComments();
            }
        }

        if (self.consumeChar('[')) return self.unsupported("array declarators are not supported");

        return .{
            .base = base,
            .pointer_depth = pointer_depth,
            .is_const = is_const,
        };
    }

    fn parsePrimitiveType(self: *Parser) ParseError!?ast.PrimitiveType {
        const primitives = [_]struct { []const u8, ast.PrimitiveType }{
            .{ "void", .void },
            .{ "bool", .bool },
            .{ "char", .char },
            .{ "int8_t", .int8_t },
            .{ "int16_t", .int16_t },
            .{ "int32_t", .int32_t },
            .{ "int64_t", .int64_t },
            .{ "uint8_t", .uint8_t },
            .{ "uint16_t", .uint16_t },
            .{ "uint32_t", .uint32_t },
            .{ "uint64_t", .uint64_t },
            .{ "float", .float },
            .{ "double", .double },
            .{ "size_t", .size_t },
        };
        inline for (primitives) |entry| {
            if (self.consumeKeyword(entry.@"0")) return entry.@"1";
        }
        if (self.peekKeyword("short") or self.peekKeyword("int") or self.peekKeyword("long") or self.peekKeyword("unsigned") or self.peekKeyword("signed")) {
            return self.unsupported("platform-width integer type names are not supported");
        }
        return null;
    }

    fn parseIdentifierAlloc(self: *Parser) ParseError![]const u8 {
        try self.skipSpaceAndComments();
        const start = self.pos;
        if (self.eof()) return self.syntax("expected identifier");
        const first = self.source[self.pos];
        if (!(std.ascii.isAlphabetic(first) or first == '_')) return self.syntax("expected identifier");
        self.pos += 1;
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
            self.pos += 1;
        }
        return self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    fn skipSpaceAndComments(self: *Parser) ParseError!void {
        while (!self.eof()) {
            const ch = self.source[self.pos];
            if (std.ascii.isWhitespace(ch)) {
                self.pos += 1;
                continue;
            }
            if (ch == '/' and self.pos + 1 < self.source.len) {
                const next = self.source[self.pos + 1];
                if (next == '/') {
                    self.pos += 2;
                    while (!self.eof() and self.source[self.pos] != '\n') self.pos += 1;
                    continue;
                }
                if (next == '*') {
                    self.pos += 2;
                    while (self.pos + 1 < self.source.len and !(self.source[self.pos] == '*' and self.source[self.pos + 1] == '/')) {
                        self.pos += 1;
                    }
                    if (self.pos + 1 >= self.source.len) return self.syntax("unterminated block comment");
                    self.pos += 2;
                    continue;
                }
            }
            break;
        }
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) ParseError!void {
        if (!self.consumeKeyword(keyword)) return self.syntax("expected keyword");
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) bool {
        if (!self.peekKeyword(keyword)) return false;
        self.pos += keyword.len;
        return true;
    }

    fn peekKeyword(self: *Parser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;
        const before_ok = self.pos == 0 or !isIdentifierChar(self.source[self.pos - 1]);
        const after_pos = self.pos + keyword.len;
        const after_ok = after_pos >= self.source.len or !isIdentifierChar(self.source[after_pos]);
        return before_ok and after_ok;
    }

    fn expectChar(self: *Parser, ch: u8) ParseError!void {
        try self.skipSpaceAndComments();
        if (!self.consumeChar(ch)) return self.syntax("expected punctuation");
    }

    fn consumeChar(self: *Parser, ch: u8) bool {
        if (self.eof() or self.source[self.pos] != ch) return false;
        self.pos += 1;
        return true;
    }

    fn peekChar(self: *Parser) u8 {
        return if (self.eof()) 0 else self.source[self.pos];
    }

    fn peekDotDotDot(self: *Parser) bool {
        return self.pos + 3 <= self.source.len and std.mem.eql(u8, self.source[self.pos .. self.pos + 3], "...");
    }

    fn eof(self: *Parser) bool {
        return self.pos >= self.source.len;
    }

    fn syntax(self: *Parser, message: []const u8) ParseError {
        self.diagnostic = .{
            .kind = .syntax,
            .offset = self.pos,
            .message = message,
        };
        return error.SyntaxError;
    }

    fn unsupported(self: *Parser, message: []const u8) ParseError {
        self.diagnostic = .{
            .kind = .unsupported,
            .offset = self.pos,
            .message = message,
        };
        return error.UnsupportedFeature;
    }

    fn freeParamList(self: *Parser, items: []const ast.ParamDecl) void {
        for (items) |param| {
            self.freeTypeExpr(param.ty);
            self.allocator.free(param.name);
        }
    }

    fn freeStructFieldList(self: *Parser, items: []const ast.StructField) void {
        for (items) |field| {
            self.freeTypeExpr(field.ty);
            self.allocator.free(field.name);
        }
    }

    fn freeTypeExpr(self: *Parser, ty: ast.TypeExpr) void {
        switch (ty.base) {
            .primitive => {},
            .named => |name| self.allocator.free(name),
        }
    }
};

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "parser parses libm style function prototypes" {
    const allocator = std.testing.allocator;
    const source =
        \\double sqrt(double x);
        \\double pow(double x, double y);
    ;
    const parsed = try parse(allocator, source);
    defer parsed.unit.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.unit.declarations.len);
    try std.testing.expectEqual(@as(?Diagnostic, null), parsed.diagnostic);

    const sqrt_decl = parsed.unit.declarations[0].function;
    try std.testing.expectEqualStrings("sqrt", sqrt_decl.name);
    try std.testing.expectEqual(@as(u8, 0), sqrt_decl.return_type.pointer_depth);
    try std.testing.expectEqual(ast.PrimitiveType.double, sqrt_decl.return_type.base.primitive);
    try std.testing.expectEqual(@as(usize, 1), sqrt_decl.params.len);
    try std.testing.expectEqualStrings("x", sqrt_decl.params[0].name);
}

test "parser parses opaque and pod struct typedefs with functions" {
    const allocator = std.testing.allocator;
    const source =
        \\typedef struct sqlite3 sqlite3;
        \\typedef struct {
        \\  double x;
        \\  double y;
        \\} Point;
        \\int32_t sqlite3_open(const char* filename, sqlite3** out_db);
    ;
    const parsed = try parse(allocator, source);
    defer parsed.unit.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.unit.declarations.len);
    try std.testing.expectEqualStrings("sqlite3", parsed.unit.declarations[0].type_decl.opaque_handle.name);
    const point = parsed.unit.declarations[1].type_decl.pod_struct;
    try std.testing.expectEqualStrings("Point", point.name);
    try std.testing.expectEqual(@as(usize, 2), point.fields.len);
    const open_fn = parsed.unit.declarations[2].function;
    try std.testing.expectEqualStrings("sqlite3_open", open_fn.name);
    try std.testing.expectEqual(@as(usize, 2), open_fn.params.len);
    try std.testing.expectEqual(@as(u8, 1), open_fn.params[0].ty.pointer_depth);
    try std.testing.expectEqual(@as(u8, 2), open_fn.params[1].ty.pointer_depth);
}

test "parser accepts void parameter list as no params" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "void init(void);");
    defer parsed.unit.deinit(allocator);

    const init_fn = parsed.unit.declarations[0].function;
    try std.testing.expectEqual(@as(usize, 0), init_fn.params.len);
}

test "parser rejects variadic functions as unsupported" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFeature, parse(allocator, "int printf(const char* fmt, ...);"));
}

test "parser rejects preprocessor directives as unsupported" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFeature, parse(allocator, "#include <stdio.h>"));
}

test "parser rejects function pointer parameters as unsupported" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFeature, parse(allocator, "void set_cb(void (*cb)(int));"));
}

test "parser rejects platform width integer names as unsupported" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFeature, parse(allocator, "int sum(int a, int b);"));
}

test "parser rejects syntax errors distinctly" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SyntaxError, parse(allocator, "double sqrt(double x)"));
}
