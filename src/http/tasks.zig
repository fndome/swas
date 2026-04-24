const Context = @import("context.zig").Context;

pub const Task = struct {
    conn_id: u64,
    path: []u8,
    request_data: []u8,
};

pub const ResponseTask = struct {
    conn_id: u64,
    status: u16,
    content_type: Context.ContentType,
    body: []u8,
    headers: []u8,
};
