// see https://dom.spec.whatwg.org/#nodes
const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const htmlid = @import("htmlid.zig");
const TagId = htmlid.TagId;
const AttrId = htmlid.AttrId;

const htmlidmaps = @import("htmlidmaps.zig");

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

fn lookupTagIgnoreCase(name: []const u8) ?TagId {
    // need enough room for the max tag name
    var buf: [20]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return htmlidmaps.tag_id_map.get(buf[0 .. name.len]);
}
fn lookupAttrIgnoreCase(name: []const u8) ?AttrId {
    // need enough room for the max attr name
    var buf: [20]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return htmlidmaps.attr_id_map.get(buf[0 .. name.len]);
}

pub const DomNode = union(enum) {
    tag: struct {
        id: TagId,
        self_closing: bool,
    },
    attr: struct {
        id: AttrId,
        value: u32,
    },
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

fn next(tokenizer: *Tokenizer, saved_token: *?Token) !?Token {
    if (saved_token.*) |t| {
        // TODO: is t still valid if we set this to null here?
        saved_token.* = null;
        return t;
    }
    return tokenizer.next();
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8, opt: ParseOptions) ![]DomNode {
    var state: union(enum) {
        start: void,
        in_doctype: void,
        default: void,
        in_tag: struct {
            start_node_index: usize,
        },
    } = .start;

    var nodes = std.ArrayListUnmanaged(DomNode){ };
    errdefer nodes.deinit(allocator);

    var tokenizer = Tokenizer.init(content);
    var saved_token: ?Token = null;

    while (true) {
        switch (state) {
            .start => {
                const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
                switch (token) {
                    .doctype => |d| {
                        const name = if (d.name_raw) |n| n.slice(content) else
                            return opt.reportError("got doctype with no name", .{});
                        if (!std.ascii.eqlIgnoreCase(name, "html"))
                            return opt.reportError("expected doctype 'html' but got '{}'", .{std.zig.fmtEscapes(name)});
                        state = .default;
                    },
                    else => std.debug.panic("todo handle token {}", .{token})
                }
            },
            .in_doctype => {
                const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
                switch (token) {
                    .start_tag => {
                        saved_token = token;
                        state = .default;
                    },
                    else => std.debug.panic("todo handle token {} where state=in_doctype", .{token}),
                }
            },
            .default => {
                const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
                switch (token) {
                    .start_tag => |t| {
                        const name_raw = t.name_raw.slice(content);
                        const id = lookupTagIgnoreCase(name_raw) orelse
                            return opt.reportError("unknown tag '{}'", .{std.zig.fmtEscapes(name_raw)});
                        //std.log.info("DEBUG: start <{s}>", .{@tagName(id)});
                        try nodes.append(allocator, .{ .tag = .{ .id = id, .self_closing = false } });
                        state = .{ .in_tag = .{ .start_node_index = nodes.items.len - 1 } };
                    },
                    else => std.debug.panic("todo handle token {}", .{token})
                }
            },
            .in_tag => |tag_state| {
                const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
                switch (token) {
                    .start_tag => {
                        //std.log.info("DEBUG: append <{s}>", .{@tagName(tag_state.id)});
                        saved_token = token;
                        state = .default;
                    },
                    .attr => |t| {
                        const name_raw = t.name_raw.slice(content);
                        //std.log.info("DEBUG: attr name_raw is '{s}'", .{name_raw});
                        const id = lookupAttrIgnoreCase(name_raw) orelse
                            return opt.reportError("unknown attribute '{}'", .{std.zig.fmtEscapes(name_raw)});
                        // TODO: also process value
                        try nodes.append(allocator, .{ .attr = .{ .id = id, .value = 0 } });
                    },
                    .start_tag_self_closed => {
                        nodes.items[tag_state.start_node_index].tag.self_closing = true;
                    },
                    else => std.debug.panic("todo handle token {}", .{token})
                }
            },
        }
    }
    return nodes.toOwnedSlice(allocator);
}
