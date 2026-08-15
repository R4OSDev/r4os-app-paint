const r4os = @import("r4os");
const r4img = @import("r4img");
const bmp_writer = @import("bmp_writer.zig");
const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    net: r4os.r4net.Context,
    dev: r4os.r4dev.Context,
    img: r4img.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .net = r4_app.networkLowLevel() orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
            .img = r4img.Context.init(r4_app.startContext()) orelse return null,
        };
    }
};

const path_capacity: usize = 192;
const status_capacity: usize = 96;
const message_title_capacity: usize = 40;
const message_text_capacity: usize = 128;
const dir_buffer_capacity: usize = 4096;
const max_dir_items: usize = 96;
const dir_item_capacity: usize = 96;
const scratch_capacity: usize = 512;
const bmp_buffer_capacity: usize = 70 * 1024;

const default_image_w: u32 = 64;
const default_image_h: u32 = 48;
const background_color: u32 = 0x00FFFFFF;
const pencil_color: u32 = 0x00000000;
const face_mid: u32 = 0x00D4D0C8;
const work_bg: u32 = 0x00808080;
const status_h: i32 = 20;
const toolbar_h: i32 = 34;

const ctrl_n: u8 = 0x0E;
const ctrl_o: u8 = 0x0F;
const ctrl_s: u8 = 0x13;

const SizeField = r4os.gui.TextField(5);

const Tool = enum {
    pencil,
    eraser,
};

const Command = enum(u32) {
    file_new = 101,
    file_open = 102,
    file_save = 103,
    file_save_as = 104,
    file_exit = 105,
    edit_change_size = 201,
};

const DialogMode = enum {
    none,
    open,
    save_as,
    save_prompt,
    change_size,
    message,
};

const PendingAction = enum {
    none,
    new_file,
    open_dialog,
    exit_app,
};

const ResizeFocus = enum {
    width,
    height,
    ok,
    cancel,
};

const ImagePoint = struct {
    x: u32,
    y: u32,
};

const AppMenus = struct {
    file_items: [5]r4os.gui.MenuItem = undefined,
    edit_items: [1]r4os.gui.MenuItem = undefined,
    menus: [2]r4os.gui.MenubarMenu = undefined,
};

