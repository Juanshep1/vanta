import Foundation

/// Token classes shared by the highlighter, bracket matcher and comment toggle.
enum TokenKind: UInt8 {
    case plain = 0, keyword, decl, opword, constant, pseudo, builtin, function, funcDef, typeName,
         typeAnno, number, string, escape, interp, docString, comment, docComment, op, punct,
         heading, emphasis, code, link

    var isStringOrComment: Bool {
        switch self {
        case .string, .escape, .docString, .comment, .docComment, .code: return true
        default: return false
        }
    }
}

struct Token {
    var start: Int      // offset within the line
    var length: Int
    var kind: TokenKind
}

/// Line-at-a-time lexer for Vanta 6.0, mirroring tools/vanta_lexer.py (the
/// Pygments lexer the Vanta Book uses), with one improvement: definition names
/// (`to NAME`, `type NAME`, `kind NAME`) are only recognised at the start of a
/// statement, so `change x to y` doesn't paint `y` as a function.
///
/// The only state carried between lines is "inside a triple-quoted string" (1).
enum VantaLexer {
    static let keywords: Set<String> = [
        "say", "let", "change", "fix", "if", "otherwise", "repeat", "times", "while", "for", "each",
        "in", "to", "give", "back", "ask", "into", "add", "remove", "from", "import", "as", "use",
        "private", "stop", "skip", "attempt", "rescue", "type", "has", "shared", "new", "match",
        "when", "increase", "decrease", "by", "make", "test", "expect", "fails", "with", "end",
        "kind", "yield", "using", "lock", "send", "be", "at",
    ]
    static let constants: Set<String> = ["yes", "no", "true", "false", "nothing", "Yes", "No", "True", "False",
                                         "Nothing", "pi", "e"]
    static let typeNames: Set<String> = ["number", "text", "list", "map", "set", "bytes", "function", "nothing",
                                         "any", "yes-no", "bool"]
    static let opwords: Set<String> = ["plus", "minus", "times", "xor", "and", "or", "not", "contains"]
    static let builtins: Set<String> = Set(builtinList.split(separator: " ").map(String.init))

    /// Words after which a statement opens a block that closes with `end`.
    static let blockOpeners: Set<String> = ["if", "repeat", "while", "for", "to", "attempt", "type", "match",
                                            "using", "lock"]

    // MARK: lexing

    /// Lex one line (without its newline). Returns the end state.
    static func lexLine(_ c: UnsafeBufferPointer<UInt16>, state: UInt8, into tokens: inout [Token]) -> UInt8 {
        let n = c.count
        var i = 0
        if state == 1 {
            if let e = findTriple(c, from: 0) {
                tokens.append(Token(start: 0, length: e + 3, kind: .docString))
                i = e + 3
            } else {
                if n > 0 { tokens.append(Token(start: 0, length: n, kind: .docString)) }
                return 1
            }
        } else {
            i = lexStatementHead(c, &tokens)
        }
        var st: UInt8 = 0
        _ = lexExpr(c, from: i, tokens: &tokens, inInterp: false, endState: &st)
        return st
    }

