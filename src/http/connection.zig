const ConnState = enum(u8) {
    reading,
    processing,
    writing,
    closing,
    ws_reading,
    ws_writing,
};

pub const Connection = struct {
    id: u64,
    fd: i32,
    fixed_index: u16 = 0,
    state: ConnState = .reading,
    read_bid: u16 = 0,
    read_len: usize = 0,
    write_headers_len: usize = 0,
    write_offset: usize = 0,
    /// Lazy-allocated write buffer from tiered pool.
    response_buf: ?[]u8 = null,
    /// Tier index for response_buf (valid only when response_buf != null). 0xFF = slab buffer.
    response_buf_tier: u8 = 0,
    write_body: ?[]u8 = null,
    keep_alive: bool = false,
    last_active_ms: i64 = 0,
    ws_token: ?[]const u8 = null,
};