const App = struct {
    ctx: *AppApi = undefined,
    menubar_state: r4os.gui.MenubarState = .{},
    menu_storage: AppMenus = .{},
    dialog: DialogMode = .none,
    pending_action: PendingAction = .none,
    quit_requested: bool = false,
    dirty: bool = false,
    drawing: bool = false,
    hosted_w: i32 = 520,
    hosted_h: i32 = 360,
    tool: Tool = .pencil,
    image_w: u32 = default_image_w,
    image_h: u32 = default_image_h,
    last_x: i32 = -1,
    last_y: i32 = -1,
    dialog_selected_index: usize = 0,
    dialog_first_index: usize = 0,
    dialog_hover_index: ?usize = null,
    dialog_pressed_action: r4os.gui.DialogAction = .none,
    resize_focus: ResizeFocus = .width,
    message_kind: r4os.gui.MessageKind = .info,
    pixels: [r4os.raster.max_pixels]u32 = .{0} ** r4os.raster.max_pixels,
    file_buffer: [bmp_buffer_capacity]u8 = .{0} ** bmp_buffer_capacity,
    current_dir: [path_capacity]u8 = .{0} ** path_capacity,
    current_path: [path_capacity]u8 = .{0} ** path_capacity,
    selected_path: [path_capacity]u8 = .{0} ** path_capacity,
    save_file_name: [path_capacity]u8 = .{0} ** path_capacity,
    hosted_status: [status_capacity]u8 = .{0} ** status_capacity,
    message_title: [message_title_capacity]u8 = .{0} ** message_title_capacity,
    message_text: [message_text_capacity]u8 = .{0} ** message_text_capacity,
    dirbuf: [dir_buffer_capacity]u8 = .{0} ** dir_buffer_capacity,
    dir_items: [max_dir_items][dir_item_capacity]u8 = .{.{0} ** dir_item_capacity} ** max_dir_items,
    dir_item_slices: [max_dir_items][]const u8 = [_][]const u8{""} ** max_dir_items,
    dir_item_count: usize = 0,
    resize_width: SizeField = .{},
    resize_height: SizeField = .{},

    fn init(self: *App, ctx: *AppApi) void {
        self.ctx = ctx;
        setZ(self.current_dir[0..], "C:\\");
        setZ(self.save_file_name[0..], "UNTITLED.BMP");
        _ = self.resetImage(default_image_w, default_image_h, true, false);
        self.setStatus("Ready");
        self.openInitialArg();
    }

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        return self.runFullscreenFallback();
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Paint");
        _ = self.ctx.desk.guiSetMinSize(420, 300);
        self.updateHostedMetrics();
        self.renderHosted();

        while (!self.quit_requested) {
            if (self.ctx.sys.programShouldClose() and self.dialog == .none) {
                self.requestAction(.exit_app);
            }

            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                self.handleHostedEvent(event);
                if (self.quit_requested) break;
            }
            if (self.quit_requested) break;
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn runFullscreenFallback(self: *App) i32 {
        self.ctx.draw.clear(background_color);
        self.ctx.draw.text(8, 8, "R4OS Paint requires Desktop hosted GUI mode.", pencil_color, background_color);
        while (!self.quit_requested and !self.ctx.sys.programShouldClose()) {
            const key = self.ctx.desk.readKey();
            if (key == r4os.gui.Key.escape) break;
            if (key == 0) self.ctx.sys.taskYield();
        }
        return 0;
    }

    fn handleHostedEvent(self: *App, event: r4os.abi.GuiEvent) void {
        const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
        switch (kind) {
            .close => self.requestAction(.exit_app),
            .resize => {
                self.updateHostedMetrics();
                self.renderHosted();
            },
            .key_down => self.handleHostedKey(r4os.gui.eventKey(event)),
            .mouse_down => self.handleMouseDown(event.x, event.y),
            .mouse_up => self.handleMouseUp(event.x, event.y),
            .mouse_move => self.handleMouseMove(event.x, event.y, event.buttons),
            else => {},
        }
    }

    fn updateHostedMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.hosted_w = clampI32(canvas.w, 260, 1600);
        self.hosted_h = clampI32(canvas.h, 220, 1000);
    }

    fn handleHostedKey(self: *App, raw_key: u8) void {
        var key = raw_key;
        if (key == 0x85 or key == 0x86) key = r4os.gui.Key.menu_focus;

        if (self.dialog != .none) {
            self.handleDialogKey(key);
            self.renderHosted();
            return;
        }

        if (self.menubar_state.isOpen() or key == r4os.gui.Key.menu_focus or key == r4os.gui.Key.f10) {
            var menu_storage: AppMenus = undefined;
            const menus = buildAppMenus(&menu_storage);
            const result = self.menubar_state.keyAction(menus, key);
            if (result.hasCommand()) self.executeCommand(result.command_id);
            self.renderHosted();
            return;
        }

        if (self.handleCommandShortcut(key)) {
            self.renderHosted();
            return;
        }

        switch (key) {
            'p', 'P' => {
                self.tool = .pencil;
                self.setStatus("Pencil");
                self.renderHosted();
            },
            'e', 'E' => {
                self.tool = .eraser;
                self.setStatus("Eraser");
                self.renderHosted();
            },
            else => {},
        }
    }

    fn handleCommandShortcut(self: *App, key: u8) bool {
        switch (key) {
            ctrl_n => self.requestAction(.new_file),
            ctrl_o => self.requestAction(.open_dialog),
            ctrl_s => self.saveCurrentOrOpenSaveAs(),
            else => return false,
        }
        return true;
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        if (self.dialog != .none) {
            self.handleDialogMouseDown(x, y);
            self.renderHosted();
            return;
        }

        const canvas = self.appCanvas();
        var menu_storage: AppMenus = undefined;
        const menus = buildAppMenus(&menu_storage);
        const menu_result = self.menubar_state.mouseDown(self.menubarRect(canvas), menus, x, y);
        if (menu_result.action != .none or self.menubarRect(canvas).contains(x, y)) {
            self.renderHosted();
            return;
        }

        if (self.toolbarToolAt(x, y)) |tool| {
            self.tool = tool;
            self.setStatus(if (tool == .pencil) "Pencil" else "Eraser");
            self.renderHosted();
            return;
        }

        if (self.imagePointAt(x, y)) |point| {
            self.drawing = true;
            self.last_x = @intCast(point.x);
            self.last_y = @intCast(point.y);
            self.drawPoint(point);
            self.renderHosted();
        }
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.dialog != .none) {
            self.handleDialogMouseUp(x, y);
            self.renderHosted();
            return;
        }
        if (self.menubar_state.isOpen()) {
            var menu_storage: AppMenus = undefined;
            const menus = buildAppMenus(&menu_storage);
            const result = self.menubar_state.mouseUp(self.menubarRect(self.appCanvas()), menus, x, y);
            if (result.hasCommand()) self.executeCommand(result.command_id);
            self.renderHosted();
            return;
        }
        if (self.drawing) {
            if (self.imagePointAt(x, y)) |point| {
                self.drawLine(self.last_x, self.last_y, @intCast(point.x), @intCast(point.y));
            }
            self.drawing = false;
            self.last_x = -1;
            self.last_y = -1;
            self.renderHosted();
        }
    }

    fn handleMouseMove(self: *App, x: i32, y: i32, buttons: u32) void {
        if (self.dialog != .none) return;
        if (self.menubar_state.isOpen()) {
            var menu_storage: AppMenus = undefined;
            const menus = buildAppMenus(&menu_storage);
            _ = self.menubar_state.mouseMove(self.menubarRect(self.appCanvas()), menus, x, y);
            self.renderHosted();
            return;
        }
        if (!self.drawing) return;
        if ((buttons & 1) == 0) {
            self.drawing = false;
            return;
        }
        if (self.imagePointAt(x, y)) |point| {
            const px: i32 = @intCast(point.x);
            const py: i32 = @intCast(point.y);
            self.drawLine(self.last_x, self.last_y, px, py);
            self.last_x = px;
            self.last_y = py;
            self.renderHosted();
        }
    }

    fn executeCommand(self: *App, command_id: u32) void {
        self.menubar_state.close();
        switch (command_id) {
            @intFromEnum(Command.file_new) => self.requestAction(.new_file),
            @intFromEnum(Command.file_open) => self.requestAction(.open_dialog),
            @intFromEnum(Command.file_save) => self.saveCurrentOrOpenSaveAs(),
            @intFromEnum(Command.file_save_as) => self.openFileDialog(.save_as),
            @intFromEnum(Command.file_exit) => self.requestAction(.exit_app),
            @intFromEnum(Command.edit_change_size) => self.openSizeDialog(),
            else => {},
        }
    }

    fn requestAction(self: *App, action: PendingAction) void {
        if (self.dirty) {
            self.pending_action = action;
            self.dialog = .save_prompt;
            self.dialog_pressed_action = .none;
            self.setStatus("Unsaved changes");
            self.renderHosted();
            return;
        }
        self.performAction(action);
    }

    fn performAction(self: *App, action: PendingAction) void {
        switch (action) {
            .none => {},
            .new_file => self.newImage(),
            .open_dialog => self.openFileDialog(.open),
            .exit_app => self.quit_requested = true,
        }
    }

    fn newImage(self: *App) void {
        _ = self.resetImage(default_image_w, default_image_h, false, false);
        setZ(self.save_file_name[0..], "UNTITLED.BMP");
        self.pending_action = .none;
        self.dialog = .none;
        self.setStatus("New image");
    }

    fn resetImage(self: *App, width: u32, height: u32, keep_path: bool, mark_dirty: bool) bool {
        const image = r4os.raster.init(self.pixels[0..], width, height, background_color) catch {
            self.showMessage("Paint", "Image size must be 1..128.", .warning);
            return false;
        };
        self.image_w = image.width;
        self.image_h = image.height;
        if (!keep_path) zero(self.current_path[0..]);
        self.dirty = mark_dirty;
        self.drawing = false;
        return true;
    }

    fn openSizeDialog(self: *App) void {
        self.setResizeField(&self.resize_width, self.image_w);
        self.setResizeField(&self.resize_height, self.image_h);
        self.setResizeFocus(.width);
        self.dialog = .change_size;
        self.dialog_pressed_action = .none;
        self.setStatus("Change canvas size");
    }

    fn setResizeField(self: *App, field: *SizeField, value: u32) void {
        _ = self;
        var text: [8]u8 = .{0} ** 8;
        field.set(u32Text(text[0..], value));
        field.selectAll();
    }

    fn setResizeFocus(self: *App, focus: ResizeFocus) void {
        self.resize_focus = focus;
        self.resize_width.focused = focus == .width;
        self.resize_height.focused = focus == .height;
    }

    fn applyResizeDialog(self: *App) void {
        const width = parseDimension(self.resize_width.value()) orelse {
            self.setStatus("Width must be 1..128");
            return;
        };
        const height = parseDimension(self.resize_height.value()) orelse {
            self.setStatus("Height must be 1..128");
            return;
        };
        var image = self.imageView();
        image.resize(width, height, background_color) catch {
            self.setStatus("Size must be 1..128");
            return;
        };
        self.image_w = width;
        self.image_h = height;
        self.dirty = true;
        self.dialog = .none;
        self.setStatus("Canvas resized");
    }

    fn saveCurrentOrOpenSaveAs(self: *App) void {
        if (self.current_path[0] == 0) {
            self.openFileDialog(.save_as);
            return;
        }
        if (self.saveToCurrentPath()) {
            const pending = self.pending_action;
            self.pending_action = .none;
            self.performAction(pending);
        }
    }

    fn saveToCurrentPath(self: *App) bool {
        return self.saveToPath(self.current_path[0..]);
    }

    fn saveToPath(self: *App, path_buffer: []const u8) bool {
        var path_copy: [path_capacity]u8 = .{0} ** path_capacity;
        copyZ(path_copy[0..], path_buffer);
        const image = self.imageView();
        const encoded_len = bmp_writer.encode(image, self.file_buffer[0..], .bpp24) catch |err| {
            self.showMessage("Save failed", bmpWriterErrorText(err), .warning);
            return false;
        };
        const written = self.ctx.sys.fileWrite(zptr(path_copy[0..]), self.file_buffer[0..encoded_len]);
        if (written < 0 or @as(usize, @intCast(written)) != encoded_len) {
            self.showMessage("Save failed", "Could not write BMP file.", .warning);
            return false;
        }
        copyZ(self.current_path[0..], path_copy[0..]);
        self.setDirFromPath(spanZ(self.current_path[0..]));
        setZ(self.save_file_name[0..], baseName(spanZ(self.current_path[0..])));
        self.dirty = false;
        self.setStatus("Saved BMP");
        self.noteRecentDocument();
        return true;
    }

    fn openFileDialog(self: *App, mode: DialogMode) void {
        if (mode == .save_as) {
            if (self.current_path[0] != 0) {
                setZ(self.save_file_name[0..], baseName(spanZ(self.current_path[0..])));
            } else if (self.save_file_name[0] == 0) {
                setZ(self.save_file_name[0..], "UNTITLED.BMP");
            }
        }

        if (!self.loadDirectory()) {
            self.showMessage("Paint", "Directory read failed.", .warning);
            return;
        }
        self.dialog = mode;
        self.dialog_selected_index = 0;
        self.dialog_first_index = 0;
        self.dialog_hover_index = null;
        self.dialog_pressed_action = .none;
        self.setStatus(if (mode == .save_as) "Choose BMP name" else "Choose BMP file");
    }

    fn loadDirectory(self: *App) bool {
        zero(self.dirbuf[0..]);
        self.dir_item_count = 0;
        const read = self.ctx.sys.dirList(zptr(self.current_dir[0..]), self.dirbuf[0 .. self.dirbuf.len - 1]);
        if (read < 0) return false;
        const len: usize = @intCast(read);
        if (len < self.dirbuf.len) self.dirbuf[len] = 0;
        self.parseDirectoryItems(self.dirbuf[0..@min(len, self.dirbuf.len - 1)]);
        return true;
    }

    fn parseDirectoryItems(self: *App, data: []const u8) void {
        var start: usize = 0;
        var i: usize = 0;
        while (i <= data.len) : (i += 1) {
            if (i == data.len or data[i] == '\n') {
                var end = i;
                while (end > start and (data[end - 1] == '\r' or data[end - 1] == '\n')) end -= 1;
                if (end > start) self.addDirItem(data[start..end]);
                start = i + 1;
            }
        }
    }

    fn addDirItem(self: *App, text: []const u8) void {
        if (self.dir_item_count >= max_dir_items) return;
        const index = self.dir_item_count;
        zero(self.dir_items[index][0..]);
        const len = @min(text.len, dir_item_capacity - 1);
        if (len > 0) @memcpy(self.dir_items[index][0..len], text[0..len]);
        self.dir_items[index][len] = 0;
        self.dir_item_slices[index] = self.dir_items[index][0..len];
        self.dir_item_count += 1;
    }

    fn handleDialogKey(self: *App, key: u8) void {
        switch (self.dialog) {
            .save_prompt => self.handleSavePromptAction(self.savePromptKeyAction(key)),
            .open, .save_as => self.handleFileDialogKey(key),
            .change_size => self.handleSizeDialogKey(key),
            .message => self.handleMessageAction(self.messageDialog().keyAction(key)),
            .none => {},
        }
    }

    fn handleFileDialogKey(self: *App, key: u8) void {
        if (key == r4os.gui.Key.escape) {
            self.closeDialog("Cancelled");
            return;
        }
        if (self.dialog == .save_as and key == r4os.gui.Key.backspace) {
            backspaceZ(self.save_file_name[0..], 0);
            return;
        }
        if (self.dialog == .save_as and isFileNameChar(key)) {
            appendZChar(self.save_file_name[0..], key);
            return;
        }

        const dialog = self.fileDialog();
        switch (dialog.keyAction(key)) {
            .ok => self.fileDialogOk(),
            .cancel => self.closeDialog("Cancelled"),
            .previous, .next => |action| {
                self.dialog_selected_index = dialog.selectedIndexForAction(action);
                self.dialog_first_index = self.fileDialog().firstIndexForSelection();
            },
            else => {},
        }
    }

    fn handleSizeDialogKey(self: *App, key: u8) void {
        if (key == r4os.gui.Key.escape) {
            self.closeDialog("Cancelled");
            return;
        }
        if (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab) {
            self.stepResizeFocus(if (key == r4os.gui.Key.shift_tab) -1 else 1);
            return;
        }
        if (key == r4os.gui.Key.enter) {
            if (self.resize_focus == .cancel) {
                self.closeDialog("Cancelled");
            } else {
                self.applyResizeDialog();
            }
            return;
        }
        if (key == ' ' and self.resize_focus == .ok) {
            self.applyResizeDialog();
            return;
        }
        if (key == ' ' and self.resize_focus == .cancel) {
            self.closeDialog("Cancelled");
            return;
        }
        if (self.resize_focus == .width or self.resize_focus == .height) {
            if (!isSizeFieldKey(key)) return;
            const field = if (self.resize_focus == .width) &self.resize_width else &self.resize_height;
            _ = field.handleKey(key);
        }
    }

    fn stepResizeFocus(self: *App, direction: i32) void {
        const index: i32 = switch (self.resize_focus) {
            .width => 0,
            .height => 1,
            .ok => 2,
            .cancel => 3,
        };
        var next = index + direction;
        if (next < 0) next = 3;
        if (next > 3) next = 0;
        self.setResizeFocus(switch (next) {
            0 => .width,
            1 => .height,
            2 => .ok,
            else => .cancel,
        });
    }

    fn handleDialogMouseDown(self: *App, x: i32, y: i32) void {
        switch (self.dialog) {
            .save_prompt => self.dialog_pressed_action = self.savePromptActionAt(x, y),
            .open, .save_as => self.handleFileDialogMouseDown(x, y),
            .change_size => self.handleSizeDialogMouseDown(x, y),
            .message => self.dialog_pressed_action = self.messageDialog().actionAt(x, y),
            .none => {},
        }
    }

    fn handleDialogMouseUp(self: *App, x: i32, y: i32) void {
        switch (self.dialog) {
            .save_prompt => {
                const action = self.savePromptActionAt(x, y);
                const pressed = self.dialog_pressed_action;
                self.dialog_pressed_action = .none;
                if (action == pressed) self.handleSavePromptAction(action);
            },
            .open, .save_as => self.handleFileDialogMouseUp(x, y),
            .change_size => self.handleSizeDialogMouseUp(x, y),
            .message => {
                const action = self.messageDialog().actionAt(x, y);
                const pressed = self.dialog_pressed_action;
                self.dialog_pressed_action = .none;
                if (action == pressed) self.handleMessageAction(action);
            },
            .none => {},
        }
    }

    fn handleFileDialogMouseDown(self: *App, x: i32, y: i32) void {
        const dialog = self.fileDialog();
        const action = dialog.actionAt(x, y);
        if (action == .select) {
            if (dialog.indexAt(x, y)) |index| {
                self.dialog_selected_index = index;
                self.dialog_first_index = self.fileDialog().firstIndexForSelection();
                self.selectDirEntry(index);
            }
            return;
        }
        self.dialog_pressed_action = action;
    }

    fn handleFileDialogMouseUp(self: *App, x: i32, y: i32) void {
        const dialog = self.fileDialog();
        const action = dialog.actionAt(x, y);
        const pressed = self.dialog_pressed_action;
        self.dialog_pressed_action = .none;
        if (action != pressed) return;
        switch (action) {
            .ok => self.fileDialogOk(),
            .cancel => self.closeDialog("Cancelled"),
            else => {},
        }
    }

    fn handleSizeDialogMouseDown(self: *App, x: i32, y: i32) void {
        if (self.resizeWidthRect().contains(x, y)) {
            self.setResizeFocus(.width);
            return;
        }
        if (self.resizeHeightRect().contains(x, y)) {
            self.setResizeFocus(.height);
            return;
        }
        var button_storage: [2]r4os.gui.DialogButton = undefined;
        const action = r4os.gui.dialogButtonActionAt(self.sizeDialogRect(), self.sizeDialogButtons(&button_storage), .right, x, y);
        self.dialog_pressed_action = action;
        if (action == .ok) self.setResizeFocus(.ok);
        if (action == .cancel) self.setResizeFocus(.cancel);
    }

    fn handleSizeDialogMouseUp(self: *App, x: i32, y: i32) void {
        var button_storage: [2]r4os.gui.DialogButton = undefined;
        const action = r4os.gui.dialogButtonActionAt(self.sizeDialogRect(), self.sizeDialogButtons(&button_storage), .right, x, y);
        const pressed = self.dialog_pressed_action;
        self.dialog_pressed_action = .none;
        if (action != pressed) return;
        switch (action) {
            .ok => self.applyResizeDialog(),
            .cancel => self.closeDialog("Cancelled"),
            else => {},
        }
    }

    fn handleMessageAction(self: *App, action: r4os.gui.DialogAction) void {
        switch (action) {
            .ok, .cancel, .yes, .no => self.closeDialog("Ready"),
            else => {},
        }
    }

    fn selectDirEntry(self: *App, index: usize) void {
        const kind = self.resolveDirEntry(index);
        if (kind < 0) {
            self.setStatus("Selection failed");
            return;
        }
        if (kind > 0) {
            copyZ(self.current_dir[0..], self.selected_path[0..]);
            if (self.loadDirectory()) {
                self.dialog_selected_index = 0;
                self.dialog_first_index = 0;
                self.setStatus("Opened folder");
            } else {
                self.setStatus("Directory read failed");
            }
            return;
        }
        if (self.dialog == .save_as) setZ(self.save_file_name[0..], baseName(spanZ(self.selected_path[0..])));
        self.setStatus("Selected file");
    }

    fn resolveDirEntry(self: *App, index: usize) i32 {
        if (index >= self.dir_item_count) return -1;
        zero(self.selected_path[0..]);
        const kind = self.ctx.sys.dirEntry(zptr(self.current_dir[0..]), @intCast(index), self.selected_path[0 .. self.selected_path.len - 1]);
        self.selected_path[self.selected_path.len - 1] = 0;
        return kind;
    }

    fn fileDialogOk(self: *App) void {
        if (self.dialog == .save_as) {
            self.saveFromDialog();
            return;
        }
        self.openFromDialog();
    }

    fn openFromDialog(self: *App) void {
        const kind = self.resolveDirEntry(self.dialog_selected_index);
        if (kind < 0) {
            self.setStatus("Selection failed");
            return;
        }
        if (kind > 0) {
            self.selectDirEntry(self.dialog_selected_index);
            return;
        }
        if (self.loadBmp(self.selected_path[0..])) {
            self.dialog = .none;
            self.pending_action = .none;
        }
    }

    fn saveFromDialog(self: *App) void {
        if (spanZ(self.save_file_name[0..]).len == 0) {
            self.setStatus("Enter a file name");
            return;
        }
        var normalized_name: [path_capacity]u8 = .{0} ** path_capacity;
        copyZ(normalized_name[0..], self.save_file_name[0..]);
        ensureBmpExtension(normalized_name[0..]);
        if (!buildPath(self.current_dir[0..], normalized_name[0..], self.selected_path[0..])) {
            self.setStatus("Path too long");
            return;
        }
        if (!self.saveToPath(self.selected_path[0..])) return;
        self.dialog = .none;
        const action = self.pending_action;
        self.pending_action = .none;
        self.performAction(action);
    }

    fn loadBmp(self: *App, path_buffer: []const u8) bool {
        var path_copy: [path_capacity]u8 = .{0} ** path_capacity;
        copyZ(path_copy[0..], path_buffer);
        if (self.ctx.sys.fileInfo(zptr(path_copy[0..]))) |info| {
            if (info.size > self.file_buffer.len) {
                self.showMessage("Open failed", "BMP file is too large for Paint.", .warning);
                return false;
            }
        }
        const read = self.ctx.sys.fileRead(zptr(path_copy[0..]), self.file_buffer[0..]);
        if (read < 0) {
            self.showMessage("Open failed", "Could not read BMP file.", .warning);
            return false;
        }
        const len: usize = @intCast(read);
        const info = self.ctx.img.probe(self.file_buffer[0..len], "image/bmp") catch |err| {
            self.showMessage("Open failed", imageErrorText(err), .warning);
            return false;
        };
        if (info.format != .bmp) {
            self.showMessage("Open failed", "File is not a BMP image.", .warning);
            return false;
        }
        _ = r4os.raster.requiredPixels(info.width, info.height) catch {
            self.showMessage("Open failed", "BMP must fit within 128x128 pixels.", .warning);
            return false;
        };
        const scratch_bytes = self.ctx.img.scratchBytesFor(info, len) catch |err| {
            self.showMessage("Open failed", imageErrorText(err), .warning);
            return false;
        };
        const allocator = self.ctx.sys.allocator();
        const scratch = allocator.alloc(u8, scratch_bytes) catch {
            self.showMessage("Open failed", "Not enough memory to decode BMP.", .warning);
            return false;
        };
        defer allocator.free(scratch);
        const image = self.ctx.img.decode(self.file_buffer[0..len], "image/bmp", self.pixels[0..], scratch) catch |err| {
            self.showMessage("Open failed", imageErrorText(err), .warning);
            return false;
        };
        self.image_w = image.info.width;
        self.image_h = image.info.height;
        copyZ(self.current_path[0..], path_copy[0..]);
        self.setDirFromPath(spanZ(self.current_path[0..]));
        setZ(self.save_file_name[0..], baseName(spanZ(self.current_path[0..])));
        self.dirty = false;
        self.drawing = false;
        self.setStatus("Opened BMP");
        self.noteRecentDocument();
        return true;
    }

    fn noteRecentDocument(self: *App) void {
        if (self.current_path[0] == 0) return;
        _ = r4os.recent_documents.addOpenedFile(&self.ctx.sys, spanZ(self.current_path[0..]), "Paint");
    }

    fn closeDialog(self: *App, status: []const u8) void {
        self.dialog = .none;
        self.pending_action = .none;
        self.dialog_pressed_action = .none;
        self.setStatus(status);
    }

    fn savePromptKeyAction(self: *App, key: u8) r4os.gui.DialogAction {
        if (key == 'd' or key == 'D' or key == 'n' or key == 'N') return .no;
        var button_storage: [3]r4os.gui.DialogButton = undefined;
        const buttons = self.savePromptButtons(&button_storage);
        return r4os.gui.dialogKeyAction(buttons, .ok, key);
    }

    fn handleSavePromptAction(self: *App, action: r4os.gui.DialogAction) void {
        switch (action) {
            .ok => {
                self.dialog = .none;
                self.saveCurrentOrOpenSaveAs();
            },
            .no => {
                const pending = self.pending_action;
                self.pending_action = .none;
                self.dialog = .none;
                self.dirty = false;
                self.performAction(pending);
            },
            .cancel => self.closeDialog("Cancelled"),
            else => {},
        }
    }

    fn showMessage(self: *App, title: []const u8, message: []const u8, kind: r4os.gui.MessageKind) void {
        setZ(self.message_title[0..], title);
        setZ(self.message_text[0..], message);
        self.message_kind = kind;
        self.pending_action = .none;
        self.dialog = .message;
        self.dialog_pressed_action = .none;
        self.setStatus(message);
    }

    fn openInitialArg(self: *App) void {
        const raw = self.ctx.sys.argsRaw();
        if (raw[0] == 0) return;
        copyZPtr(self.selected_path[0..], raw);
        _ = self.loadBmp(self.selected_path[0..]);
    }

    fn renderHosted(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.hosted_w, self.hosted_h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [scratch_capacity]u8 = .{0} ** scratch_capacity;
        _ = canvas.clear(r4os.gui.default_palette.face);
        self.renderToolbar(canvas, scratch[0..]);
        self.renderWorkArea(canvas);
        self.renderStatus(canvas, scratch[0..]);
        _ = canvas.menubar(self.menubar(), scratch[0..]);
        self.renderDialog(canvas, scratch[0..]);
        _ = paint.present();
    }

    fn renderToolbar(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.toolbarRect(canvas);
        _ = canvas.rect(rect, r4os.gui.default_palette.face);
        _ = canvas.rect(.{ .x = rect.x, .y = rect.bottom() - 1, .w = rect.w, .h = 1 }, r4os.gui.default_palette.face_shadow);
        _ = canvas.toolbarButton(self.toolbarButton(.pencil), scratch);
        _ = canvas.toolbarButton(self.toolbarButton(.eraser), scratch);
    }

    fn renderWorkArea(self: *App, canvas: r4os.gui.Canvas) void {
        const area = self.workRect(canvas);
        _ = canvas.rect(area, work_bg);
        const image_rect = self.imageRect(canvas);
        _ = canvas.rect(.{ .x = image_rect.x - 1, .y = image_rect.y - 1, .w = image_rect.w + 2, .h = image_rect.h + 2 }, r4os.gui.default_palette.face_shadow);
        _ = canvas.raster(image_rect.x, image_rect.y, self.image_w, self.image_h, self.imageScale(canvas), self.imagePixelsConst());
    }

    fn renderStatus(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.statusRect(canvas);
        _ = canvas.rect(rect, r4os.gui.default_palette.face);
        _ = canvas.rect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, r4os.gui.default_palette.face_shadow);
        const status_text = if (self.hosted_status[0] != 0) spanZ(self.hosted_status[0..]) else "Ready";
        _ = r4os.gui.drawTextInRect(canvas, rect.inset(6, 2), scratch, status_text, .left, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
        var marker: [96]u8 = .{0} ** 96;
        self.formatStatusMarker(marker[0..]);
        _ = r4os.gui.drawTextInRect(canvas, rect.inset(6, 2), scratch, spanZ(marker[0..]), .right, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
    }

    fn renderDialog(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        switch (self.dialog) {
            .none => {},
            .open, .save_as => _ = canvas.fileDialog(self.fileDialog(), scratch),
            .save_prompt => self.drawSavePrompt(canvas, scratch),
            .change_size => self.drawSizeDialog(canvas, scratch),
            .message => _ = canvas.messageDialog(self.messageDialog(), scratch),
        }
    }

    fn drawSavePrompt(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.savePromptRect();
        var button_storage: [3]r4os.gui.DialogButton = undefined;
        _ = r4os.gui.drawDialogFrame(canvas, rect, scratch, "Paint", r4os.gui.default_palette);
        _ = r4os.gui.drawTextInRect(canvas, rect.inset(12, 34), scratch, "Save changes to this image?", .left, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
        _ = r4os.gui.drawDialogButtons(canvas, rect, scratch, self.savePromptButtons(&button_storage), .ok, self.dialog_pressed_action, .right, r4os.gui.default_palette);
    }

    fn drawSizeDialog(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.sizeDialogRect();
        _ = r4os.gui.drawDialogFrame(canvas, rect, scratch, "Change Size", r4os.gui.default_palette);
        _ = r4os.gui.drawTextInRect(canvas, .{ .x = rect.x + 18, .y = rect.y + 38, .w = 72, .h = 18 }, scratch, "Width", .left, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
        _ = r4os.gui.drawTextInRect(canvas, .{ .x = rect.x + 18, .y = rect.y + 70, .w = 72, .h = 18 }, scratch, "Height", .left, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
        _ = self.resize_width.draw(canvas, self.resizeWidthRect(), scratch);
        _ = self.resize_height.draw(canvas, self.resizeHeightRect(), scratch);
        _ = r4os.gui.drawTextInRect(canvas, .{ .x = rect.x + 160, .y = rect.y + 38, .w = @max(0, rect.w - 176), .h = 50 }, scratch, "1..128 pixels", .left, r4os.gui.default_palette.disabled_text, r4os.gui.default_palette.face);
        const focus_action: r4os.gui.DialogAction = switch (self.resize_focus) {
            .ok => .ok,
            .cancel => .cancel,
            else => .none,
        };
        var button_storage: [2]r4os.gui.DialogButton = undefined;
        _ = r4os.gui.drawDialogButtons(canvas, rect, scratch, self.sizeDialogButtons(&button_storage), focus_action, self.dialog_pressed_action, .right, r4os.gui.default_palette);
    }

    fn appCanvas(self: *App) r4os.gui.Canvas {
        return r4os.gui.Canvas.initSize(&self.ctx.draw, self.hosted_w, self.hosted_h);
    }

    fn menubar(self: *App) r4os.gui.Menubar {
        const menus = buildAppMenus(&self.menu_storage);
        return .{
            .rect = self.menubarRect(self.appCanvas()),
            .menus = menus,
            .state = self.menubar_state,
        };
    }

    fn menubarRect(self: *App, canvas: r4os.gui.Canvas) r4os.gui.Rect {
        _ = self;
        return .{ .x = 0, .y = 0, .w = canvas.w, .h = r4os.gui.default_metrics.menu_bar_h };
    }

    fn toolbarRect(self: *App, canvas: r4os.gui.Canvas) r4os.gui.Rect {
        _ = self;
        return .{ .x = 0, .y = r4os.gui.default_metrics.menu_bar_h, .w = canvas.w, .h = toolbar_h };
    }

    fn workRect(self: *App, canvas: r4os.gui.Canvas) r4os.gui.Rect {
        _ = self;
        return .{
            .x = 0,
            .y = r4os.gui.default_metrics.menu_bar_h + toolbar_h,
            .w = canvas.w,
            .h = @max(0, canvas.h - r4os.gui.default_metrics.menu_bar_h - toolbar_h - status_h),
        };
    }

    fn statusRect(self: *App, canvas: r4os.gui.Canvas) r4os.gui.Rect {
        _ = self;
        return .{ .x = 0, .y = @max(0, canvas.h - status_h), .w = canvas.w, .h = status_h };
    }

    fn paintClientRect(self: *App, canvas: r4os.gui.Canvas) r4os.gui.Rect {
        return self.workRect(canvas).inset(10, 10);
    }

    fn imageScale(self: *App, canvas: r4os.gui.Canvas) u32 {
        const client = self.paintClientRect(canvas);
        const iw: i32 = @intCast(self.image_w);
        const ih: i32 = @intCast(self.image_h);
        if (iw <= 0 or ih <= 0) return 1;
        const scale_x = @max(1, @divTrunc(@max(1, client.w - 2), iw));
        const scale_y = @max(1, @divTrunc(@max(1, client.h - 2), ih));
        return @intCast(clampI32(@min(scale_x, scale_y), 1, 8));
    }

    fn imageRect(self: *App, canvas: r4os.gui.Canvas) r4os.gui.Rect {
        const client = self.paintClientRect(canvas);
        const scale: i32 = @intCast(self.imageScale(canvas));
        return .{
            .x = client.x + 1,
            .y = client.y + 1,
            .w = @as(i32, @intCast(self.image_w)) * scale,
            .h = @as(i32, @intCast(self.image_h)) * scale,
        };
    }

    fn imagePointAt(self: *App, x: i32, y: i32) ?ImagePoint {
        const canvas = self.appCanvas();
        const rect = self.imageRect(canvas);
        if (!rect.contains(x, y)) return null;
        const scale: i32 = @intCast(self.imageScale(canvas));
        if (scale <= 0) return null;
        const px = @divTrunc(x - rect.x, scale);
        const py = @divTrunc(y - rect.y, scale);
        if (px < 0 or py < 0) return null;
        if (px >= @as(i32, @intCast(self.image_w)) or py >= @as(i32, @intCast(self.image_h))) return null;
        return .{ .x = @intCast(px), .y = @intCast(py) };
    }

    fn toolbarButton(self: *App, tool: Tool) r4os.gui.ToolbarButton {
        return .{
            .rect = self.toolbarButtonRect(tool),
            .text = if (tool == .pencil) "Pencil" else "Eraser",
            .selected = self.tool == tool,
        };
    }

    fn toolbarButtonRect(self: *App, tool: Tool) r4os.gui.Rect {
        _ = self;
        const index: i32 = if (tool == .pencil) 0 else 1;
        return .{ .x = 6 + index * 66, .y = r4os.gui.default_metrics.menu_bar_h + 5, .w = 62, .h = 24 };
    }

    fn toolbarToolAt(self: *App, x: i32, y: i32) ?Tool {
        if (self.toolbarButtonRect(.pencil).contains(x, y)) return .pencil;
        if (self.toolbarButtonRect(.eraser).contains(x, y)) return .eraser;
        return null;
    }

    fn fileDialog(self: *App) r4os.gui.FileDialog {
        const mode: r4os.gui.FileDialogMode = if (self.dialog == .save_as) .save else .open;
        return .{
            .rect = self.fileDialogRect(),
            .title = if (mode == .save) "Save As" else "Open",
            .path = spanZ(self.current_dir[0..]),
            .items = self.dir_item_slices[0..self.dir_item_count],
            .mode = mode,
            .file_name = if (mode == .save) spanZ(self.save_file_name[0..]) else "",
            .ok_text = if (mode == .save) "Save" else "Open",
            .cancel_text = "Cancel",
            .selected_index = @min(self.dialog_selected_index, if (self.dir_item_count == 0) 0 else self.dir_item_count - 1),
            .hover_index = self.dialog_hover_index,
            .first_index = self.dialog_first_index,
            .focus_action = .select,
            .pressed_action = self.dialog_pressed_action,
        };
    }

    fn messageDialog(self: *App) r4os.gui.MessageDialog {
        return .{
            .rect = self.messageDialogRect(),
            .title = spanZ(self.message_title[0..]),
            .message = spanZ(self.message_text[0..]),
            .kind = self.message_kind,
            .buttons = .ok,
            .ok_text = "OK",
            .cancel_text = "Cancel",
            .yes_text = "Yes",
            .no_text = "No",
            .pressed_action = self.dialog_pressed_action,
        };
    }

    fn fileDialogRect(self: *App) r4os.gui.Rect {
        const canvas = self.appCanvas();
        const width = @min(520, @max(300, canvas.w - 24));
        const height = @min(340, @max(220, canvas.h - 36));
        return r4os.gui.centeredRect(canvas.bounds(), width, height);
    }

    fn savePromptRect(self: *App) r4os.gui.Rect {
        return r4os.gui.centeredRect(self.appCanvas().bounds(), @min(360, @max(260, self.hosted_w - 40)), 116);
    }

    fn sizeDialogRect(self: *App) r4os.gui.Rect {
        return r4os.gui.centeredRect(self.appCanvas().bounds(), @min(380, @max(280, self.hosted_w - 40)), 150);
    }

    fn messageDialogRect(self: *App) r4os.gui.Rect {
        return r4os.gui.centeredRect(self.appCanvas().bounds(), @min(380, @max(260, self.hosted_w - 40)), 124);
    }

    fn resizeWidthRect(self: *App) r4os.gui.Rect {
        const rect = self.sizeDialogRect();
        return .{ .x = rect.x + 86, .y = rect.y + 34, .w = 58, .h = 22 };
    }

    fn resizeHeightRect(self: *App) r4os.gui.Rect {
        const rect = self.sizeDialogRect();
        return .{ .x = rect.x + 86, .y = rect.y + 66, .w = 58, .h = 22 };
    }

    fn savePromptButtons(self: *App, out: *[3]r4os.gui.DialogButton) []const r4os.gui.DialogButton {
        _ = self;
        out.* = .{
            .{ .action = .ok, .text = "Save", .role = .default },
            .{ .action = .no, .text = "Don't Save" },
            .{ .action = .cancel, .text = "Cancel", .role = .cancel },
        };
        return out[0..];
    }

    fn sizeDialogButtons(self: *App, out: *[2]r4os.gui.DialogButton) []const r4os.gui.DialogButton {
        _ = self;
        out.* = .{
            .{ .action = .ok, .text = "OK", .role = .default },
            .{ .action = .cancel, .text = "Cancel", .role = .cancel },
        };
        return out[0..];
    }

    fn savePromptActionAt(self: *App, x: i32, y: i32) r4os.gui.DialogAction {
        var button_storage: [3]r4os.gui.DialogButton = undefined;
        return r4os.gui.dialogButtonActionAt(self.savePromptRect(), self.savePromptButtons(&button_storage), .right, x, y);
    }

    fn imageView(self: *App) r4os.raster.Image {
        return .{ .width = self.image_w, .height = self.image_h, .storage = self.pixels[0..] };
    }

    fn imagePixelsConst(self: *App) []const u32 {
        return self.pixels[0..imagePixelCount(self.image_w, self.image_h)];
    }

    fn drawPoint(self: *App, point: ImagePoint) void {
        const color = if (self.tool == .pencil) pencil_color else background_color;
        const image = self.imageView();
        if (image.setPixel(point.x, point.y, color)) {
            self.dirty = true;
            self.setStatus(if (self.tool == .pencil) "Drawing" else "Erasing");
        }
    }

    fn drawLine(self: *App, x0_raw: i32, y0_raw: i32, x1: i32, y1: i32) void {
        if (x0_raw < 0 or y0_raw < 0) return;
        var x0 = x0_raw;
        var y0 = y0_raw;
        const dx = absI32(x1 - x0);
        const sx: i32 = if (x0 < x1) 1 else -1;
        const dy = -absI32(y1 - y0);
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        while (true) {
            if (x0 >= 0 and y0 >= 0 and x0 < @as(i32, @intCast(self.image_w)) and y0 < @as(i32, @intCast(self.image_h))) {
                self.drawPoint(.{ .x = @intCast(x0), .y = @intCast(y0) });
            }
            if (x0 == x1 and y0 == y1) break;
            const e2 = err * 2;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    fn setDirFromPath(self: *App, path: []const u8) void {
        var last_sep: ?usize = null;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '\\' or path[i] == '/') last_sep = i;
        }
        if (last_sep) |sep| {
            setZ(self.current_dir[0..], path[0 .. sep + 1]);
        } else {
            setZ(self.current_dir[0..], "C:\\");
        }
    }

    fn setStatus(self: *App, message: []const u8) void {
        setZ(self.hosted_status[0..], message);
    }

    fn formatStatusMarker(self: *App, out: []u8) void {
        zero(out);
        if (self.dirty) appendSliceZ(out, "Modified ");
        appendU32Z(out, self.image_w);
        appendZChar(out, 'x');
        appendU32Z(out, self.image_h);
        if (!self.dirty and self.current_path[0] != 0) {
            appendSliceZ(out, " ");
            appendSliceZ(out, baseName(spanZ(self.current_path[0..])));
        }
    }
};

fn buildAppMenus(out: *AppMenus) []const r4os.gui.MenubarMenu {
    out.file_items = .{
        .{ .text = "New", .id = @intFromEnum(Command.file_new), .shortcut = "Ctrl+N" },
        .{ .text = "Open", .id = @intFromEnum(Command.file_open), .shortcut = "Ctrl+O" },
        .{ .text = "Save", .id = @intFromEnum(Command.file_save), .shortcut = "Ctrl+S" },
        .{ .text = "Save As", .id = @intFromEnum(Command.file_save_as) },
        .{ .text = "Exit", .id = @intFromEnum(Command.file_exit), .separator_before = true },
    };
    out.edit_items = .{
        .{ .text = "Change Size", .id = @intFromEnum(Command.edit_change_size) },
    };
    out.menus = .{
        .{ .text = "File", .items = out.file_items[0..] },
        .{ .text = "Edit", .items = out.edit_items[0..] },
    };
    return out.menus[0..];
}

var app_state: App = .{};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    app_state = .{};
    app_state.init(&ctx);
    return app_state.run();
}

fn zptr(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

fn zero(buffer: []u8) void {
    @memset(buffer, 0);
}

fn setZ(buffer: []u8, text: []const u8) void {
    zero(buffer);
    if (buffer.len == 0) return;
    const len = @min(buffer.len - 1, text.len);
    if (len > 0) @memcpy(buffer[0..len], text[0..len]);
    buffer[len] = 0;
}

fn copyZ(dest: []u8, source: []const u8) void {
    setZ(dest, spanZ(source));
}

fn copyZPtr(dest: []u8, source: [*:0]const u8) void {
    zero(dest);
    var i: usize = 0;
    while (i + 1 < dest.len and source[i] != 0) : (i += 1) dest[i] = source[i];
    if (dest.len > 0) dest[i] = 0;
}

fn appendSliceZ(buffer: []u8, text: []const u8) void {
    var len = zlen(buffer);
    var i: usize = 0;
    while (len + 1 < buffer.len and i < text.len) : ({
        len += 1;
        i += 1;
    }) {
        buffer[len] = text[i];
    }
    if (len < buffer.len) buffer[len] = 0;
}

fn appendZChar(buffer: []u8, ch: u8) void {
    const len = zlen(buffer);
    if (len + 1 >= buffer.len) return;
    buffer[len] = ch;
    buffer[len + 1] = 0;
}

fn appendU32Z(buffer: []u8, value: u32) void {
    var text: [12]u8 = .{0} ** 12;
    appendSliceZ(buffer, u32Text(text[0..], value));
}

fn backspaceZ(buffer: []u8, min_len: usize) void {
    const len = zlen(buffer);
    if (len <= min_len) return;
    buffer[len - 1] = 0;
}

fn zlen(buffer: []const u8) usize {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return len;
}

fn spanZ(buffer: []const u8) []const u8 {
    return buffer[0..zlen(buffer)];
}

fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') start = i + 1;
    }
    return path[start..];
}

fn buildPath(dir_buffer: []const u8, name_buffer: []const u8, out: []u8) bool {
    const dir = spanZ(dir_buffer);
    const name = spanZ(name_buffer);
    if (name.len == 0 or out.len == 0) return false;
    zero(out);
    if (isAbsolutePath(name)) {
        if (name.len + 1 > out.len) return false;
        @memcpy(out[0..name.len], name);
        out[name.len] = 0;
        return true;
    }
    var len: usize = @min(dir.len, out.len - 1);
    if (len > 0) @memcpy(out[0..len], dir[0..len]);
    if (len > 0 and out[len - 1] != '\\' and out[len - 1] != '/') {
        if (len + 1 >= out.len) return false;
        out[len] = '\\';
        len += 1;
    }
    if (len + name.len + 1 > out.len) return false;
    @memcpy(out[len .. len + name.len], name);
    out[len + name.len] = 0;
    return true;
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 2 and path[1] == ':') return true;
    return path.len > 0 and (path[0] == '\\' or path[0] == '/');
}

