const r4os = @import("r4os");

const report_max: usize = 32768;
const path_max: usize = 128;
const kind_count: usize = 9;

const Options = struct {
    summary: bool = false,
    framebuffer: bool = false,
    map: bool = false,
    raw: bool = false,
    save_path: []const u8 = "",

    fn normalize(self: *Options) void {
        if (!self.summary and !self.framebuffer and !self.map and !self.raw) {
            self.summary = true;
            self.framebuffer = true;
        }
        if (self.raw) {
            self.summary = true;
            self.framebuffer = true;
            self.map = true;
        }
    }
};

const App = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,
    report: [report_max]u8 = .{0} ** report_max,
    report_len: usize = 0,
    overflow: bool = false,
    echo: bool = true,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }

    fn write(self: *App, text: []const u8) void {
        if (self.echo) self.sys.write(text);
        if (self.report_len >= self.report.len) {
            self.overflow = true;
            return;
        }
        const count = @min(text.len, self.report.len - self.report_len);
        if (count < text.len) self.overflow = true;
        if (count != 0) {
            @memcpy(self.report[self.report_len .. self.report_len + count], text[0..count]);
            self.report_len += count;
        }
    }

    fn line(self: *App, text: []const u8) void {
        self.write(text);
        self.write("\r\n");
    }

    fn writeDec(self: *App, value: u64) void {
        var buf: [20]u8 = undefined;
        var pos = buf.len;
        var n = value;
        if (n == 0) {
            self.write("0");
            return;
        }
        while (n > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.write(buf[pos..]);
    }

    fn writeHex(self: *App, value: u64) void {
        self.write("0x");
        var shift: u6 = 60;
        while (true) {
            const nibble: u8 = @intCast((value >> shift) & 0xF);
            self.write(&[_]u8{if (nibble < 10) '0' + nibble else 'A' + (nibble - 10)});
            if (shift == 0) break;
            shift -= 4;
        }
    }

    fn writeZ(self: *App, bytes: []const u8) void {
        self.write(spanZ(bytes));
    }

    fn writeBytes(self: *App, bytes: u64) void {
        self.writeDec(bytes);
        self.write(" bytes");
        if (bytes >= 1024) {
            self.write(" (");
            self.writeDec(bytes / 1024);
            self.write(" KB");
            if (bytes >= 1024 * 1024) {
                self.write(", ");
                self.writeDec(bytes / (1024 * 1024));
                self.write(" MB");
            }
            self.write(")");
        }
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    var options = parseOptions(zSlice(app.sys.argsRaw())) orelse {
        usage(&app);
        return 1;
    };
    options.normalize();

    if (!app.dev.hasFn("boot_info_summary")) {
        app.line("BOOTINFO: BootInfo API not available");
        return 1;
    }

    if (options.save_path.len != 0) app.echo = false;
    const rc = runReport(&app, options);
    if (options.save_path.len != 0) {
        var path_buf: [path_max + 1]u8 = .{0} ** (path_max + 1);
        const path = makeZ(options.save_path, path_buf[0..]) orelse {
            app.sys.println("BOOTINFO: save path too long");
            return 1;
        };
        const written = app.sys.fileWrite(path, app.report[0..app.report_len]);
        if (written <= 0) {
            app.sys.println("BOOTINFO: save failed");
            return 1;
        }
        if (app.overflow) app.sys.println("BOOTINFO: report saved, but truncated");
        app.sys.write("BOOTINFO saved: ");
        app.sys.write(options.save_path);
        app.sys.write("\r\n");
    }
    return rc;
}

fn runReport(app: *App, options: Options) i32 {
    const summary = app.dev.bootInfoSummary() orelse {
        app.line("BOOTINFO: read failed");
        return 1;
    };

    app.line("BOOTINFO.R4X");
    app.line("===========");
    if (options.summary) {
        printSummary(app, summary);
        printMemorySummary(app);
        printPagingSummary(app);
    }
    if (options.framebuffer) printFramebuffer(app, summary);
    if (options.map) printMemoryMap(app);
    if (options.raw) printRaw(app, summary);
    if (app.overflow) app.line("WARN: report truncated");
    return if ((summary.flags & r4os.abi.boot_info_flag_initialized) != 0) 0 else 1;
}

fn printSummary(app: *App, s: r4os.abi.BootInfoSummary) void {
    app.line("");
    app.line("Summary");
    app.write("Loader . . . . . . . . . : ");
    app.writeZ(s.bootloader_name[0..]);
    app.line("");
    app.write("Initialized . . . . . . . : ");
    app.line(if ((s.flags & r4os.abi.boot_info_flag_initialized) != 0) "yes" else "no");
    app.write("Memory map entries . . . : ");
    app.writeDec(s.memory_map_count);
    app.write("/");
    app.writeDec(s.max_memory_map_entries);
    if ((s.flags & r4os.abi.boot_info_flag_memory_map_truncated) != 0) app.write(" truncated");
    app.line("");
    app.write("HHDM offset . . . . . . . : ");
    if ((s.flags & r4os.abi.boot_info_flag_has_hhdm) != 0) app.writeHex(s.hhdm_offset) else app.write("missing");
    app.line("");
    app.write("RSDP address . . . . . . : ");
    if ((s.flags & r4os.abi.boot_info_flag_has_rsdp) != 0) app.writeHex(s.rsdp_address) else app.write("missing");
    app.line("");
    printWarnings(app, s);
}

fn printWarnings(app: *App, s: r4os.abi.BootInfoSummary) void {
    var any = false;
    app.write("Warnings . . . . . . . . : ");
    if ((s.flags & r4os.abi.boot_info_flag_initialized) == 0) {
        app.write("not initialized");
        any = true;
    }
    if ((s.flags & r4os.abi.boot_info_flag_has_hhdm) == 0) {
        if (any) app.write(", ");
        app.write("HHDM missing");
        any = true;
    }
    if ((s.flags & r4os.abi.boot_info_flag_has_framebuffer) == 0) {
        if (any) app.write(", ");
        app.write("framebuffer missing");
        any = true;
    }
    if ((s.flags & r4os.abi.boot_info_flag_memory_map_truncated) != 0) {
        if (any) app.write(", ");
        app.write("memory map truncated");
        any = true;
    }
    if (!any) app.write("none");
    app.line("");
}

fn printMemorySummary(app: *App) void {
    var totals: [kind_count]u64 = .{0} ** kind_count;
    var largest_usable_base: u64 = 0;
    var largest_usable_len: u64 = 0;
    const count = app.dev.bootInfoMemoryCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = app.dev.bootInfoMemoryEntry(i) orelse continue;
        const kind: usize = if (entry.kind < kind_count) entry.kind else r4os.abi.boot_memory_kind_unknown;
        totals[kind] +%= entry.length;
        if (entry.kind == r4os.abi.boot_memory_kind_usable and entry.length > largest_usable_len) {
            largest_usable_base = entry.base;
            largest_usable_len = entry.length;
        }
    }

    app.line("");
    app.line("Memory Summary");
    printKindTotal(app, "usable", totals[r4os.abi.boot_memory_kind_usable]);
    printKindTotal(app, "reserved", totals[r4os.abi.boot_memory_kind_reserved]);
    printKindTotal(app, "bootloader", totals[r4os.abi.boot_memory_kind_bootloader_reclaimable]);
    printKindTotal(app, "kernel", totals[r4os.abi.boot_memory_kind_kernel_and_modules]);
    printKindTotal(app, "framebuffer", totals[r4os.abi.boot_memory_kind_framebuffer]);
    app.write("Largest usable . . . . . : ");
    if (largest_usable_len != 0) {
        app.writeHex(largest_usable_base);
        app.write(" ");
        app.writeBytes(largest_usable_len);
    } else {
        app.write("none");
    }
    app.line("");
}

