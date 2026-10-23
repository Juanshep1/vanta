"""A Pygments lexer for Vanta, the plain-English programming language.

Used by the book's PDF builder and anything else that highlights code with Pygments:

    from tools.vanta_lexer import VantaLexer           # or: sys.path.insert(0, "tools")
    from pygments import highlight
    from pygments.formatters import HtmlFormatter
    print(highlight(source, VantaLexer(), HtmlFormatter()))

From the command line (no install needed):

    pygmentize -l tools/vanta_lexer.py:VantaLexer -x -f html -O full program.va

It knows statement keywords, word operators (`is at least`, `is not in`, `divided by`,
`plus`, ...), "strings" with {interpolation} and escapes, \"\"\"raw triple-quoted
strings\"\"\", ## doc comments, # comments and `note` lines, numbers (0xFF, 0b1010,
1_000_000, 3.14), builtins, function / type / kind names where they are defined, type
annotations (`r: number`, `-> text`), and named arguments.
"""

import re

from pygments.lexer import RegexLexer, bygroups, include, words
from pygments.token import (Comment, Keyword, Name, Number, Operator, Punctuation,
                            String, Text, Whitespace)

__all__ = ["VantaLexer"]

KEYWORDS = (
    "say", "let", "change", "fix", "if", "otherwise", "repeat", "times", "while", "for", "each",
    "in", "to", "give", "back", "ask", "into", "add", "remove", "from", "import", "as", "use",
    "private", "stop", "skip", "attempt", "rescue", "type", "has", "shared", "new", "match",
    "when", "increase", "decrease", "by", "make", "test", "expect", "fails", "with", "end",
    "kind", "yield", "using", "lock", "send", "be", "at",
)

CONSTANTS = ("yes", "no", "true", "false", "nothing", "Yes", "No", "True", "False", "Nothing",
             "pi", "e")

TYPE_NAMES = ("number", "text", "list", "map", "set", "bytes", "function", "nothing", "any",
              "yes-no", "bool")

