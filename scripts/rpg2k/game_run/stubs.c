/* Stubs for LVGL symbols the headless game run does not exercise: only so the link succeeds. Object constructors return a placeholder so the runtime keeps a live handle. */
static char placeholder_obj[256];
long lv_area_get_height(void) { return 0; }
long lv_area_get_width(void) { return 0; }
void *lv_canvas_create(void) { return placeholder_obj; }
long lv_canvas_set_buffer(void) { return 0; }
long lv_color_black(void) { return 0; }
long lv_delay_ms(void) { return 0; }
long lv_delay_set_cb(void) { return 0; }
long lv_display_create(void) { return 0; }
long lv_display_flush_is_last(void) { return 0; }
long lv_display_flush_ready(void) { return 0; }
long lv_display_get_horizontal_resolution(void) { return 0; }
long lv_display_get_screen_active(void) { return 0; }
long lv_display_get_vertical_resolution(void) { return 0; }
long lv_display_set_buffers(void) { return 0; }
long lv_display_set_color_format(void) { return 0; }
long lv_display_set_flush_cb(void) { return 0; }
long lv_draw_buf_destroy(void) { return 0; }
long lv_event_get_target(void) { return 0; }
long lv_image_set_pivot(void) { return 0; }
long lv_image_set_rotation(void) { return 0; }
long lv_image_set_scale_x(void) { return 0; }
long lv_image_set_scale_y(void) { return 0; }
long lv_is_initialized(void) { return 0; }
long lv_log_add(void) { return 0; }
long lv_mem_monitor(void) { return 0; }
long lv_obj_add_event_cb(void) { return 0; }
long lv_obj_add_flag(void) { return 0; }
void *lv_obj_create(void) { return placeholder_obj; }
long lv_obj_delete(void) { return 0; }
long lv_obj_get_child(void) { return 0; }
long lv_obj_get_child_count(void) { return 0; }
long lv_obj_get_parent(void) { return 0; }
long lv_obj_get_user_data(void) { return 0; }
long lv_obj_invalidate(void) { return 0; }
long lv_obj_move_to_index(void) { return 0; }
long lv_obj_remove_flag(void) { return 0; }
long lv_obj_remove_style_all(void) { return 0; }
long lv_obj_set_parent(void) { return 0; }
long lv_obj_set_pos(void) { return 0; }
long lv_obj_set_scrollbar_mode(void) { return 0; }
long lv_obj_set_size(void) { return 0; }
long lv_obj_set_style_bg_color(void) { return 0; }
long lv_obj_set_style_bg_opa(void) { return 0; }
long lv_obj_set_style_blend_mode(void) { return 0; }
long lv_obj_set_style_opa(void) { return 0; }
long lv_obj_set_user_data(void) { return 0; }
long lv_obj_set_x(void) { return 0; }
long lv_obj_set_y(void) { return 0; }
long lv_pct(void) { return 0; }
long lv_snapshot_take(void) { return 0; }
long lv_tick_get(void) { return 0; }
long lv_tick_set_cb(void) { return 0; }
long lv_timer_handler(void) { return 0; }

/* Bytes per pixel of the formats the engine uses (LVGL's enum values; see 3rd/lvgl/src/misc/lv_color.h). */
unsigned int lv_color_format_get_size(int f) {
  switch (f) {
    case 0x06: case 0x0A: case 0x0E: return 1; /* L8, I8, A8 */
    case 0x0F: return 3;                       /* RGB888 */
    case 0x12: return 2;                       /* RGB565 */
    default: return 4;                         /* ARGB8888, XRGB8888 */
  }
}
