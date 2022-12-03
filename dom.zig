// see https://dom.spec.whatwg.org/#nodes
const std = @import("std");

const HtmlTokenizer = @import("HtmlTokenizer.zig");
const Token = HtmlTokenizer.Token;

const htmlid = @import("htmlid.zig");
const TagId = htmlid.TagId;
const AttrId = htmlid.AttrId;
const SvgTagId = htmlid.SvgTagId;
const SvgAttrId = htmlid.SvgAttrId;

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

pub const NodeInterface = struct {
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

pub fn defaultDisplayIsBlock(id: TagId) bool {
    return switch (id) {
        .address, .article, .aside, .blockquote, .canvas, .dd, .div,
        .dl, .dt, .fieldset, .figcaption, .figure, .footer, .form,
        .h1, .h2, .h3, .h4, .h5, .h6, .header, .hr, .li, .main, .nav,
        .noscript, .ol, .p, .pre, .section, .table, .tfoot, .ul, .video,
        => true,
        else => false,
    };
}

/// An element that can never have content
pub fn isVoidElement(id: TagId) bool {
    return switch (id) {
        .area, .base, .br, .col, .command, .embed, .hr, .img, .input,
        .keygen, .link, .meta, .param, .source, .track, .wbr,
        => true,
        else => false,
    };
}

fn lookupIdIgnoreCase(comptime map_namespace: type, name: []const u8) ?map_namespace.Enum {
    // need enough room for the max tag name
    var buf: [20]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return map_namespace.map.get(buf[0 .. name.len]);
}
fn lookupTagIgnoreCase(name: []const u8) ?TagId {
    return lookupIdIgnoreCase(htmlidmaps.tag, name);
}
fn lookupAttrIgnoreCase(name: []const u8) ?AttrId {
    return lookupIdIgnoreCase(htmlidmaps.attr, name);
}

pub const Node = union(enum) {
    start_tag: struct {
        id: TagId,
        self_closing: bool,
        // TODO: maybe make this a u32?
        parent_index: usize,
    },
    end_tag: TagId,
    attr: struct {
        id: AttrId,
        value: ?HtmlTokenizer.Span,
    },
    text: HtmlTokenizer.Span,
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

fn next(tokenizer: *HtmlTokenizer, saved_token: *?Token) !?Token {
    if (saved_token.*) |t| {
        // TODO: is t still valid if we set this to null here?
        saved_token.* = null;
        return t;
    }
    return tokenizer.next();
}

// The parse should only succeed if the following guarantees are met
// 1. all "spans" returned contain valid UTF8 sequences
// 2. all start/end tags are balanced
// 3. the <body> and <script> tags can only go 1 level deep
//    this guarantee can make processing the dom simpler because you only need
//    a single boolean value to tack when you enter or exit one of these tags.
// 4. there is only 1 <body> tag
pub fn parse(allocator: std.mem.Allocator, content: []const u8, opt: ParseOptions) !std.ArrayListUnmanaged(Node) {
    var tokenizer = HtmlTokenizer.init(content);
    var saved_token: ?Token = null;

    var nodes = std.ArrayListUnmanaged(Node){ };
    errdefer nodes.deinit(allocator);

    // check for doctype first
    {
        const token = (try tokenizer.next()) orelse return nodes;
        switch (token) {
            .doctype => |d| {
                const name = if (d.name_raw) |n| n.slice(content) else
                    return opt.reportError("got doctype with no name", .{});
                if (!std.ascii.eqlIgnoreCase(name, "html"))
                    return opt.reportError("expected doctype 'html' but got '{}'", .{std.zig.fmtEscapes(name)});
            },
            else => {
                saved_token = token;
            },
        }
    }

    // get the html tag
    get_html_tag_loop:
    while (true) {
        const token = (try next(&tokenizer, &saved_token)) orelse return nodes;
        switch (token) {
            .start_tag => |name_raw_span| {
                const name_raw = name_raw_span.slice(content);
                if (!std.mem.eql(u8, name_raw, "html"))
                    return opt.reportError("expected <html> but got <{}>", .{std.zig.fmtEscapes(name_raw)});
                break :get_html_tag_loop;
            },
            .char => |span| {
                const slice = span.slice(content);
                if (!isWhitespace(slice))
                    return opt.reportError("unexpected data before <html> '{}'", .{std.zig.fmtEscapes(slice)});
            },
            else => return opt.reportError("expected <html> but got a {s} token", .{@tagName(token)}),
        }
    }
    try nodes.append(allocator, .{.start_tag = .{
        .id = .html,
        .parent_index = 0,
        .self_closing = false,
    }});

    const State = union(enum) {
        default: struct {
            start_tag_index: usize,
        },
        data: struct {
            start_tag_index: usize,
            span: HtmlTokenizer.Span,
        },
        in_tag: InTag,
        pub const InTag = struct {
            parent_tag_index: usize,
            start_tag_index: usize,
        };
    };
    var state = State{ .default = .{ .start_tag_index = 0 } };
    var got_body_tag = false;
    var inside_script_tag = false;

    parse_loop:
    while (true) switch (state) {
        .default => |default_state| {
            const token = (try next(&tokenizer, &saved_token)) orelse return opt.reportError(
                "missing </{s}>",
                .{@tagName(nodes.items[default_state.start_tag_index].start_tag.id)},
            );
            switch (token) {
                .start_tag => |name_raw_span| {
                    const name_raw = name_raw_span.slice(content);
                    const id = lookupTagIgnoreCase(name_raw) orelse
                        return opt.reportError("unknown tag '{}'", .{std.zig.fmtEscapes(name_raw)});
                    //std.log.info("DEBUG: <{s}> (start={},void={})", .{@tagName(id), default_state.start_tag_index, isVoidElement(id)});
                    switch (id) {
                        .body => {
                            if (got_body_tag)
                                return opt.reportError("multiple <body> tags", .{});
                            got_body_tag = true;
                        },
                        .script => {
                            if (inside_script_tag)
                                return opt.reportError("recursive <script> tags", .{});
                            inside_script_tag = true;
                        },
                        else => {},
                    }
                    try nodes.append(allocator, .{ .start_tag = .{
                        .id = id,
                        .parent_index = default_state.start_tag_index,
                        .self_closing = false,
                    } });
                    const next_start_tag_index = if (isVoidElement(id))
                        default_state.start_tag_index
                    else
                        nodes.items.len - 1;
                    state = .{ .in_tag = .{
                        .parent_tag_index = default_state.start_tag_index,
                        .start_tag_index = next_start_tag_index,
                    } };
                },
                .end_tag => |name_raw_span| {
                    const name_raw = name_raw_span.slice(content);
                    const id = lookupTagIgnoreCase(name_raw) orelse
                        return opt.reportError("unknown tag '{}'", .{std.zig.fmtEscapes(name_raw)});
                    //std.log.info("DEBUG: </{s}>", .{@tagName(id)});
                    const start_tag = switch (nodes.items[default_state.start_tag_index]) {
                        .start_tag => |*t| t,
                        else => unreachable,
                    };
                    if (start_tag.id != id)
                        return opt.reportError("</{s}> cannot close <{s}>", .{@tagName(id), @tagName(start_tag.id)});
                    switch (id) {
                        .script => {
                            std.debug.assert(inside_script_tag);
                            inside_script_tag = false;
                        },
                        else => {},
                    }
                    try nodes.append(allocator, .{ .end_tag = id });
                    if (default_state.start_tag_index == 0)
                        break :parse_loop;
                    //std.log.debug("DEBUG: restoring <{s}>", .{@tagName(nodes.items[start_tag.parent_index].start_tag.id)});
                    state = .{ .default = .{
                        .start_tag_index = start_tag.parent_index,
                    }};
                },
                .char => |span| state = .{ .data = .{
                    .start_tag_index = default_state.start_tag_index,
                    .span = span,
                }},
                else => std.debug.panic("todo handle token {}", .{token})
            }
        },
        .data => |*data_state| {
            if (try next(&tokenizer, &saved_token)) |token| switch (token) {
                .char => |span| {
                    //std.log.info("old '{s}' {} new '{s}' {}", .{
                    //    data_state.span.slice(content), data_state.span,
                    //    span.slice(content), span});
                    // TODO: this should be true eventually
                    //std.debug.assert(data_state.span.limit == span.start);
                    data_state.span.limit = span.limit;
                },
                else => {
                    try nodes.append(allocator, .{ .text = data_state.span });
                    saved_token = token;
                    state = .{ .default = .{
                        .start_tag_index = data_state.start_tag_index,
                    }};
                },
            } else {
                try nodes.append(allocator, .{ .text = data_state.span });
                state = .{ .default = .{
                    .start_tag_index = data_state.start_tag_index,
                }};
            }
        },
        .in_tag => |tag_state| {
            const token = (try next(&tokenizer, &saved_token)) orelse return error.NotImpl;
            switch (token) {
                .start_tag, .end_tag => {
                    //std.log.info("DEBUG: append <{s}>", .{@tagName(tag_state.id)});
                    saved_token = token;
                    state = .{ .default = .{
                        .start_tag_index = tag_state.start_tag_index,
                    }};
                },
                .attr => |t| {
                    const name_raw = t.name_raw.slice(content);
                    //std.log.info("DEBUG: attr name_raw is '{s}'", .{name_raw});
                    const id = lookupAttrIgnoreCase(name_raw) orelse {
                        if (std.ascii.startsWithIgnoreCase(name_raw, "data-"))
                            return opt.reportError("custom attribute '{s}' not supported", .{name_raw});
                        return opt.reportError("unknown attribute '{}'", .{std.zig.fmtEscapes(name_raw)});
                    };
                    // TODO: also process value
                    try nodes.append(allocator, .{ .attr = .{ .id = id, .value = t.value_raw } });
                },
                .start_tag_self_closed => {
                    nodes.items[tag_state.start_tag_index].start_tag.self_closing = true;
                },
                .char => |span| state = .{ .data = .{
                    .start_tag_index = tag_state.start_tag_index,
                    .span = span,
                }},
                else => std.debug.panic("todo handle token {}", .{token})
            }
        },
    };

    while (try next(&tokenizer, &saved_token)) |token| switch (token) {
        .char => |span| {
            const slice = span.slice(content);
            if (!isWhitespace(slice))
                return opt.reportError("unexpected data after </html> '{}'", .{std.zig.fmtEscapes(slice)});
        },
        else => return opt.reportError("unexpected {s} token after </html>", .{@tagName(token)}),
    };
    return nodes;
}

fn isWhitespace(slice: []const u8) bool {
    for (slice) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

pub fn dump(content: []const u8, nodes: []const Node) !void {
    const stdout = std.io.getStdOut().writer();
    for (nodes) |node| {
        switch (node) {
            .start_tag => |t| {
                const close: []const u8 = if (t.self_closing) " /" else "";
                try stdout.print("<{s}{s}>\n", .{@tagName(t.id), close});
            },
            .end_tag => |id| try stdout.print("</{s}>\n", .{@tagName(id)}),
            .attr => |a| {
                if (a.value) |v| {
                    try stdout.print("  {s}=\"{s}\"\n", .{@tagName(a.id), v.slice(content)});
                } else {
                    try stdout.print("  {s}=\n", .{@tagName(a.id)});
                }
            },
            .text => |t| {
                try stdout.print("---text---\n{s}\n----------\n", .{t.slice(content)});
            },
        }
    }
}
