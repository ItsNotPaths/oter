package oter

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "oket:theme"

// `oter --theme`: oket's themer as a TUI. Every helix theme, the ones in themes/ first.
// Enter pulls one that is not here, then writes [theme] name; the outer oter reloads it.

@(private = "file")
API_URL :: "https://api.github.com/repos/helix-editor/helix/contents/runtime/themes"
@(private = "file")
RAW_URL :: "https://raw.githubusercontent.com/helix-editor/helix/master/runtime/themes"

Theme_State :: enum {
    Away, // only in the repo list
    Here,
    Pulled, // here, and named in .themer: the only kind del removes
}

Theme_Row :: struct {
    name:  string,
    state: Theme_State,
}

@(private = "file")
Themer :: struct {
    dir:    string, // <config>/themes
    conf:   string, // <config>/config.conf
    rows:   [dynamic]Theme_Row,
    filter: [dynamic]u8,
    cursor: int, // into what the filter shows
    top:    int,
    note:   string, // the head's last word, until the next key
}

// The program's exit code.
themer_run :: proc() -> int {
    h := home_resolve()
    if h.config == "" {
        fmt.eprintln("oter --theme: no config dir")
        return 1
    }
    th := Themer {
        dir  = filepath.join({h.config, "themes"}) or_else "",
        conf = filepath.join({h.config, "config.conf"}) or_else "",
    }
    os.make_directory_all(th.dir)
    if !os.exists(list_file(th.dir)) {
        fmt.println("fetching the helix theme list...")
        list_fetch(th.dir)
    }
    th.rows = themes_scan(th.dir)

    saved: posix.termios
    if posix.tcgetattr(0, &saved) != .OK {
        fmt.eprintln("oter --theme: not a terminal")
        return 1
    }
    raw := saved
    raw.c_lflag -= {.ECHO, .ICANON, .ISIG}
    raw.c_iflag -= {.IXON, .ICRNL}
    raw.c_cc[.VMIN], raw.c_cc[.VTIME] = 0, 1 // a 100ms tick, so a resize redraws
    posix.tcsetattr(0, .TCSAFLUSH, &raw)
    os.write_string(os.stdout, "\e[?1049h")

    picked := themer_loop(&th)

    os.write_string(os.stdout, "\e[?1049l")
    posix.tcsetattr(0, .TCSAFLUSH, &saved)
    if picked != "" {
        fmt.printfln("theme: %s", picked)
    }
    return 0
}

// Keys until enter lands a theme (its name) or esc leaves ("").
@(private = "file")
themer_loop :: proc(th: ^Themer) -> string {
    size: [2]int
    buf: [64]u8
    for {
        shown := themes_shown(th.rows[:], string(th.filter[:]))
        th.cursor = clamp(th.cursor, 0, max(len(shown) - 1, 0))
        size = term_size()
        themer_draw(th, shown, size)
        n := 0
        for n <= 0 {
            n = int(posix.read(0, raw_data(buf[:]), len(buf)))
            if n == 0 && term_size() != size {
                break
            }
        }
        if n <= 0 {
            continue
        }
        th.note = ""
        switch key := string(buf[:n]); key {
        case "\e", "\x03":
            if key == "\e" && len(th.filter) > 0 {
                clear(&th.filter)
            } else {
                return ""
            }
        case "\e[A":
            th.cursor -= 1
        case "\e[B":
            th.cursor += 1
        case "\x7f", "\b":
            if len(th.filter) > 0 {
                pop(&th.filter)
            }
            th.cursor = 0
        case "\r", "\n":
            if len(shown) > 0 && themer_pick(th, shown) {
                return th.rows[shown[th.cursor]].name
            }
        case "\e[3~":
            if len(shown) > 0 {
                themer_remove(th, shown[th.cursor])
            }
        case:
            if key[0] >= ' ' && key[0] < 0x7f {
                append(&th.filter, ..buf[:n])
                th.cursor = 0
            }
        }
    }
}