fn printKindTotal(app: *App, name: []const u8, value: u64) void {
    app.write(name);
    var pad = if (name.len < 22) 22 - name.len else 1;
    while (pad > 0) : (pad -= 1) app.write(".");
    app.write(" : ");
    app.writeBytes(value);
    app.line("");
}

fn printPagingSummary(app: *App) void {
    app.line("");
    app.line("Paging");
    const summary = app.dev.pagingSummary() orelse {
        app.line("Paging summary . . . . . : not available");
        return;
    };

    app.write("Active root . . . . . . . : ");
    app.writeHex(summary.active_root_phys);
    app.line("");
    app.write("Hardware CR3 . . . . . . : ");
    app.writeHex(summary.hardware_cr3);
    app.write(" ");
    app.line(if ((summary.flags & r4os.abi.paging_flag_active_root_matches_hardware) != 0) "match" else "mismatch");
    app.write("Root owner . . . . . . . : ");
    app.line(pagingOwnerName(summary.root_owner));
    app.write("R4OS PML4 active . . . . : ");
    app.line(if ((summary.flags & r4os.abi.paging_flag_r4os_root_active) != 0) "yes" else "no");
    app.write("CR3 switch . . . . . . . : ");
    app.line(if ((summary.flags & r4os.abi.paging_flag_cr3_switch_done) != 0) "done" else "pending");
    app.write("Old CR3 -> new CR3 . . . : ");
    app.writeHex(summary.old_cr3);
    app.write(" -> ");
    app.writeHex(summary.new_cr3);
    app.line("");
    app.write("Page-table blocks . . . . : ");
    app.writeDec(summary.page_table_blocks);
    app.write(" kernel=");
    app.writeDec(summary.kernel_page_table_blocks);
    app.write(" bootloader=");
    app.writeDec(summary.bootloader_page_table_blocks);
    app.line("");
    app.write("Page-table bytes . . . . : ");
    app.writeBytes(summary.page_table_bytes);
    app.line("");
    app.write("Limine tables . . . . . : old=");
    app.writeDec(summary.limine_old_table_frames);
    app.write(" active=");
    app.writeDec(summary.limine_active_table_frames);
    app.write(" referenced=");
    app.writeDec(summary.limine_referenced_frames);
    app.line("");
    app.write("Limine reclaim . . . . . : quarantined=");
    app.writeDec(summary.limine_quarantined_frames);
    app.write(" released=");
    app.writeDec(summary.limine_released_frames);
    app.write(" retained=");
    app.writeDec(summary.limine_retained_frames);
    app.line("");
    app.write("Paging ops . . . . . . . : map=");
    app.writeDec(summary.map_pages);
    app.write(" unmap=");
    app.writeDec(summary.unmap_pages);
    app.write(" invlpg=");
    app.writeDec(summary.invlpg_flushes);
    app.write(" mismatches=");
    app.writeDec(summary.root_mismatches);
    app.line("");
}