BUILTINS = tuple((
    "abs absolute_path accept acos affine_set all_where antialias any_where append_file "
    "append_to_file arc arguments asin assert atan atan2 audio_close audio_open audio_queue "
    "audio_queued band base64_decode base64_encode base64_to_bytes basename beep bnot bor bxor "
    "bytes bytes_to_base64 bytes_to_text camera camera_center canvas capitalize ceil change_dir "
    "channel chr chunk circle clamp clear clear_hotkey clear_keys clear_screen clip clock close "
    "close_input code color compress contains copy_image copy_path copy_screen cos count_where "
    "create_file csv_format csv_parse csv_read csv_read_maps csv_write csv_write_maps current_dir "
    "cursor_position date_parts days db_execute db_last_id db_open db_query decompress delete_file "
    "delta_time difference dirname disable_interrupts dns_lookup double_buffer download draw_frame "
    "draw_image draw_line draw_rect draw_text draw_tilemap draw_to draw_to_screen each ellipse "
    "enable_interrupts ends_with entries env env_vars every exit exp extname factorial fail "
    "file_exists file_length file_mtime file_size fill_circle fill_rect find find_all find_pid "
    "find_where first flatten floor font format format_date format_duration format_number fps "
    "frame_count frame_rate frames_in free_image freeze from_json fullscreen game_frame game_keys "
    "game_ms game_open game_screenshot game_set_keys game_time gcd get get_pixel glob graphics_mode "
    "gunzip gzip halt has_key hex_decode hex_encode hide_cursor hmac home_dir hours hsv html_escape "
    "http_get http_post http_request image_from_rows image_height image_pixel image_width index_of "
    "insert_at interpreter intersection io_lines io_read io_write is_a is_bytes is_dir is_done "
    "is_file is_function is_list is_map is_nothing is_number is_set is_subset is_text isqrt join "
    "json_response keep key_down key_pressed key_released key_repeated key_up keys kill_process "
    "last last_index_of last_key lcm length line line_width lines list list_dir list_files "
    "load_font load_image load_sound log lowercase lz77 make_date make_dir make_image make_sound "
    "make_tone map master_volume matches matches_pattern max md5 mean median mem_next mem_regions "
    "mem_scan memory_info merge min minutes mix_color mode mouse_click mouse_down mouse_move "
    "mouse_pos mouse_pressed mouse_released mouse_wheel mouse_world_x mouse_world_y mouse_x mouse_y "
    "move_path music_volume my_pid new_lock next next_frame no_camera no_clip now now_ms number "
    "oam_set oam_write on_hotkey on_interrupt on_signal open_file open_process open_url os_name "
    "outline_circle outline_ellipse outline_polygon outline_rect outline_round_rect "
    "outline_triangle pad_axis pad_count pad_down pad_left pad_pressed pad_released pad_right "
    "pal_get pal_set pal_write parse_date path_exists path_join peek16 peek32 peek8 pick pie pixel "
    "play_music play_sound poke16 poke32 poke8 poll_key polygon polyline pop port_in16 port_in32 "
    "port_in8 port_out16 port_out32 port_out8 power power_off press_key print_at process_errors "
    "process_id process_list product push put_pixel put_u16 put_u32 put_u8 random random_float "
    "random_seed range read_all read_binary read_bytes read_chunk read_chunk_bytes read_file "
    "read_float read_from_file read_int read_key read_line read_mem reboot receive receive_bytes "
    "rect redirect reduce regex_escape regex_search regex_split remove_at remove_key remove_path "
    "rename_file render_html repeat_text replace replace_all reverse rgb rgba round round_rect run "
    "run_detached run_file run_game run_parallel run_process run_vanta s16 s32 s8 save_image "
    "screen_columns screen_height screen_rows screen_width screenshot seek send send_signal serve "
    "server_port set set_color set_cursor set_env set_image_pixel set_timeout sha1 sha256 shell "
    "shift_left shift_right show_cursor show_frame show_keyboard show_mouse shuffle sign sin sleep "
    "sleep_ms slice socket_info sort sort_by sound_length sound_playing spawn split sprite_sheet "
    "sqrt start_server starts_with stdev stop_all_sounds stop_game stop_music stop_server "
    "stop_sound stop_timer sum system_info tan tcp_connect tcp_listen tell temp_dir temp_file "
    "test_input text text_align text_at text_height text_input text_width ticks timezone title_case "
    "to_json today touch_controls touch_count touch_x touch_y touches triangle trim type_of "
    "type_text typeof u16 u32 u8 udp_open udp_receive udp_send unfreeze union unique uppercase "
    "uptime url_decode url_encode uuid values variance vram_fill vram_read vram_write wait wait_key "
    "walk_dir window window_title write_binary write_bytes write_file write_float write_int "
    "write_mem write_to write_to_file zip "
).split())

# word operators, longest first so "is not in" wins over "is not" and "is"
IS_PHRASES = (r"is\s+not\s+in", r"is\s+at\s+least", r"is\s+at\s+most", r"is\s+greater\s+than",
              r"is\s+bigger\s+than", r"is\s+more\s+than", r"is\s+less\s+than",
              r"is\s+smaller\s+than", r"is\s+not", r"is\s+an?", r"is\s+in", r"is\s+over",
              r"is\s+above", r"is\s+under", r"is\s+below", r"is")


