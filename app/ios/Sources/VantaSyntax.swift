import UIKit

// Syntax highlighter for Vanta — applies colour attributes to an NSTextStorage
// by scanning the text (comments, strings, numbers, keywords, builtins,
// operators). Same scanner as Vanta Studio's, ported to UIKit.
enum VantaSyntax {
    static let keywords: Set<String> = [
        "let","be","change","to","if","otherwise","end","repeat","while","for","each",
        "in","say","give","back","stop","skip","import","is","and","or","not","yes","no",
        "nothing","times","at","type","has","attempt","rescue","new","from","super",
        "match","when","increase","decrease","by","make","fix","ask","into","add","me",
        "plus","minus","divided","over","under","above","below","least","most","than",
        "bigger","smaller","greater","more","an","a",
    ]

    static let builtins: Set<String> = [
        "length","text","number","uppercase","lowercase","trim","replace","starts_with",
        "ends_with","find","split","lines","pad_left","pad_right","chr","code","abs","round",
        "floor","ceil","sqrt","power","sin","cos","tan","asin","acos","atan","atan2","log",
        "exp","sum","product","min","max","random","random_float","now","today","clock",
        "first","last","range","contains","keys","values","sort","reverse","slice","push",
        "pop","remove_at","unique","zip","flatten","index_of","last_index_of","insert_at",
        "shuffle","pick","chunk","map","keep","reduce","each","count_where","find_where",
        "sort_by","any_where","all_where","get","has_key","remove_key","merge","entries",
        "repeat_text","title_case","capitalize","format_number","clamp","sign",
        "format_date","parse_date","type_of","is_a","is_number","is_text","is_list",
        "is_map","is_function","is_nothing","matches","find_all","replace_all","fail",
        "assert","read_file","write_file","read_bytes","band","bor","bxor","bnot",
        "shift_left","shift_right","run","shell","arguments","env","to_json","from_json",
        "pi","e","sleep","join","http_get","http_post","http_request","serve",
    ]

    private static let operators = Set("+-*/%^<>=!:[](){},.".unicodeScalars.map { UInt16($0.value) })

    static func highlight(_ storage: NSTextStorage, font: UIFont) {
        let s = storage.string as NSString
        let n = s.length
        let full = NSRange(location: 0, length: n)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.uink], range: full)

        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isAlpha(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func color(_ col: UIColor, _ loc: Int, _ len: Int) {
            if len > 0 { storage.addAttribute(.foregroundColor, value: col, range: NSRange(location: loc, length: len)) }
        }

        var i = 0
        while i < n {
            let c = s.character(at: i)
            if c == 35 { // '#' comment to end of line
                var j = i
                while j < n && s.character(at: j) != 10 { j += 1 }
                color(Theme.ucom, i, j - i)
                i = j
                continue
            }
            if c == 34 { // '"' string
                // Triple-quoted raw string """...""" (multi-line HTML/CSS/JS).
                if i + 2 < n && s.character(at: i + 1) == 34 && s.character(at: i + 2) == 34 {
                    var j = i + 3
                    while j + 2 < n && !(s.character(at: j) == 34 && s.character(at: j + 1) == 34 && s.character(at: j + 2) == 34) {
                        j += 1
                    }
                    j = (j + 2 < n) ? j + 3 : n
                    color(Theme.ustr, i, j - i)
                    i = j
                    continue
                }
                var j = i + 1
                while j < n && s.character(at: j) != 34 {
                    if s.character(at: j) == 92 && j + 1 < n { j += 2 } else { j += 1 }
                }
                if j < n { j += 1 }
                color(Theme.ustr, i, j - i)
                i = j
                continue
            }
            if isDigit(c) {
                var j = i
                while j < n && (isDigit(s.character(at: j)) || s.character(at: j) == 46) { j += 1 }
                color(Theme.unum, i, j - i)
                i = j
                continue
            }
            if isAlpha(c) {
                var j = i
                while j < n && (isAlpha(s.character(at: j)) || isDigit(s.character(at: j))) { j += 1 }
                let word = s.substring(with: NSRange(location: i, length: j - i))
                if keywords.contains(word) { color(Theme.ukw, i, j - i) }
                else if builtins.contains(word) { color(Theme.ufn, i, j - i) }
                i = j
                continue
            }
            if operators.contains(c) { color(Theme.uop, i, 1) }
            i += 1
        }
        storage.endEditing()
    }
}
