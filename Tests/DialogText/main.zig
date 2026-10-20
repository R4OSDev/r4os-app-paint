//! Headless fixture: the identical app entry, self-test and owners.
const r4os = @import("r4os");
const dialog_app = @import("dialog_app");
pub fn r4_app_main(app: *r4os.App) i32 {
    return dialog_app.r4_app_main(app);
}