    /// Definitions at the start of a statement: `to f`, `private to f`,
    /// `shared to f`, `type T [from P]`, `kind K`, `test "…"`, `note …`.
    private static func lexStatementHead(_ c: UnsafeBufferPointer<UInt16>, _ tokens: inout [Token]) -> Int {
        var i = skipWS(c, 0)
        guard i < c.count, isIdentStart(c[i]) else { return i }
        var (wEnd, w) = word(c, i)
        if w == "note" && (wEnd >= c.count || !isIdent(c[wEnd])) {
            tokens.append(Token(start: i, length: c.count - i, kind: .comment))
            return c.count
        }
        if w == "private" || w == "shared" {
            let j = skipWS(c, wEnd)
            guard j < c.count, isIdentStart(c[j]) else { return i }
            let (e2, w2) = word(c, j)
            guard ["to", "type", "kind", "let", "fix"].contains(w2) || (w == "shared" && w2 != "") else { return i }
            tokens.append(Token(start: i, length: wEnd - i, kind: .keyword))
            i = j; wEnd = e2; w = w2
        }
        switch w {
        case "to":
            tokens.append(Token(start: i, length: wEnd - i, kind: .decl))
            let j = skipWS(c, wEnd)
            if j > wEnd, j < c.count, isIdentStart(c[j]) {
                let (e, _) = word(c, j)
                tokens.append(Token(start: j, length: e - j, kind: .funcDef))
                return e
            }
            return wEnd
        case "type", "kind":
            tokens.append(Token(start: i, length: wEnd - i, kind: .decl))
            var j = skipWS(c, wEnd)
            guard j > wEnd, j < c.count, isIdentStart(c[j]) else { return wEnd }
            let (e, _) = word(c, j)
            tokens.append(Token(start: j, length: e - j, kind: .typeName))
            j = skipWS(c, e)
            if w == "type", j < c.count, isIdentStart(c[j]) {
                let (fe, fw) = word(c, j)
                if fw == "from" {
                    tokens.append(Token(start: j, length: fe - j, kind: .keyword))
                    let k = skipWS(c, fe)
                    if k < c.count, isIdentStart(c[k]) {
                        let (pe, _) = word(c, k)
                        tokens.append(Token(start: k, length: pe - k, kind: .typeName))
                        return pe
                    }
                    return fe
                }
            }
            return e
        case "test":
            let j = skipWS(c, wEnd)
            if j < c.count && c[j] == 34 {
                tokens.append(Token(start: i, length: wEnd - i, kind: .decl))
                return wEnd
            }
            return i
        default:
            return i
        }
    }

    enum Stop { case end, brace, quote }

