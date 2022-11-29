// see https://dom.spec.whatwg.org/#nodes
const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");

pub const EventTarget = struct {

    // ctor
    // addEventListener
    // removeEventListener
    // dispatchEvent
    
};

pub const EventListener = struct {
    // handleEvent
};

pub const EventListenerOptions = struct {
    capture: bool = false,
};

pub const AddEventListenerOptions = struct {
    base: EventListenerOptions,
    passive: bool,
    once: bool = false,
    //signal: AbortSignal,
};

pub const DOMString = struct {
};
pub const USVString = struct {
};

pub const GetRootNodeOptions = struct {
    composed: bool = false,
};

pub const Node = struct {
    pub const ELEMENT_NODE = 1;
    pub const ATTRIBUTE_NODE = 2;
    pub const TEXT_NODE = 3;
    pub const CDATA_SECTION_NODE = 4;
    pub const ENTITY_REFERENCE_NODE = 5; // legacy
    pub const ENTITY_NODE = 6; // legacy
    pub const PROCESSING_INSTRUCTION_NODE = 7;
    pub const COMMENT_NODE = 8;
    pub const DOCUMENT_NODE = 9;
    pub const DOCUMENT_TYPE_NODE = 10;
    pub const DOCUMENT_FRAGMENT_NODE = 11;
    pub const NOTATION_NODE = 12; // legacy

//    eventTarget: EventTarget,
//    nodeType: u16,
//    nodeName: DOMString,
//    baseURI: USVString,
//    isConnected: bool,
//    ownerDocument: ?Document,
//    parentNode: ?Node,
//    parentElement: ?Element,

    //pub fn nodeType(node: Node) u16 { ... }
    
//    fn getRootNode(options: GetRootNodeOptions) Node {
//        _ = options;
//        @panic("todo");
//    }
    
};

pub const Document = struct {
    node: Node,
};

pub const Element = struct {
    node: Node,
};

const ParseOptions = struct {
    context: ?*anyopaque = null,
    on_error: ?*const fn(context: ?*anyopaque, msg: []const u8) void = null,
    pub fn reportError(self: ParseOptions, comptime fmt: []const u8, args: anytype) error{ReportedParseError} {
        const f = self.on_error orelse return error.ReportedParseError;
        var buf: [300]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
            f(self.context, "error message to large to format, the following is its format string");
            f(self.context, fmt);
            return error.ReportedParseError;
        };
        f(self.context, msg);
        return error.ReportedParseError;
    }
};

fn next(tokenizer: *Tokenizer, saved_token: *?Tokenizer.Token) !?Tokenizer.Token {
    if (saved_token.*) |t| {
        // TODO: is t still valid if we set this to null here?
        saved_token.* = null;
        return t;
    }
    return tokenizer.next();
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8, opt: ParseOptions) !Document {
    _ = allocator;

    var state: enum {
        start,
        got_doctype,
    } = .start;

    //var got_doctype = false;
    var tokenizer = Tokenizer.init(content);
    var saved_token: ?Tokenizer.Token = null;

    while (true) {
        switch (state) {
            .start => {
                const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
                switch (token) {
                    .doctype => |d| {
                        //if (got_doctype)
                        //    return opt.reportError("got multiple doctypes", .{});
                        //got_doctype = true;
                        const name = if (d.name_raw) |n| n.slice(content) else
                            return opt.reportError("got doctype with no name", .{});
                        if (!std.ascii.eqlIgnoreCase(name, "html"))
                            return opt.reportError("expected doctype 'html' but got '{s}'", .{name});
                        state = .got_doctype;
                    },
                    else => std.debug.panic("todo handle token {}", .{token})
                }
            },
            .got_doctype => {
                const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
                switch (token) {
                    .start_tag => |t| {
                        std.debug.panic("handle start tag {}", .{t});
                    },
                    else => std.debug.panic("todo handle token {}", .{token})
                }
            },
        }
    }
//    
//    while (try tokenizer.next()) |token| {
//        switch (state) {
//            .initial => switch (token) {
//                .start_tag => |t| {
//                    std.log.info("StartTag: name={s}", .{t.name_raw.slice(content)});
//                },
//                .attr => |a| {
//                    const value = if (a.value_raw) |v| v.slice(content) else "<none>";
//                    std.log.info("    Attr: name={s} value='{s}'", .{a.name_raw.slice(content), value});
//                },
//                .start_tag_end => |self_close| {
//                    std.log.info("StartTagEnd: self_close={}", .{self_close});
//                },
//                .char => |c| {
//                    var s: [10]u8 = undefined;
//                    const len = std.unicode.utf8Encode(c, &s) catch unreachable;
//                    std.log.info("Char: '{}'", .{std.zig.fmtEscapes(s[0 .. len])});
//                },
//                else => |t| {
//                    std.log.info("{}", .{t});
//                },
//            },
//        }
//    }
//    return error.NotImpl;
}
