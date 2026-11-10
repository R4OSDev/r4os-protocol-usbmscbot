const r4os = @import("r4os");

const CBW_SIGNATURE: u32 = 0x43425355;
const CSW_SIGNATURE: u32 = 0x53425355;

comptime {
    if (!@import("builtin").is_test) asm (r4os.technical2.protocolEntriesAsm("usbmsc_init", "usbmsc_shutdown", "usbmsc_query", "usbmsc_dispatch"));
}

export fn usbmsc_init(api: *const r4os.r4dev.ProtocolApi2) callconv(.c) i32 {
    const ctx = r4os.r4dev.ProtocolContext2.init(api);
    if (!ctx.requires(.{ "register_role", "set_status" })) return r4os.abi.err_no_fn;
    const registered = ctx.registerRole("usb.msc_bot", .usb, 0);
    if (registered != 0) return registered;
    return ctx.setStatus(.active, "USB MSC BOT R4P active");
}

export fn usbmsc_shutdown() callconv(.c) i32 {
    return 0;
}

export fn usbmsc_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("USB MSC BOT R4P ready"),
    };
    return 0;
}

export fn usbmsc_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    _ = out_buffer;
    const request = requestFromBuffer(in_buffer) orelse return -2;
    switch (op) {
        r4os.abi.usb_msc_bot_op_build_cbw => buildCbw(request),
        r4os.abi.usb_msc_bot_op_parse_csw => parseCsw(request),
        r4os.abi.usb_msc_bot_op_self_test => selfTest(request),
        else => return -4,
    }
    return request.result;
}

fn buildCbw(op: *r4os.abi.UsbMscBotOp) void {
    if (op.cdb_len == 0 or op.cdb_len > op.cdb.len) {
        op.result = r4os.abi.usb_msc_bot_result_bad_cdb;
        return;
    }
    op.cbw = .{0} ** r4os.abi.usb_msc_bot_cbw_len;
    writeLe32(op.cbw[0..4], CBW_SIGNATURE);
    writeLe32(op.cbw[4..8], op.tag);
    writeLe32(op.cbw[8..12], op.transfer_len);
    op.cbw[12] = if (op.direction == r4os.abi.usb_msc_bot_dir_in) 0x80 else 0x00;
    op.cbw[13] = op.lun & 0x0F;
    op.cbw[14] = op.cdb_len;
    const len: usize = @intCast(op.cdb_len);
    @memcpy(op.cbw[15 .. 15 + len], op.cdb[0..len]);
    op.result = r4os.abi.usb_msc_bot_result_ok;
}

fn parseCsw(op: *r4os.abi.UsbMscBotOp) void {
    const signature = readLe32(op.csw[0..4]);
    op.csw_tag = readLe32(op.csw[4..8]);
    op.residue = readLe32(op.csw[8..12]);
    op.status = op.csw[12];
    if (signature != CSW_SIGNATURE) {
        op.result = r4os.abi.usb_msc_bot_result_bad_csw;
        return;
    }
    if (op.csw_tag != op.tag) {
        op.result = r4os.abi.usb_msc_bot_result_tag_mismatch;
        return;
    }
    if (op.residue > op.transfer_len) {
        op.result = r4os.abi.usb_msc_bot_result_residue;
        return;
    }
    op.result = switch (op.status) {
        0 => r4os.abi.usb_msc_bot_result_ok,
        1 => r4os.abi.usb_msc_bot_result_command_failed,
        2 => r4os.abi.usb_msc_bot_result_phase_error,
        else => r4os.abi.usb_msc_bot_result_unsupported_status,
    };
}

fn selfTest(op: *r4os.abi.UsbMscBotOp) void {
    var probe: r4os.abi.UsbMscBotOp = .{
        .tag = 0xAABBCCDD,
        .transfer_len = 36,
        .direction = r4os.abi.usb_msc_bot_dir_in,
        .cdb_len = 6,
    };
    probe.cdb[0] = 0x12;
    probe.cdb[4] = 36;
    buildCbw(&probe);
    if (probe.result != r4os.abi.usb_msc_bot_result_ok or readLe32(probe.cbw[0..4]) != CBW_SIGNATURE or probe.cbw[12] != 0x80 or probe.cbw[14] != 6) {
        op.result = r4os.abi.usb_msc_bot_result_bad_cdb;
        return;
    }
    writeLe32(probe.csw[0..4], CSW_SIGNATURE);
    writeLe32(probe.csw[4..8], probe.tag);
    writeLe32(probe.csw[8..12], 0);
    probe.csw[12] = 0;
    parseCsw(&probe);
    if (probe.result != r4os.abi.usb_msc_bot_result_ok or probe.csw_tag != 0xAABBCCDD or probe.status != 0) {
        op.result = r4os.abi.usb_msc_bot_result_bad_csw;
        return;
    }
    probe.csw[12] = 1;
    parseCsw(&probe);
    if (probe.result != r4os.abi.usb_msc_bot_result_command_failed) {
        op.result = r4os.abi.usb_msc_bot_result_bad_csw;
        return;
    }
    op.result = r4os.abi.usb_msc_bot_result_ok;
}

fn requestFromBuffer(buffer: *const r4os.abi.ProtocolBuffer) ?*r4os.abi.UsbMscBotOp {
    const native = r4os.native_protocol_view;
    // These original caller-owned operation records are not wire headers.
    // Dispatch borrows them exclusively and never owns a USB transfer.
    var metadata = buffer.*;
    return (native.InOut(r4os.abi.UsbMscBotOp).init(&metadata, native.Policy.record(r4os.abi.UsbMscBotOp, .inout, .prefix)) catch return null).value;
}

fn readLe32(bytes: []const u8) u32 {
    var reader = r4os.binary_cursor.Reader.init(bytes) catch unreachable;
    return reader.readInt(u32, .little) catch unreachable;
}

fn writeLe32(out: []u8, value: u32) void {
    var writer = r4os.binary_cursor.Writer.init(out) catch unreachable;
    writer.writeInt(u32, value, .little) catch unreachable;
}

fn note(comptime text: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    @memcpy(out[0..text.len], text);
    return out;
}