    /// Lex expression tokens from `from`. In interpolation mode stops at the
    /// closing `}` (returns index after it) or at a `"` (the string ends).
    @discardableResult
    private static func lexExpr(_ c: UnsafeBufferPointer<UInt16>, from: Int, tokens: inout [Token],
                                inInterp: Bool, endState: inout UInt8) -> (Int, Stop) {
        let n = c.count
        var i = from
        var depth = 0
        var lastSignificant: UInt16 = 0       // previous non-space char (for `name: type`)
        var expectTypeAnno = false
        while i < n {
            let ch = c[i]
            if ch == 32 || ch == 9 { i += 1; continue }
            if inInterp {
                if ch == 125 { // }
                    if depth == 0 { return (i, .brace) }
                    depth -= 1
                    tokens.append(Token(start: i, length: 1, kind: .punct)); i += 1; continue
                }
                if ch == 34 { return (i, .quote) }
                if ch == 123 { depth += 1; tokens.append(Token(start: i, length: 1, kind: .punct)); i += 1; continue }
            }
            if ch == 35 { // #
                let doc = !inInterp && i + 1 < n && c[i + 1] == 35
                tokens.append(Token(start: i, length: n - i, kind: doc ? .docComment : .comment))
                return (n, .end)
            }
            if ch == 34 { // "
                if i + 2 < n && c[i + 1] == 34 && c[i + 2] == 34 {
                    if let e = findTriple(c, from: i + 3) {
                        tokens.append(Token(start: i, length: e + 3 - i, kind: .docString))
                        i = e + 3; lastSignificant = 34; continue
                    }
                    tokens.append(Token(start: i, length: n - i, kind: .docString))
                    endState = 1
                    return (n, .end)
                }
                i = lexString(c, i, &tokens)
                lastSignificant = 34
                continue
            }
            if isDigit(ch) {
                var j = i + 1
                if ch == 48, j < n, (c[j] | 0x20) == 120 || (c[j] | 0x20) == 98 || (c[j] | 0x20) == 111 { // 0x 0b 0o
                    j += 1
                    while j < n && (isHex(c[j]) || c[j] == 95) { j += 1 }
                } else {
                    while j < n && (isDigit(c[j]) || c[j] == 95) { j += 1 }
                    if j + 1 < n && c[j] == 46 && isDigit(c[j + 1]) {
                        j += 1
                        while j < n && (isDigit(c[j]) || c[j] == 95) { j += 1 }
                    }
                }
                tokens.append(Token(start: i, length: j - i, kind: .number))
                i = j; lastSignificant = 48; continue
            }
            if isIdentStart(ch) {
                let (e, w) = word(c, i)
                if expectTypeAnno {
                    var e2 = e
                    while e2 < n && (isIdent(c[e2]) || c[e2] == 45) { e2 += 1 }       // yes-no
                    tokens.append(Token(start: i, length: e2 - i, kind: .typeAnno))
                    expectTypeAnno = false; i = e2; lastSignificant = 97; continue
                }
                let (spanEnd, kind) = classifyWord(c, i, e, w)
                if kind != .plain { tokens.append(Token(start: i, length: spanEnd - i, kind: kind)) }
                i = spanEnd; lastSignificant = 97
                continue
            }
            // operators / punctuation
            if ch == 45, i + 1 < n, c[i + 1] == 62 {            // ->
                tokens.append(Token(start: i, length: 2, kind: .op))
                i += 2; expectTypeAnno = true; lastSignificant = 62; continue
            }
            if ch == 58 {                                        // :  (annotation?)
                tokens.append(Token(start: i, length: 1, kind: .punct))
                if isIdent(lastSignificant) || lastSignificant == 41 {
                    let j = skipWS(c, i + 1)
                    if j < n, isIdentStart(c[j]) {
                        var e = j
                        while e < n && (isIdent(c[e]) || c[e] == 45) { e += 1 }
                        let w = String(utf16CodeUnits: c.baseAddress! + j, count: e - j)
                        if typeNames.contains(w) && !(skipWS(c, e) < n && c[skipWS(c, e)] == 40) {
                            tokens.append(Token(start: j, length: e - j, kind: .typeAnno))
                            i = e; lastSignificant = 97; continue
                        }
                    }
                }
                i += 1; lastSignificant = ch; continue
            }
            if ch == 46, i + 2 < n, c[i + 1] == 46, c[i + 2] == 46 {
                tokens.append(Token(start: i, length: 3, kind: .op)); i += 3; lastSignificant = ch; continue
            }
            if i + 1 < n {
                let two = (ch, c[i + 1])
                if two == (60, 60) || two == (62, 62) || two == (62, 61) || two == (60, 61) || two == (61, 61) || two == (33, 61) {
                    tokens.append(Token(start: i, length: 2, kind: .op)); i += 2; lastSignificant = ch; continue
                }
            }
            switch ch {
            case 45, 43, 42, 47, 37, 94, 38, 124, 126, 60, 62, 61:      // - + * / % ^ & | ~ < > =
                tokens.append(Token(start: i, length: 1, kind: .op))
            case 40, 41, 91, 93, 123, 125, 44, 46:                      // ( ) [ ] { } , .
                tokens.append(Token(start: i, length: 1, kind: .punct))
            default: break
            }
            lastSignificant = ch
            i += 1
        }
        return (n, .end)
    }