fn isFileNameChar(ch: u8) bool {
    if (ch < 0x20 or ch >= 0x7F) return false;
    return ch != '\\' and ch != '/' and ch != ':' and ch != '*' and ch != '?' and ch != '"' and ch != '<' and ch != '>' and ch != '|';
}

fn isSizeFieldKey(key: u8) bool {
    if (key >= '0' and key <= '9') return true;
    return key == r4os.gui.Key.backspace or key == r4os.gui.Key.delete or key == r4os.gui.Key.left or key == r4os.gui.Key.right or key == r4os.gui.Key.home or key == r4os.gui.Key.end or key == r4os.gui.Key.ctrl_a;
}

fn parseDimension(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    var value: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + @as(u32, ch - '0');
        if (value > r4os.raster.max_width) return null;
    }
    if (value == 0 or value > r4os.raster.max_width) return null;
    return value;
}

fn ensureBmpExtension(buffer: []u8) void {
    const path = spanZ(buffer);
    const name = baseName(path);
    var has_dot = false;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '.') has_dot = true;
    }
    if (!has_dot) appendSliceZ(buffer, ".BMP");
}

fn imagePixelCount(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height);
}

fn u32Text(buffer: []u8, value: u32) []const u8 {
    zero(buffer);
    if (buffer.len == 0) return buffer[0..0];
    if (value == 0) {
        buffer[0] = '0';
        if (buffer.len > 1) buffer[1] = 0;
        return buffer[0..1];
    }
    var tmp: [12]u8 = .{0} ** 12;
    var count: usize = 0;
    var remaining = value;
    while (remaining > 0 and count < tmp.len) : (count += 1) {
        tmp[count] = @intCast('0' + remaining % 10);
        remaining /= 10;
    }
    const len = @min(count, buffer.len - 1);
    var i: usize = 0;
    while (i < len) : (i += 1) buffer[i] = tmp[count - 1 - i];
    buffer[len] = 0;
    return buffer[0..len];
}

fn bmpWriterErrorText(err: bmp_writer.Error) []const u8 {
    return switch (err) {
        error.InvalidDimensions => "BMP dimensions are invalid.",
        error.TooLarge => "BMP must fit within 128x128 pixels.",
        error.BufferTooSmall => "BMP buffer is too small.",
    };
}

fn imageErrorText(err: r4img.Error) []const u8 {
    return switch (err) {
        error.Empty => "BMP file is empty.",
        error.UnsupportedFormat => "File is not a supported BMP.",
        error.InvalidImage => "BMP file is invalid.",
        error.InvalidDimensions => "BMP dimensions are invalid.",
        error.TooLarge => "BMP must fit within the R4IMG limits.",
        error.PixelBufferTooSmall => "BMP must fit within 128x128 pixels.",
        error.ScratchBufferTooSmall => "BMP decoder memory is too small.",
        error.DecodeFailed => "BMP decoding failed.",
        error.UnsupportedFeature => "BMP feature is unsupported.",
        error.InvalidArgument => "BMP decoder rejected its arguments.",
    };
}

fn absI32(value: i32) i32 {
    return if (value < 0) -value else value;
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}