// It and the themes it inherits from pulled where missing, then config.conf names it.
@(private = "file")
themer_pick :: proc(th: ^Themer, shown: []int) -> bool {
    r := &th.rows[shown[th.cursor]]
    name := r.name
    for _ in 0 ..< 4 { // theme.load follows no deeper
        file := fmt.tprintf("%s/%s.toml", th.dir, name)
        if !os.exists(file) {
            th.note = fmt.tprintf("pulling %s...", name)
            themer_draw(th, shown, term_size())
            if !curl(fmt.tprintf("%s/%s.toml", RAW_URL, name), file) {
                _ = os.remove(file)
                th.note = fmt.tprintf("could not pull %s", name)
                return false
            }
            for &row in th.rows {
                if row.name == name {
                    row.state = .Pulled
                }
            }
            manifest_write(th)
        }
        name = inherits_of(file)
        if !name_ok(name) {
            break
        }
    }
    if !conf_set_theme(th.conf, r.name) {
        th.note = fmt.tprintf("could not write %s", th.conf)
        return false
    }
    return true
}

// A pulled theme's file and manifest line; config.conf goes back to the default if it named it.
@(private = "file")
themer_remove :: proc(th: ^Themer, i: int) {
    r := &th.rows[i]
    if r.state != .Pulled {
        th.note = fmt.tprintf("%s was not pulled here", r.name)
        return
    }
    if os.remove(fmt.tprintf("%s/%s.toml", th.dir, r.name)) != nil {
        th.note = fmt.tprintf("cannot remove %s.toml", r.name)
        return
    }
    r.state = .Away
    manifest_write(th)
    cfg: Config
    defer config_destroy(&cfg)
    if text, err := os.read_entire_file(th.conf, context.temp_allocator); err == nil {
        bad_free(config_parse(&cfg, string(text), th.conf))
        if cfg.theme == r.name {
            conf_set_theme(th.conf, theme.DEFAULT)
        }
    }
    th.note = fmt.tprintf("removed %s", r.name)
}

@(private = "file")
themer_draw :: proc(th: ^Themer, shown: []int, size: [2]int) {
    rows, cols := size[0], size[1]
    list_h := max(rows - 2, 1)
    th.top = clamp(th.top, th.cursor - list_h + 1, th.cursor)
    here := 0
    for r in th.rows {
        here += int(r.state != .Away)
    }
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "\e[?25l\e[H")
    head := fmt.tprintf("themes   %d here of %d   %d shown   %s", here, len(th.rows), len(shown),
        th.note != "" ? th.note : "enter switches; del removes a pulled one; esc leaves")
    fmt.sbprintf(&b, "%s\e[K\r\n", clip(head, cols))
    fmt.sbprintf(&b, "/%s\e[K\r\n", clip(string(th.filter[:]), cols - 1))
    for y in 0 ..< list_h {
        if i := th.top + y; i < len(shown) {
            r := th.rows[shown[i]]
            line := fmt.tprintf("%s %-34s%s", r.state == .Away ? " " : "*", r.name, r.state == .Pulled ? "pulled" : "")
            fmt.sbprintf(&b, "%s%s\e[0m", i == th.cursor ? "\e[7m" : "", clip(line, cols))
        }
        strings.write_string(&b, y < list_h - 1 ? "\e[K\r\n" : "\e[K")
    }
    fmt.sbprintf(&b, "\e[2;%dH\e[?25h", min(len(th.filter) + 2, cols)) // the caret in the search bar
    os.write_string(os.stdout, strings.to_string(b))
}

@(private = "file")
clip :: proc(s: string, n: int) -> string {
    return s[:clamp(n, 0, len(s))]
}

// Rows by terminal; 24x80 when it will not say.
@(private = "file")
term_size :: proc() -> [2]int {
    ws: struct {
        row, col, x, y: u16,
    }
    if linux.ioctl(0, linux.TIOCGWINSZ, uintptr(&ws)) != 0 || ws.row == 0 {
        return {24, 80}
    }
    return {int(ws.row), int(ws.col)}
}

// Indices into `rows` whose names hold `filter`. Temp-allocated.
themes_shown :: proc(rows: []Theme_Row, filter: string) -> []int {
    out := make([dynamic]int, context.temp_allocator)
    for r, i in rows {
        if strings.contains(r.name, filter) {
            append(&out, i)
        }
    }
    return out[:]
}