    /// "…" with escapes and {interpolation}. Returns the index after the string.
    private static func lexString(_ c: UnsafeBufferPointer<UInt16>, _ start: Int, _ tokens: inout [Token]) -> Int {
        let n = c.count
        var segStart = start
        var i = start + 1
        func flush(_ end: Int) {
            if end > segStart { tokens.append(Token(start: segStart, length: end - segStart, kind: .string)) }
        }
        while i < n {
            let ch = c[i]
            if ch == 92 {                       // backslash escape
                flush(i)
                let len = i + 1 < n ? 2 : 1
                tokens.append(Token(start: i, length: len, kind: .escape))
                i += len; segStart = i; continue
            }
            if (ch == 123 || ch == 125) && i + 1 < n && c[i + 1] == ch {      // {{ }}
                flush(i)
                tokens.append(Token(start: i, length: 2, kind: .escape))
                i += 2; segStart = i; continue
            }
            if ch == 123 {                      // {interpolation}
                flush(i)
                tokens.append(Token(start: i, length: 1, kind: .interp))
                var st: UInt8 = 0
                let (stop, why) = lexExpr(c, from: i + 1, tokens: &tokens, inInterp: true, endState: &st)
                switch why {
                case .brace:
                    tokens.append(Token(start: stop, length: 1, kind: .interp))
                    i = stop + 1; segStart = i; continue
                case .quote:
                    tokens.append(Token(start: stop, length: 1, kind: .string))
                    return stop + 1
                case .end:
                    return n
                }
            }
            if ch == 34 {
                i += 1
                flush(i)
                return i
            }
            i += 1
        }
        flush(n)
        return n
    }

    /// Classify an identifier, folding multi-word operators into one span.
    private static func classifyWord(_ c: UnsafeBufferPointer<UInt16>, _ s: Int, _ e: Int, _ w: String) -> (Int, TokenKind) {
        switch w {
        case "is":
            // longest phrase first: is not in / is at least / is greater than …
            let (e1, w1) = nextWord(c, e)
            if let w1 {
                let (e2, w2) = nextWord(c, e1)
                if let w2 {
                    if (w1 == "not" && w2 == "in") || (w1 == "at" && (w2 == "least" || w2 == "most"))
                        || (["greater", "bigger", "more", "less", "smaller"].contains(w1) && w2 == "than") {
                        return (e2, .opword)
                    }
                }
                if ["not", "a", "an", "in", "over", "above", "under", "below"].contains(w1) { return (e1, .opword) }
            }
            return (e, .opword)
        case "divided":
            let (e1, w1) = nextWord(c, e)
            return w1 == "by" ? (e1, .opword) : (e, .plain)
        case "give":
            let (e1, w1) = nextWord(c, e)
            return w1 == "back" ? (e1, .keyword) : (e, .keyword)
        case "for":
            let (e1, w1) = nextWord(c, e)
            return w1 == "each" ? (e1, .keyword) : (e, .keyword)
        case "otherwise":
            let (e1, w1) = nextWord(c, e)
            return w1 == "if" ? (e1, .keyword) : (e, .keyword)
        default: break
        }
        if opwords.contains(w) { return (e, .opword) }
        if constants.contains(w) { return (e, .constant) }
        if w == "me" || w == "super" { return (e, .pseudo) }
        if keywords.contains(w) { return (e, .keyword) }
        let callNext = { () -> Bool in let j = skipWS(c, e); return j < c.count && c[j] == 40 }
        if builtins.contains(w) && callNext() { return (e, .builtin) }
        if isUpper(c[s]) { return (e, .typeName) }
        if callNext() { return (e, .function) }
        return (e, .plain)
    }

    // MARK: helpers

