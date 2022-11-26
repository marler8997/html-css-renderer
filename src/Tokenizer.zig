/// An html5 tokenizer.
/// Implements the state machine described here:
///     https://html.spec.whatwg.org/multipage/parsing.html#tokenization
///
const Tokenizer = @This();

const std = @import("std");

start: [*]const u8,
limit: [*]const u8,
ptr: [*]const u8,
state: State = .data,
deferred_token: ?Token = null,
current_input_character: struct {
    len: u3,
    val: u21,
} = undefined,

const DOCTYPE = "DOCTYPE";
const form_feed = 0xc;

pub fn init(slice: []const u8) Tokenizer {
    return .{
        .start = slice.ptr,
        .limit = slice.ptr + slice.len,
        .ptr = slice.ptr,
    };
}

const Span = struct {
    start: usize,
    limit: usize,
    pub fn slice(self: Span, text: []const u8) []const u8 {
        return text[self.start..self.limit];
    }
};

pub const Token = union(enum) {
    doctype: Doctype,
    // TODO: maybe combine start/end tag?
    start_tag: StartTag,
    start_tag_end: bool,
    end_tag: struct {
        name: usize,
        self_closing: bool,
    },
    attr: struct {
        // NOTE: process the name_raw by replacing
        //     - upper-case ascii alpha with lower case (add 0x20)
        //     - 0 with U+FFFD
        name_raw: Span,
        // NOTE: process value...somehow...
        value_raw: ?Span,
    },
    comment: Span,
    // TODO: return multiple utf8-encoded chars in a single string
    //       there's no reason for the tokenizer not to return all consecutive
    //       char tokens as a single string
    // chars: Span,
    char: u21,
    parse_error: enum {
        unexpected_null_character,
        invalid_first_character_of_tag_name,
        incorrectly_opened_comment,
        missing_end_tag_name,
        eof_before_tag_name,
        eof_in_doctype,
        eof_in_tag,
        eof_in_comment,
        missing_whitespace_before_doctype_name,
        unexpected_character_in_attribute_name,
        missing_attribute_value,
        unexpected_solidus_in_tag,
        abrupt_closing_of_empty_comment,
    },

    pub const Doctype = struct {
        // NOTE: process name_raw by replacing
        //     - upper-case ascii alpha with lower case (add 0x20)
        //     - 0 with U+FFFD
        name_raw: ?Span,
        public_id: usize,
        system_id: usize,
        force_quirks: bool,
    };
    pub const StartTag = struct {
        // NOTE: process name_raw by replacing
        //     - upper-case ascii alpha with lower case (add 0x20)
        //     - 0 with U+FFFD
        name_raw: Span,
    };
};

const State = union(enum) {
    data: void,
    tag_open: void,
    end_tag_open: void,
    character_reference: void,
    markup_declaration_open: void,
    doctype: void,
    before_doctype_name: void,
    doctype_name: struct {
        name_offset: usize,
    },
    after_doctype_name: struct {
        name_offset: usize,
        name_limit: usize,
    },
    comment_start: usize,
    comment_start_dash: void,
    comment: usize,
    comment_end_dash: Span,
    comment_end: Span,
    tag_name: struct {
        is_end: bool,
        start: usize,
    },
    self_closing_start_tag: void,
    before_attribute_name: void,
    attribute_name: usize,
    after_attribute_name: void,
    before_attribute_value: Span,
    attribute_value: struct {
        quote: enum { double, single },
        name_raw: Span,
        start: usize,
    },
    attribute_value_unquoted: struct {
        name_raw: Span,
    },
    after_attribute_value: struct {
    },
    bogus_comment: void,
    eof: void,
};

fn consume(self: *Tokenizer) !void {
    if (self.ptr == self.limit) {
        self.current_input_character = .{ .len = 0, .val = undefined };
        return;
    }
    const len = try std.unicode.utf8CodepointSequenceLength(self.ptr[0]);
    if (@ptrToInt(self.ptr) + len > @ptrToInt(self.limit))
        return error.Utf8TruncatedInput;
    self.current_input_character = .{ .len = len, .val = try std.unicode.utf8Decode(self.ptr[0 .. len]) };
    self.ptr += len;
}