fn printFramebuffer(app: *App, s: r4os.abi.BootInfoSummary) void {
    app.line("");
    app.line("Framebuffer");
    if ((s.flags & r4os.abi.boot_info_flag_has_framebuffer) == 0) {
        app.line("missing");
        return;
    }
    app.write("Address . . . . . . . . . : ");
    app.writeHex(s.framebuffer_address);
    app.line("");
    app.write("Size . . . . . . . . . . : ");
    app.writeDec(s.framebuffer_width);
    app.write(" x ");
    app.writeDec(s.framebuffer_height);
    app.write(" @ ");
    app.writeDec(s.framebuffer_bpp);
    app.line(" bpp");
    app.write("Pitch . . . . . . . . . : ");
    app.writeDec(s.framebuffer_pitch);
    app.line(" bytes");
    app.write("Memory model . . . . . . : ");
    app.writeDec(s.framebuffer_memory_model);
    app.line("");
    app.write("Red mask . . . . . . . . : size=");
    app.writeDec(s.framebuffer_red_mask_size);
    app.write(" shift=");
    app.writeDec(s.framebuffer_red_mask_shift);
    app.line("");
    app.write("Green mask . . . . . . . : size=");
    app.writeDec(s.framebuffer_green_mask_size);
    app.write(" shift=");
    app.writeDec(s.framebuffer_green_mask_shift);
    app.line("");
    app.write("Blue mask . . . . . . . : size=");
    app.writeDec(s.framebuffer_blue_mask_size);
    app.write(" shift=");
    app.writeDec(s.framebuffer_blue_mask_shift);
    app.line("");
    app.write("EDID . . . . . . . . . . : ");
    if ((s.flags & r4os.abi.boot_info_flag_has_edid) != 0) {
        app.writeBytes(s.edid_size);
        app.write(" at ");
        app.writeHex(s.edid_address);
    } else {
        app.write("missing");
    }
    app.line("");
}