    @inline(__always) static func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }
    @inline(__always) static func isUpper(_ u: UInt16) -> Bool { u >= 65 && u <= 90 }
    @inline(__always) static func isHex(_ u: UInt16) -> Bool { isDigit(u) || (u | 0x20 >= 97 && u | 0x20 <= 102) }
    @inline(__always) static func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u > 127 }
    @inline(__always) static func isIdent(_ u: UInt16) -> Bool { isIdentStart(u) || isDigit(u) }

    static func skipWS(_ c: UnsafeBufferPointer<UInt16>, _ from: Int) -> Int {
        var i = from
        while i < c.count && (c[i] == 32 || c[i] == 9) { i += 1 }
        return i
    }

    static func word(_ c: UnsafeBufferPointer<UInt16>, _ s: Int) -> (Int, String) {
        var e = s
        while e < c.count && isIdent(c[e]) { e += 1 }
        return (e, String(utf16CodeUnits: c.baseAddress! + s, count: e - s))
    }

    private static func nextWord(_ c: UnsafeBufferPointer<UInt16>, _ from: Int) -> (Int, String?) {
        let j = skipWS(c, from)
        guard j > from, j < c.count, isIdentStart(c[j]) else { return (from, nil) }
        let (e, w) = word(c, j)
        return (e, w)
    }

    private static func findTriple(_ c: UnsafeBufferPointer<UInt16>, from: Int) -> Int? {
        var i = from
        while i + 2 < c.count {
            if c[i] == 34 && c[i + 1] == 34 && c[i + 2] == 34 { return i }
            i += 1
        }
        return nil
    }

    // From tools/vanta_lexer.py (Vanta 6.0 builtins)
    static let builtinList = """
    abs absolute_path accept acos affine_set all_where antialias any_where append_file \
    append_to_file arc arguments asin assert atan atan2 audio_close audio_open audio_queue \
    audio_queued band base64_decode base64_encode base64_to_bytes basename beep bnot bor bxor \
    bytes bytes_to_base64 bytes_to_text camera camera_center canvas capitalize ceil change_dir \
    channel chr chunk circle clamp clear clear_hotkey clear_keys clear_screen clip clock close \
    close_input code color compress contains copy_image copy_path copy_screen cos count_where \
    create_file csv_format csv_parse csv_read csv_read_maps csv_write csv_write_maps current_dir \
    cursor_position date_parts days db_execute db_last_id db_open db_query decompress delete_file \
    delta_time difference dirname disable_interrupts dns_lookup double_buffer download draw_frame \
    draw_image draw_line draw_rect draw_text draw_tilemap draw_to draw_to_screen each ellipse \
    enable_interrupts ends_with entries env env_vars every exit exp extname factorial fail \
    file_exists file_length file_mtime file_size fill_circle fill_rect find find_all find_pid \
    find_where first flatten floor font format format_date format_duration format_number fps \
    frame_count frame_rate frames_in free_image freeze from_json fullscreen game_frame game_keys \
    game_ms game_open game_screenshot game_set_keys game_time gcd get get_pixel glob graphics_mode \
    gunzip gzip halt has_key hex_decode hex_encode hide_cursor hmac home_dir hours hsv html_escape \
    http_get http_post http_request image_from_rows image_height image_pixel image_width index_of \
    insert_at interpreter intersection io_lines io_read io_write is_a is_bytes is_dir is_done \
    is_file is_function is_list is_map is_nothing is_number is_set is_subset is_text isqrt join \
    json_response keep key_down key_pressed key_released key_repeated key_up keys kill_process \
    last last_index_of last_key lcm length line line_width lines list list_dir list_files \
    load_font load_image load_sound log lowercase lz77 make_date make_dir make_image make_sound \
    make_tone map master_volume matches matches_pattern max md5 mean median mem_next mem_regions \
    mem_scan memory_info merge min minutes mix_color mode mouse_click mouse_down mouse_move \
    mouse_pos mouse_pressed mouse_released mouse_wheel mouse_world_x mouse_world_y mouse_x mouse_y \
    move_path music_volume my_pid new_lock next next_frame no_camera no_clip now now_ms number \
    oam_set oam_write on_hotkey on_interrupt on_signal open_file open_process open_url os_name \
    outline_circle outline_ellipse outline_polygon outline_rect outline_round_rect \
    outline_triangle pad_axis pad_count pad_down pad_left pad_pressed pad_released pad_right \
    pal_get pal_set pal_write parse_date path_exists path_join peek16 peek32 peek8 pick pie pixel \
    play_music play_sound poke16 poke32 poke8 poll_key polygon polyline pop port_in16 port_in32 \
    port_in8 port_out16 port_out32 port_out8 power power_off press_key print_at process_errors \
    process_id process_list product push put_pixel put_u16 put_u32 put_u8 random random_float \
    random_seed range read_all read_binary read_bytes read_chunk read_chunk_bytes read_file \
    read_float read_from_file read_int read_key read_line read_mem reboot receive receive_bytes \
    rect redirect reduce regex_escape regex_search regex_split remove_at remove_key remove_path \
    rename_file render_html repeat_text replace replace_all reverse rgb rgba round round_rect run \
    run_detached run_file run_game run_parallel run_process run_vanta s16 s32 s8 save_image \
    screen_columns screen_height screen_rows screen_width screenshot seek send send_signal serve \
    server_port set set_color set_cursor set_env set_image_pixel set_timeout sha1 sha256 shell \
    shift_left shift_right show_cursor show_frame show_keyboard show_mouse shuffle sign sin sleep \
    sleep_ms slice socket_info sort sort_by sound_length sound_playing spawn split sprite_sheet \
    sqrt start_server starts_with stdev stop_all_sounds stop_game stop_music stop_server \
    stop_sound stop_timer sum system_info tan tcp_connect tcp_listen tell temp_dir temp_file \
    test_input text text_align text_at text_height text_input text_width ticks timezone title_case \
    to_json today touch_controls touch_count touch_x touch_y touches triangle trim type_of \
    type_text typeof u16 u32 u8 udp_open udp_receive udp_send unfreeze union unique uppercase \
    uptime url_decode url_encode uuid values variance vram_fill vram_read vram_write wait wait_key \
    walk_dir window window_title write_binary write_bytes write_file write_float write_int \
    write_mem write_to write_to_file zip
    """
}