pub fn next(self: *Tokenizer) !?Token {
    //std.log.info("next: offset={}", .{@ptrToInt(self.ptr) - @ptrToInt(self.start)});
    if (self.deferred_token) |t| {
        const token_copy = t;
        self.deferred_token = null;
        return token_copy;
    }
    const result = (try self.next2()) orelse return null;
    if (result.deferred) |d| {
        self.deferred_token = d;
    }
    return result.token;
}

fn next2(self: *Tokenizer) !?struct {
    token: Token,
    deferred: ?Token = null,
} {
    // TODO: not sure what this is for
    //var return_state: ?State = null;

    while (true) {
        switch (self.state) {
            .data => {
                try self.consume();
                if (self.current_input_character.len == 0) return null;
                switch (self.current_input_character.val) {
                    '&' => {
                        std.log.warn("TODO: implement character reference state", .{});
                        //return_state = .data;
                        //self.state = .character_reference;
                    },
                    '<' => self.state = .tag_open,
                    0 => {
                        return .{
                            .token = .{ .parse_error = .unexpected_null_character },
                            .deferred = .{ .char = 0 },
                        };
                    },
                    else => |c| return .{ .token = .{ .char = c } },
                }
            },
            .tag_open => {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_before_tag_name },
                        .deferred = .{ .char = '<' },
                    };
                }
                switch (self.current_input_character.val) {
                    '!' => self.state = .markup_declaration_open,
                    '/' => self.state = .end_tag_open,
                    '?' => return error.NotImpl,
                    else => |c| if (isAsciiAlpha(c)) {
                        self.state = .{
                            .tag_name = .{
                                .is_end = false,
                                .start = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                            },
                        };
                    } else {
                        self.state = .data;
                        self.ptr -= self.current_input_character.len;
                        return .{
                            .token = .{ .parse_error = .invalid_first_character_of_tag_name },
                            .deferred = .{ .char = '<' },
                        };
                    },
                }
            },
            .end_tag_open => {
                const save_previous_char_len = self.current_input_character.len;
                try self.consume();
                if (self.current_input_character.len == 0) {
                    // NOTE: this is implemented differently from the spec so we only need to
                    //       support 1 deferred token, but, should result in the same tokens.
                    self.state = .data;
                    self.ptr -= save_previous_char_len;
                    return .{
                        .token = .{ .parse_error = .eof_before_tag_name },
                        .deferred = .{ .char = '<' },
                    };
                }
                switch (self.current_input_character.val) {
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .parse_error = .missing_end_tag_name } };
                    },
                    else => |c| if (isAsciiAlpha(c)) {
                        self.state = .{
                            .tag_name = .{
                                .is_end = true,
                                .start = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                            },
                        };
                    } else {
                        self.state = .bogus_comment;
                        return .{ .token = .{ .parse_error = .invalid_first_character_of_tag_name } };
                    },
                }
            },
            .tag_name => |tag_state| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{ .token = .{ .parse_error = .eof_in_tag } };
                }
                switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => {
                        self.state = .before_attribute_name;
                        return .{ .token = .{ .start_tag = .{
                            .name_raw = .{
                                .start = tag_state.start,
                                .limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                            },
                        }}};
                    },
                    '/' => self.state = .self_closing_start_tag,
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .start_tag = .{
                            .name_raw = .{
                                .start = tag_state.start,
                                .limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                            },
                        }}};
                        //return error.TodoReturnCurrentTagToken;
                    },
                    0 => return .{ .token = .{ .parse_error = .unexpected_null_character } },
                    else => {},
                }
            },
            .self_closing_start_tag => {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{ .token = .{ .parse_error = .eof_in_tag } };
                } else switch (self.current_input_character.val) {
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .start_tag_end = true } };
                    },
                    else => {
                        self.state = .before_attribute_name;
                        self.ptr -= self.current_input_character.len;
                        return .{ .token = .{ .parse_error = .unexpected_solidus_in_tag } };
                    },
                }
            },
            .before_attribute_name => {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .after_attribute_name;
                } else switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => {},
                    '/', '>' => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .after_attribute_name;
                    },
                    '=' => {
                        // unexpected_equals_sign_before_attribute_name
                        return error.NotImpl;
                    },
                    else => self.state = .{
                        .attribute_name = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                    },
                }
            },
            .attribute_name => |start| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .after_attribute_name;
                } else switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ', '/', '>' => {
                        self.ptr -= self.current_input_character.len;
                        // TODO: pass something to after_attribute_name like start/limit?
                        //    .start = start,
                        //    .limit = @ptrToInt(self.ptr) - @ptrToInt(self.start),
                        self.state = .after_attribute_name;
                    },
                    '=' => self.state = .{ .before_attribute_value = .{
                        .start = start,
                        .limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                    }},
                    '"', '\'', '<' => return .{ .token = .{ .parse_error = .unexpected_character_in_attribute_name } },
                    else => {},
                }
            },
            .after_attribute_name => return error.NotImpl,
            .before_attribute_value => |name_span| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .{ .attribute_value_unquoted = .{ .name_raw = name_span } };
                } else switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => {},
                    '"' => self.state = .{ .attribute_value = .{
                        .name_raw = name_span,
                        .quote = .double,
                        .start = @ptrToInt(self.ptr) - @ptrToInt(self.start),
                    } },
                    '\'' => self.state = .{ .attribute_value = .{
                        .name_raw = name_span,
                        .quote = .single,
                        .start = @ptrToInt(self.ptr) - @ptrToInt(self.start),
                    } },
                    '>' => {
                        self.state = .data;
                        return .{
                            .token = .{ .parse_error = .missing_attribute_value },
                            // TODO: return an attribute name without a value?
                            //.deferred = .{ .attribute = .{ .name = ..., .value = null } },
                        };
                    },
                    else => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .{ .attribute_value_unquoted = .{
                            .name_raw = name_span,
                        }};
                    },
                }
            },
            .attribute_value => |attr_state| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    // NOTE: spec doesn't say to emit the current tag?
                    return .{ .token = .{ .parse_error = .eof_in_tag } };
                } else switch (self.current_input_character.val) {
                    '"' => switch (attr_state.quote) {
                        .double => {
                            self.state = .after_attribute_value;
                            return .{ .token = .{ .attr = .{
                                .name_raw = attr_state.name_raw,
                                .value_raw = .{
                                    .start = attr_state.start,
                                    .limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                                },
                            }}};
                        },
                        .single => return error.NotImpl,
                    },
                    '\'' => switch (attr_state.quote) {
                        .double => return error.NotImpl,
                        .single => return error.NotImpl,
                    },
                    // TODO: the spec says the tokenizer should handle "character references" here, but,
                    //       that would require allocation, so, we should probably handle that elsewhere
                    //'&' => return error.NotImpl,
                    0 => return .{ .token = .{ .parse_error = .unexpected_null_character } },
                    else => {},
                }
            },
            .attribute_value_unquoted => {
                return error.NotImpl;
            },
            .after_attribute_value => {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    // NOTE: spec doesn't say to emit the current tag?
                    return .{ .token = .{ .parse_error = .eof_in_tag } };
                } else switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => self.state = .before_attribute_name,
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .start_tag_end = false }};
                    },
                    '/' => self.state = .self_closing_start_tag,
                    else => |c| std.debug.panic("todo c={}", .{c}),
                }
            },
            .markup_declaration_open => {
                if (self.nextCharsAre("--")) {
                    self.ptr += 2;
                    self.state = .{ .comment_start = @ptrToInt(self.ptr) - @ptrToInt(self.start) };
                } else if (self.nextCharsAre(DOCTYPE)) {
                    self.ptr += DOCTYPE.len;
                    self.state = .doctype;
                } else if (self.nextCharsAre("[CDATA[")) {
                    return error.NotImpl;
                } else {
                    self.state = .bogus_comment;
                    return .{ .token = .{ .parse_error = .incorrectly_opened_comment } };
                }
            },
            .character_reference => {
                return error.NotImpl;
            },
            .doctype => {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_in_doctype },
                        .deferred = .{ .doctype = .{
                            .force_quirks = true,
                            .name_raw = null, .public_id = 0, .system_id = 0,
                        }},
                    };
                }
                switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => self.state = .before_doctype_name,
                    '>' => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .before_doctype_name;
                    },
                    else => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .before_doctype_name;
                        return .{ .token = .{ .parse_error = .missing_whitespace_before_doctype_name } };
                    },
                }
            },
            .before_doctype_name => {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_in_doctype },
                        .deferred = .{ .doctype = .{
                            .force_quirks = true,
                            .name_raw = null, .public_id = 0, .system_id = 0,
                        }}
                    };
                }
                switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => {},
                    0 => {
                        self.state = .{ .doctype_name = .{
                            .name_offset = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                        }};
                        return .{ .token = .{ .parse_error = .unexpected_null_character } };
                    },
                    '>' => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .data;
                        return .{ .token = .{ .doctype = .{
                            .force_quirks = true,
                            .name_raw = null, .public_id = 0, .system_id = 0,
                        }}};
                    },
                    else => {
                        // NOTE: same thing for isAsciiAlphaUpper since we post-process the name
                        self.state = .{ .doctype_name = .{
                            .name_offset = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                        }};
                    }
                }
            },
            .doctype_name => |doctype_state| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_in_doctype },
                        .deferred = .{ .doctype = .{
                            .force_quirks = true,
                            .name_raw = null, .public_id = 0, .system_id = 0,
                        }},
                    };
                }
                switch (self.current_input_character.val) {
                    '\t', '\n', form_feed, ' ' => {
                        self.state = .{ .after_doctype_name = .{
                            .name_offset = doctype_state.name_offset,
                            .name_limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                        }};
                    },
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .doctype = .{
                            .name_raw = .{
                                .start = doctype_state.name_offset,
                                .limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                            },
                            .public_id = 0,
                            .system_id = 0,
                            .force_quirks = false,
                        }}};
                    },
                    0 => return .{ .token = .{ .parse_error = .unexpected_null_character } },
                    else => {},
                }
            },
            .after_doctype_name => {
                return error.NotImpl;
            },
            .comment_start => |comment_start| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.ptr -= self.current_input_character.len;
                    self.state = .{ .comment = comment_start };
                } else switch (self.current_input_character.val) {
                    '-' => self.state = .comment_start_dash,
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .parse_error = .abrupt_closing_of_empty_comment } };
                    },
                    else => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .{ .comment = comment_start };
                    },
                }
            },
            .comment_start_dash => {
                return error.NotImpl;
            },
            .comment => |comment_start| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_in_comment },
                        .deferred = .{ .comment = .{
                            .start = comment_start,
                            .limit = @ptrToInt(self.ptr) - @ptrToInt(self.start),
                        } },
                    };
                }
                switch (self.current_input_character.val) {
                    '<' => return error.NotImpl,
                    '-' => self.state = .{ .comment_end_dash = .{
                        .start = comment_start,
                        .limit = @ptrToInt(self.ptr) - self.current_input_character.len - @ptrToInt(self.start),
                    }},
                    0 => return error.NotImpl,
                    else => {},
                }
            },
            .comment_end_dash => |comment_span| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_in_comment },
                        .deferred = .{ .comment = comment_span },
                    };
                }
                switch (self.current_input_character.val) {
                    '-' => self.state = .{ .comment_end = comment_span },
                    else => {
                        self.ptr -= self.current_input_character.len;
                        self.state = .{ .comment = comment_span.start };
                    },
                }
            },
            .comment_end => |comment_span| {
                try self.consume();
                if (self.current_input_character.len == 0) {
                    self.state = .eof;
                    return .{
                        .token = .{ .parse_error = .eof_in_comment },
                        .deferred = .{ .comment = comment_span },
                    };
                }
                switch (self.current_input_character.val) {
                    '>' => {
                        self.state = .data;
                        return .{ .token = .{ .comment = comment_span } };
                    },
                    '!' => return error.NotImpl,
                    '-' => return error.NotImpl,
                    else => return error.NotImpl,
                }
            },
            .bogus_comment => {
                return error.NotImpl;
            },
            .eof => return null,
        }
    }
}

fn nextCharsAre(self: Tokenizer, s: []const u8) bool {
    return (@ptrToInt(self.ptr) + s.len <= @ptrToInt(self.limit)) and
        std.mem.eql(u8, self.ptr[0 .. s.len], s);
}

fn isAsciiAlphaLower(c: u21) bool {
    return (c >= 'a' and c <= 'z');
}
fn isAsciiAlphaUpper(c: u21) bool {
    return (c >= 'A' and c <= 'Z');
}
fn isAsciiAlpha(c: u21) bool {
    return isAsciiAlphaLower(c) or isAsciiAlphaUpper(c);
}
