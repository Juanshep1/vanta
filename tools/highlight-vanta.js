/*
 * highlight.js language definition for Vanta (https://github.com/Juanshep1/vanta).
 *
 *   import hljs from "highlight.js/lib/core";
 *   import vanta from "./highlight-vanta.js";
 *   hljs.registerLanguage("vanta", vanta);
 *
 * or in a page: <script src="highlight-vanta.js"></script> after highlight.js
 * (it registers itself when window.hljs exists).
 */
(function () {
  function vanta(hljs) {
    const KEYWORDS = ["say", "let", "change", "fix", "if", "otherwise", "repeat", "times", "while", "for", "each", "in", "to", "give", "back", "ask", "into", "add", "remove", "from", "import", "as", "use", "private", "stop", "skip", "attempt", "rescue", "type", "has", "shared", "new", "match", "when", "increase", "decrease", "by", "make", "test", "expect", "fails", "with", "end", "kind", "yield", "using", "lock", "send", "be", "at"];
    const LITERALS = ["yes", "no", "true", "false", "nothing", "Yes", "No", "True", "False", "Nothing"];
    const BUILTINS = ["abs", "absolute_path", "accept", "acos", "affine_set", "all_where", "antialias", "any_where", "append_file", "append_to_file", "arc", "arguments", "asin", "assert", "atan", "atan2", "audio_close", "audio_open", "audio_queue", "audio_queued", "band", "base64_decode", "base64_encode", "base64_to_bytes", "basename", "beep", "bnot", "bor", "bxor", "bytes", "bytes_to_base64", "bytes_to_text", "camera", "camera_center", "canvas", "capitalize", "ceil", "change_dir", "channel", "chr", "chunk", "circle", "clamp", "clear", "clear_hotkey", "clear_keys", "clear_screen", "clip", "clock", "close", "close_input", "code", "color", "compress", "contains", "copy_image", "copy_path", "copy_screen", "cos", "count_where", "create_file", "csv_format", "csv_parse", "csv_read", "csv_read_maps", "csv_write", "csv_write_maps", "current_dir", "cursor_position", "date_parts", "days", "db_execute", "db_last_id", "db_open", "db_query", "decompress", "delete_file", "delta_time", "difference", "dirname", "disable_interrupts", "dns_lookup", "double_buffer", "download", "draw_frame", "draw_image", "draw_line", "draw_rect", "draw_text", "draw_tilemap", "draw_to", "draw_to_screen", "each", "ellipse", "enable_interrupts", "ends_with", "entries", "env", "env_vars", "every", "exit", "exp", "extname", "factorial", "fail", "file_exists", "file_length", "file_mtime", "file_size", "fill_circle", "fill_rect", "find", "find_all", "find_pid", "find_where", "first", "flatten", "floor", "font", "format", "format_date", "format_duration", "format_number", "fps", "frame_count", "frame_rate", "frames_in", "free_image", "freeze", "from_json", "fullscreen", "game_frame", "game_keys", "game_ms", "game_open", "game_screenshot", "game_set_keys", "game_time", "gcd", "get", "get_pixel", "glob", "graphics_mode", "gunzip", "gzip", "halt", "has_key", "hex_decode", "hex_encode", "hide_cursor", "hmac", "home_dir", "hours", "hsv", "html_escape", "http_get", "http_post", "http_request", "image_from_rows", "image_height", "image_pixel", "image_width", "index_of", "insert_at", "interpreter", "intersection", "io_lines", "io_read", "io_write", "is_a", "is_bytes", "is_dir", "is_done", "is_file", "is_function", "is_list", "is_map", "is_nothing", "is_number", "is_set", "is_subset", "is_text", "isqrt", "join", "json_response", "keep", "key_down", "key_pressed", "key_released", "key_repeated", "key_up", "keys", "kill_process", "last", "last_index_of", "last_key", "lcm", "length", "line", "line_width", "lines", "list", "list_dir", "list_files", "load_font", "load_image", "load_sound", "log", "lowercase", "lz77", "make_date", "make_dir", "make_image", "make_sound", "make_tone", "map", "master_volume", "matches", "matches_pattern", "max", "md5", "mean", "median", "mem_next", "mem_regions", "mem_scan", "memory_info", "merge", "min", "minutes", "mix_color", "mode", "mouse_click", "mouse_down", "mouse_move", "mouse_pos", "mouse_pressed", "mouse_released", "mouse_wheel", "mouse_world_x", "mouse_world_y", "mouse_x", "mouse_y", "move_path", "music_volume", "my_pid", "new_lock", "next", "next_frame", "no_camera", "no_clip", "now", "now_ms", "number", "oam_set", "oam_write", "on_hotkey", "on_interrupt", "on_signal", "open_file", "open_process", "open_url", "os_name", "outline_circle", "outline_ellipse", "outline_polygon", "outline_rect", "outline_round_rect", "outline_triangle", "pad_axis", "pad_count", "pad_down", "pad_left", "pad_pressed", "pad_released", "pad_right", "pal_get", "pal_set", "pal_write", "parse_date", "path_exists", "path_join", "peek16", "peek32", "peek8", "pick", "pie", "pixel", "play_music", "play_sound", "poke16", "poke32", "poke8", "poll_key", "polygon", "polyline", "pop", "port_in16", "port_in32", "port_in8", "port_out16", "port_out32", "port_out8", "power", "power_off", "press_key", "print_at", "process_errors", "process_id", "process_list", "product", "push", "put_pixel", "put_u16", "put_u32", "put_u8", "random", "random_float", "random_seed", "range", "read_all", "read_binary", "read_bytes", "read_chunk", "read_chunk_bytes", "read_file", "read_float", "read_from_file", "read_int", "read_key", "read_line", "read_mem", "reboot", "receive", "receive_bytes", "rect", "redirect", "reduce", "regex_escape", "regex_search", "regex_split", "remove_at", "remove_key", "remove_path", "rename_file", "render_html", "repeat_text", "replace", "replace_all", "reverse", "rgb", "rgba", "round", "round_rect", "run", "run_detached", "run_file", "run_game", "run_parallel", "run_process", "run_vanta", "s16", "s32", "s8", "save_image", "screen_columns", "screen_height", "screen_rows", "screen_width", "screenshot", "seek", "send", "send_signal", "serve", "server_port", "set", "set_color", "set_cursor", "set_env", "set_image_pixel", "set_timeout", "sha1", "sha256", "shell", "shift_left", "shift_right", "show_cursor", "show_frame", "show_keyboard", "show_mouse", "shuffle", "sign", "sin", "sleep", "sleep_ms", "slice", "socket_info", "sort", "sort_by", "sound_length", "sound_playing", "spawn", "split", "sprite_sheet", "sqrt", "start_server", "starts_with", "stdev", "stop_all_sounds", "stop_game", "stop_music", "stop_server", "stop_sound", "stop_timer", "sum", "system_info", "tan", "tcp_connect", "tcp_listen", "tell", "temp_dir", "temp_file", "test_input", "text", "text_align", "text_at", "text_height", "text_input", "text_width", "ticks", "timezone", "title_case", "to_json", "today", "touch_controls", "touch_count", "touch_x", "touch_y", "touches", "triangle", "trim", "type_of", "type_text", "typeof", "u16", "u32", "u8", "udp_open", "udp_receive", "udp_send", "unfreeze", "union", "unique", "uppercase", "uptime", "url_decode", "url_encode", "uuid", "values", "variance", "vram_fill", "vram_read", "vram_write", "wait", "wait_key", "walk_dir", "window", "window_title", "write_binary", "write_bytes", "write_file", "write_float", "write_int", "write_mem", "write_to", "write_to_file", "zip"];
    const INTERP = { className: "subst", begin: /\{(?!\{)/, end: /\}|(?=")/, keywords: { keyword: KEYWORDS, literal: LITERALS } };
    const STRING = {
      className: "string",
      variants: [
        { begin: /"""/, end: /"""/ },
        { begin: /"/, end: /"|$/, contains: [{ className: "char.escape", begin: /\\.|\{\{|\}\}/ }, INTERP] },
      ],
    };
    const NUMBER = {
      className: "number",
      variants: [{ begin: /\b0[xX][0-9a-fA-F_]+/ }, { begin: /\b0[bB][01_]+/ }, { begin: /\b0[oO][0-7_]+/ },
                 { begin: /\b\d[\d_]*(\.\d[\d_]*)?/ }],
    };
    INTERP.contains = [NUMBER];
    return {
      name: "Vanta",
      aliases: ["va"],
      keywords: { keyword: KEYWORDS, literal: LITERALS, built_in: BUILTINS, "variable.language": ["me", "super"] },
      contains: [
        { className: "doctag", begin: /##/, end: /$/ },
        hljs.HASH_COMMENT_MODE,
        { className: "comment", begin: /^\s*note\b/, end: /$/ },
        STRING,
        NUMBER,
        { className: "operator",
          begin: /\b(is\s+not\s+in|is\s+at\s+least|is\s+at\s+most|is\s+(greater|bigger|more|less|smaller)\s+than|is\s+not|is\s+an?|is\s+in|is\s+(over|above|under|below)|is|divided\s+by|plus|minus|times|xor|and|or|not|contains)\b/ },
        { begin: [/\b(?:to)/, /\s+/, /[A-Za-z_]\w*/], beginScope: { 1: "keyword", 3: "title.function" } },
        { begin: [/\b(?:type|kind)/, /\s+/, /[A-Za-z_]\w*/], beginScope: { 1: "keyword", 3: "title.class" } },
        { className: "type", begin: /->\s*[A-Za-z_][\w-]*/ },
        { className: "title.class", begin: /\b[A-Z]\w*/ },
      ],
    };
  }
  if (typeof module !== "undefined" && module.exports) module.exports = vanta;
  if (typeof window !== "undefined" && window.hljs) window.hljs.registerLanguage("vanta", vanta);
})();
