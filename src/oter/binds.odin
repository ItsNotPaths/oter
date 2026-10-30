package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import "oket:input"

SEC_GLOBAL :: input.Section(0)
SEC_PANES :: input.Section(1)
// (hole sidebar-keys :tags (ui input) :sev gap :needs places) the sidebar has no rows: no cursor, no enter.
SEC_SIDEBAR :: input.Section(2) // empty by default, so it swallows the pane keys

SECTION_NAMES := [?]string{"global", "panes", "sidebar"}

// Every default row, in binds.conf's own words. The file is written from these on first start.
DEFAULT_BINDS :: `[global]
ctrl+q      = :quit
alt+;       = :line :
alt+c       = :line
alt+up      = :drawer open
alt+down    = :drawer close
tab         = :sidebar

[panes]
up          = :up
down        = :down
pgup        = :pgup
pgdn        = :pgdn
home        = :top
end         = :bottom
enter       = :enter
right       = :enter
backspace   = :parent
left        = :parent
y           = :mark
e           = ${EDITOR:-vi} $o_src
alt+left    = :focus @-1
alt+right   = :focus @+1
alt+shift+left  = :swap @-1
alt+shift+right = :swap @+1
shift+left  = :sel | :copy @-1
shift+right = :sel | :copy @+1
ctrl+left   = :sel | :move @-1
ctrl+right  = :sel | :move @+1

[sidebar]
`

// Rows from `text` on top of `binds`: a chord already bound is replaced, `none` unbinds it.
// Returns one message per bad row.
binds_parse :: proc(binds: ^[dynamic]input.Bind, text, file: string, resolve: input.Layout_Resolve) -> (bad: [dynamic]string) {
    section := SEC_GLOBAL
    for raw, n in strings.split_lines(text, context.temp_allocator) {
        line := strings.trim_space(raw)
        if line == "" || line[0] == '#' {
            continue
        }
        if line[0] == '[' && line[len(line) - 1] == ']' {
            name := line[1:len(line) - 1]
            found := false
            for s, i in SECTION_NAMES {
                if s == name {
                    section, found = input.Section(i), true
                }
            }
            if !found {
                append(&bad, fmt.aprintf("%s:%d: no section [%s]", file, n + 1, name))
            }
            continue
        }
        eq := strings.index_byte(line, '=')
        if eq < 0 {
            append(&bad, fmt.aprintf("%s:%d: not `chord = line`", file, n + 1))
            continue
        }
        key, value := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])
        chord, ok := input.chord_parse(key, resolve)
        if !ok {
            append(&bad, fmt.aprintf("%s:%d: %s is not a chord", file, n + 1, key))
            continue
        }
        bind_put(binds, chord, value == "none" ? "" : value, section, n + 1)
    }
    return
}

@(private = "file")
bind_put :: proc(binds: ^[dynamic]input.Bind, chord: input.Chord, line: string, section: input.Section, at: int) {
    for &b in binds {
        if b.chord == chord && b.section == section {
            delete(b.line)
            b.line = strings.clone(line)
            return
        }
    }
    append(binds, input.Bind{chord = chord, line = strings.clone(line), section = section, origin = {src = .Config, line = at}})
}

// Defaults, then ~/.config/oter/binds.conf over them. A missing file is written from the defaults.
binds_load :: proc(a: ^App) {
    bad := binds_parse(&a.binds, DEFAULT_BINDS, "defaults", key_layout_code)
    assert(len(bad) == 0, "a default bind row does not parse")
    delete(bad)

    path := binds_path()
    text, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        os.make_directory_all(filepath.dir(path))
        _ = os.write_entire_file(path, DEFAULT_BINDS)
        return
    }
    bad = binds_parse(&a.binds, string(text), path, key_layout_code)
    defer {
        for m in bad {
            delete(m)
        }
        delete(bad)
    }
    if len(bad) > 0 {
        status_set(a, len(bad) == 1 ? bad[0] : fmt.tprintf("%s (and %d more)", bad[0], len(bad) - 1), true)
    }
}

@(private = "file")
binds_path :: proc() -> string {
    base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
    if base == "" {
        base = filepath.join({os.get_env("HOME", context.temp_allocator), ".config"}, context.temp_allocator) or_else ""
    }
    return filepath.join({base, "oter", "binds.conf"}, context.temp_allocator) or_else ""
}

// The key's line for where focus is, run as if typed. True if a row answered.
bind_run :: proc(a: ^App, ev: sdl.KeyboardEvent) -> bool {
    code := input.Code(ev.scancode)
    if input.code_is_modifier(code) {
        return false
    }
    path := a.in_sidebar ? []input.Section{SEC_SIDEBAR, SEC_GLOBAL} : []input.Section{SEC_PANES, SEC_GLOBAL}
    b, ok := input.bind_lookup(a.binds[:], {code, mods_of(ev.mod)}, path)
    if !ok {
        return false
    }
    run_line(a, b.line)
    return true
}

mods_of :: proc(mod: sdl.Keymod) -> (m: input.Mods) {
    if mod & sdl.KMOD_SHIFT != {} {
        m += {.Shift}
    }
    if mod & sdl.KMOD_CTRL != {} {
        m += {.Ctrl}
    }
    if mod & sdl.KMOD_ALT != {} {
        m += {.Alt}
    }
    if mod & sdl.KMOD_GUI != {} {
        m += {.Super}
    }
    return
}

SCANCODE_COUNT :: 512

// The position that types `name` under the current layout (oket's input.odin).
key_layout_code :: proc(name: string) -> (input.Code, bool) {
    if name == "" {
        return 0, false
    }
    for sc in 1 ..< SCANCODE_COUNT {
        if layout_name(input.Code(sc)) == name {
            return input.Code(sc), true
        }
    }
    return 0, false
}

// What a position types under the current layout, "" for keys that type nothing.
layout_name :: proc(code: input.Code) -> string {
    if code == 0 || int(code) >= SCANCODE_COUNT {
        return ""
    }
    key := u32(sdl.GetKeyFromScancode(sdl.Scancode(code), sdl.KMOD_NONE, false))
    if key <= ' ' || key == 0x7f || key >= u32(sdl.K_EXTENDED_MASK) {
        return ""
    }
    buf, n := utf8.encode_rune(rune(key))
    return fmt.tprint(string(buf[:n]))
}