/// Minimal Markdown lexer for Book chapters / docs. State 2 = inside a ``` fence.
enum MarkdownLexer {
    static func lexLine(_ c: UnsafeBufferPointer<UInt16>, state: UInt8, into tokens: inout [Token]) -> UInt8 {
        let n = c.count
        let i = VantaLexer.skipWS(c, 0)
        let fence = i + 2 < n && c[i] == 96 && c[i + 1] == 96 && c[i + 2] == 96
        if state == 2 {
            if n > 0 { tokens.append(Token(start: 0, length: n, kind: .code)) }
            return fence ? 0 : 2
        }
        if fence {
            tokens.append(Token(start: 0, length: n, kind: .code))
            return 2
        }
        guard i < n else { return 0 }
        if c[i] == 35 {                                   // # heading
            tokens.append(Token(start: i, length: n - i, kind: .heading)); return 0
        }
        if c[i] == 62 {                                   // > quote
            tokens.append(Token(start: i, length: n - i, kind: .comment)); return 0
        }
        if (c[i] == 45 || c[i] == 42 || c[i] == 43) && i + 1 < n && c[i + 1] == 32 {
            tokens.append(Token(start: i, length: 1, kind: .keyword))
        }
        var j = i
        while j < n {
            let ch = c[j]
            if ch == 96 {                                 // `code`
                var e = j + 1
                while e < n && c[e] != 96 { e += 1 }
                let end = min(n, e + 1)
                tokens.append(Token(start: j, length: end - j, kind: .code))
                j = end; continue
            }
            if ch == 42 && j + 1 < n && c[j + 1] == 42 {  // **bold**
                var e = j + 2
                while e + 1 < n && !(c[e] == 42 && c[e + 1] == 42) { e += 1 }
                let end = min(n, e + 2)
                tokens.append(Token(start: j, length: end - j, kind: .emphasis))
                j = end; continue
            }
            if ch == 91 {                                 // [link](url)
                var e = j + 1
                while e < n && c[e] != 93 { e += 1 }
                if e + 1 < n && c[e + 1] == 40 {
                    var f = e + 2
                    while f < n && c[f] != 41 { f += 1 }
                    let end = min(n, f + 1)
                    tokens.append(Token(start: j, length: end - j, kind: .link))
                    j = end; continue
                }
            }
            j += 1
        }
        return 0
    }
}