class VantaLexer(RegexLexer):
    """Lexer for Vanta (.va) programs."""

    name = "Vanta"
    aliases = ["vanta", "va"]
    filenames = ["*.va"]
    mimetypes = ["text/x-vanta"]
    url = "https://github.com/Juanshep1/vanta"
    flags = re.MULTILINE

    tokens = {
        "root": [
            (r"[ \t]+", Whitespace),
            (r"\n", Whitespace),
            (r"##.*$", Comment.Special),                       # doc comments
            (r"#.*$", Comment.Single),
            (r"^([ \t]*)(note\b.*)$", bygroups(Whitespace, Comment.Single)),
            # definitions: to NAME, type NAME [from PARENT], kind NAME, test "name"
            (r"\b(to)(\s+)([A-Za-z_]\w*)", bygroups(Keyword.Declaration, Whitespace, Name.Function)),
            (r"\b(shared)(\s+)(to)(\s+)([A-Za-z_]\w*)",
             bygroups(Keyword.Declaration, Whitespace, Keyword.Declaration, Whitespace, Name.Function)),
            (r"\b(type)(\s+)([A-Za-z_]\w*)(\s+)(from)(\s+)([A-Za-z_]\w*)",
             bygroups(Keyword.Declaration, Whitespace, Name.Class, Whitespace, Keyword, Whitespace, Name.Class)),
            (r"\b(type|kind)(\s+)([A-Za-z_]\w*)", bygroups(Keyword.Declaration, Whitespace, Name.Class)),
            (r"\b(test)(\s+)(?=\")", bygroups(Keyword.Declaration, Whitespace)),
            include("expression"),
        ],
        "expression": [
            (r"[ \t]+", Whitespace),
            (r"#.*$", Comment.Single),
            (r'"""', String.Doc, "triple"),
            (r'"', String.Double, "string"),
            (r"0[xX][0-9a-fA-F_]+\b", Number.Hex),
            (r"0[bB][01_]+\b", Number.Bin),
            (r"0[oO][0-7_]+\b", Number.Oct),
            (r"\d[\d_]*\.\d[\d_]*", Number.Float),
            (r"\d[\d_]*", Number.Integer),
            (r"\b(?:" + "|".join(IS_PHRASES) + r")\b", Operator.Word),
            (r"\bdivided\s+by\b", Operator.Word),
            (r"\bgive\s+back\b", Keyword),
            (r"\bfor\s+each\b", Keyword),
            (r"\botherwise\s+if\b", Keyword),
            (words(("plus", "minus", "times", "xor", "and", "or", "not", "contains"),
                   prefix=r"\b", suffix=r"\b"), Operator.Word),
            (words(CONSTANTS, prefix=r"\b", suffix=r"\b"), Keyword.Constant),
            (r"\b(me|super)\b", Name.Builtin.Pseudo),
            (words(KEYWORDS, prefix=r"\b", suffix=r"\b"), Keyword),
            # annotations: name: type   and   -> type
            (r"(->)(\s*)([A-Za-z_][\w-]*)", bygroups(Operator, Whitespace, Keyword.Type)),
            (r"(?<=[\w)])(:)(\s*)(" + "|".join(re.escape(t) for t in TYPE_NAMES) + r")\b(?!\s*\()",
             bygroups(Punctuation, Whitespace, Keyword.Type)),
            (words(BUILTINS, prefix=r"\b", suffix=r"\b(?=\s*\()"), Name.Builtin),
            (r"[A-Z]\w*", Name.Class),
            (r"[A-Za-z_]\w*(?=\s*\()", Name.Function),
            (r"[A-Za-z_]\w*", Name),
            (r"\.\.\.", Operator),
            (r"<<|>>|>=|<=|==|!=|->|[-+*/%^&|~<>=]", Operator),
            (r"[()\[\]{},.:]", Punctuation),
            (r".", Text),
        ],
        "string": [
            (r'\\[\\"ntr{}]', String.Escape),
            (r"\\.", String.Escape),
            (r"\{\{|\}\}", String.Escape),
            (r"\{", String.Interpol, "interpolation"),
            (r'[^"\\{}\n]+', String.Double),
            (r"\}", String.Double),
            (r'"', String.Double, "#pop"),
            (r"\n", String.Double, "#pop"),                # unterminated: stop at the end of the line
        ],
        "interpolation": [
            (r"\}", String.Interpol, "#pop"),
            (r'"', String.Double, "#pop:2"),                # a quote always ends the text
            (r"\n", String.Double, "#pop:2"),
            (r"\{", Punctuation, "#push"),
            include("expression"),
        ],
        "triple": [
            (r'"""', String.Doc, "#pop"),
            (r'[^"]+', String.Doc),
            (r'"', String.Doc),
        ],
    }

    def analyse_text(text):
        score = 0.0
        if re.search(r"^\s*say\s", text, re.M):
            score += 0.2
        if re.search(r"^\s*let\s+\w+\s+be\s", text, re.M):
            score += 0.3
        if re.search(r"\bgive\s+back\b", text):
            score += 0.3
        if re.search(r"\bis\s+at\s+(least|most)\b", text):
            score += 0.1
        return min(score, 1.0)