// Files in `dir`, marked by .themer, then .list's names; here first, by name.
themes_scan :: proc(dir: string) -> [dynamic]Theme_Row {
    rows: [dynamic]Theme_Row
    add :: proc(rows: ^[dynamic]Theme_Row, name: string, state: Theme_State) {
        if !name_ok(name) {
            return
        }
        for &r in rows {
            if r.name == name {
                if r.state == .Here && state == .Pulled {
                    r.state = .Pulled
                }
                return
            }
        }
        if state != .Pulled { // a manifest line whose file is gone marks nothing
            append(rows, Theme_Row{strings.clone(name), state})
        }
    }
    if files, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
        for f in files {
            if strings.has_suffix(f.name, ".toml") {
                add(&rows, strings.trim_suffix(f.name, ".toml"), .Here)
            }
        }
    }
    for name in lines_of(fmt.tprintf("%s/.themer", dir)) {
        add(&rows, name, .Pulled)
    }
    for name in lines_of(list_file(dir)) {
        add(&rows, name, .Away)
    }
    slice.sort_by(rows[:], proc(a, b: Theme_Row) -> bool {
        if (a.state == .Away) != (b.state == .Away) {
            return b.state == .Away
        }
        return a.name < b.name
    })
    return rows
}

// Names reach file paths: only these bytes get a row.
@(private = "file")
name_ok :: proc(name: string) -> bool {
    if name == "" || name[0] == '.' {
        return false
    }
    for c in name {
        if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
            return false
        }
    }
    return true
}

// `text` with its [theme] name row set to `name`, or that row added.
conf_with_theme :: proc(text, name: string) -> string {
    lines := make([dynamic]string, context.temp_allocator)
    append(&lines, ..strings.split_lines(text, context.temp_allocator))
    row := fmt.tprintf("name = %s", name)
    section, header := "", -1
    for line, i in lines {
        t := strings.trim_space(line)
        if strings.has_prefix(t, "[") {
            section = t
            if t == "[theme]" {
                header = i
            }
        } else if key, eq, _ := strings.partition(t, "="); section == "[theme]" && eq != "" && strings.trim_space(key) == "name" {
            lines[i] = row
            return strings.join(lines[:], "\n", context.temp_allocator)
        }
    }
    if header >= 0 {
        inject_at(&lines, header + 1, row)
    } else {
        end := len(lines) > 0 && lines[len(lines) - 1] == "" ? len(lines) - 1 : len(lines)
        inject_at(&lines, end, "[theme]", row)
    }
    return strings.join(lines[:], "\n", context.temp_allocator)
}

@(private = "file")
conf_set_theme :: proc(path, name: string) -> bool {
    text := os.read_entire_file(path, context.temp_allocator) or_else transmute([]u8)string(DEFAULT_CONFIG)
    return os.write_entire_file(path, conf_with_theme(string(text), name)) == nil
}

@(private = "file")
manifest_write :: proc(th: ^Themer) {
    b := strings.builder_make(context.temp_allocator)
    for r in th.rows {
        if r.state == .Pulled {
            fmt.sbprintln(&b, r.name)
        }
    }
    _ = os.write_entire_file(fmt.tprintf("%s/.themer", th.dir), strings.to_string(b))
}

// The repo listing into .list. A failed fetch leaves whatever was there.
@(private = "file")
list_fetch :: proc(dir: string) {
    tmp := fmt.tprintf("%s/.list.tmp", dir)
    if !curl(API_URL, tmp) {
        _ = os.remove(tmp)
        return
    }
    entries: []struct {
        name: string,
    }
    data, _ := os.read_entire_file(tmp, context.temp_allocator)
    _ = os.remove(tmp)
    if json.unmarshal(data, &entries, allocator = context.temp_allocator) != nil {
        return
    }
    b := strings.builder_make(context.temp_allocator)
    for e in entries {
        if strings.has_suffix(e.name, ".toml") {
            fmt.sbprintln(&b, strings.trim_suffix(e.name, ".toml"))
        }
    }
    _ = os.write_entire_file(list_file(dir), strings.to_string(b))
}

@(private = "file")
list_file :: proc(dir: string) -> string {
    return fmt.tprintf("%s/.list", dir)
}

@(private = "file")
lines_of :: proc(path: string) -> []string {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return nil
    }
    return strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
}

@(private = "file")
curl :: proc(url, out: string) -> bool {
    state, _, _, err := os.process_exec({command = {"curl", "-fsSL", url, "-o", out}}, context.temp_allocator)
    return err == nil && state.exit_code == 0
}

// The `inherits = "<name>"` row of a helix theme file; "" without one.
@(private = "file")
inherits_of :: proc(file: string) -> string {
    for line in lines_of(file) {
        key, eq, value := strings.partition(line, "=")
        if eq != "" && strings.trim_space(key) == "inherits" {
            return strings.trim(strings.trim_space(value), "\"")
        }
    }
    return ""
}