fn printMemoryMap(app: *App) void {
    app.line("");
    app.line("Memory Map");
    const count = app.dev.bootInfoMemoryCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = app.dev.bootInfoMemoryEntry(i) orelse continue;
        app.write("[");
        app.writeDec(i);
        app.write("] base=");
        app.writeHex(entry.base);
        app.write(" end=");
        app.writeHex(entry.base +% entry.length);
        app.write(" len=");
        app.writeBytes(entry.length);
        app.write(" kind=");
        app.line(memoryKindName(entry.kind));
    }
}

fn printRaw(app: *App, s: r4os.abi.BootInfoSummary) void {
    app.line("");
    app.line("Raw");
    app.write("flags=");
    app.writeHex(s.flags);
    app.line("");
    app.write("fb_model=");
    app.writeDec(s.framebuffer_memory_model);
    app.write(" edid_size=");
    app.writeDec(s.edid_size);
    app.write(" edid_addr=");
    app.writeHex(s.edid_address);
    app.line("");
}

fn parseOptions(args_raw: []const u8) ?Options {
    var result: Options = .{};
    var rest = trim(args_raw);
    while (takeToken(&rest)) |token| {
        if (equalsIgnoreCase(token, "/?") or equalsIgnoreCase(token, "-?")) return null;
        if (equalsIgnoreCase(token, "/SUMMARY") or equalsIgnoreCase(token, "-SUMMARY")) {
            result.summary = true;
        } else if (equalsIgnoreCase(token, "/FB") or equalsIgnoreCase(token, "-FB")) {
            result.framebuffer = true;
        } else if (equalsIgnoreCase(token, "/MAP") or equalsIgnoreCase(token, "-MAP")) {
            result.map = true;
        } else if (equalsIgnoreCase(token, "/RAW") or equalsIgnoreCase(token, "-RAW")) {
            result.raw = true;
        } else if (equalsIgnoreCase(token, "/SAVE") or equalsIgnoreCase(token, "-SAVE")) {
            result.save_path = takeToken(&rest) orelse return null;
        } else if (startsWithIgnoreCase(token, "/SAVE=") or startsWithIgnoreCase(token, "-SAVE=")) {
            result.save_path = token[6..];
            if (result.save_path.len == 0) return null;
        } else {
            return null;
        }
    }
    return result;
}

fn usage(app: *App) void {
    app.line("Usage: BOOTINFO [/SUMMARY] [/FB] [/MAP] [/RAW] [/SAVE path]");
}

fn pagingOwnerName(owner: u8) []const u8 {
    return switch (owner) {
        r4os.abi.paging_root_owner_bootloader => "bootloader",
        r4os.abi.paging_root_owner_r4os => "r4os",
        else => "unknown",
    };
}

fn memoryKindName(kind: u8) []const u8 {
    return switch (kind) {
        r4os.abi.boot_memory_kind_usable => "usable",
        r4os.abi.boot_memory_kind_reserved => "reserved",
        r4os.abi.boot_memory_kind_acpi_reclaimable => "acpi-reclaim",
        r4os.abi.boot_memory_kind_acpi_nvs => "acpi-nvs",
        r4os.abi.boot_memory_kind_bad_memory => "bad",
        r4os.abi.boot_memory_kind_bootloader_reclaimable => "bootloader",
        r4os.abi.boot_memory_kind_kernel_and_modules => "kernel",
        r4os.abi.boot_memory_kind_framebuffer => "framebuffer",
        else => "unknown",
    };
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0 and len < 512) : (len += 1) {}
    return ptr[0..len];
}

fn spanZ(bytes: []const u8) []const u8 {
    var len: usize = 0;
    while (len < bytes.len and bytes[len] != 0) : (len += 1) {}
    return bytes[0..len];
}

fn makeZ(text: []const u8, out: []u8) ?[*:0]const u8 {
    if (text.len + 1 > out.len) return null;
    if (text.len != 0) @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn takeToken(rest: *[]const u8) ?[]const u8 {
    rest.* = trim(rest.*);
    if (rest.*.len == 0) return null;
    var end: usize = 0;
    while (end < rest.*.len and rest.*[end] != ' ' and rest.*[end] != '\t') : (end += 1) {}
    const token = rest.*[0..end];
    rest.* = rest.*[end..];
    return token;
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t' or value[start] == '\r' or value[start] == '\n')) : (start += 1) {}
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t' or value[end - 1] == '\r' or value[end - 1] == '\n')) : (end -= 1) {}
    return value[start..end];
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and equalsIgnoreCase(value[0..prefix.len], prefix);
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}
