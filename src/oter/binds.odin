package oter

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import "oket:input"
import "../pane"

SEC_GLOBAL :: input.Section(0)
SEC_PANES :: input.Section(1)
SEC_SIDEBAR :: input.Section(2) // no pane rows, so it swallows the pane keys
SEC_PICK :: input.Section(3) // the file dialog's pick pane, before its pane rows

SECTION_NAMES := [?]string{"global", "panes", "sidebar", "pick"}

// Every default row, in binds.conf's own words. The file is written from these on first start.
DEFAULT_BINDS :: `[global]
ctrl+q      = :quit
alt+;       = :stage :
alt+c       = :stage
alt+up      = :drawer open
alt+down    = :drawer close
alt+p       = :np
alt+q       = :close
ctrl+@AE12  = :font.bigger
ctrl+-      = :font.smaller
ctrl+0      = :font.reset
tab         = :sidebar
alt+enter   = :stage :confirm
alt+t       = :oter theme

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
space       = :mark
esc         = :unmark
shift+esc   = :unmark $o_dir
del         = :stage :sel | xargs -d '\n' rm -rf --
alt+r       = :stage mv -- $o_name
alt+n       = :stage mkdir --
e           = $OTER_EDITOR $o_src
w           = :preview
alt+left    = :focus @-1
alt+right   = :focus @+1
alt+shift+left  = :swap @-1
alt+shift+right = :swap @+1
shift+left  = :sel | :copy @-1
shift+right = :sel | :copy @+1
ctrl+left   = :sel | :move @-1
ctrl+right  = :sel | :move @+1

[sidebar]
esc         = :sidebar
up          = :place cur -1
down        = :place cur +1
shift+up    = :place move -1
shift+down  = :place move +1
a           = :place set $o_dir
s           = :place set =-=-=-=-=-=-=-=
d           = :place clear
enter       = :open $o_src
1           = :open $o_src @1
2           = :open $o_src @2
3           = :open $o_src @3
4           = :open $o_src @4
5           = :open $o_src @5
6           = :open $o_src @6
7           = :open $o_src @7
8           = :open $o_src @8
9           = :open $o_src @9

[pick]
del         = :unpick
`

// Rows from `text` on top of `binds`: a chord already bound is replaced, `none` unbinds it.
// Returns one message per bad row.
binds_parse :: proc(binds: ^[dynamic]input.Bind, text, file: string, resolve: input.Layout_Resolve) -> (bad: [dynamic]string) {
    for r in conf_rows(text, file, SECTION_NAMES[:], &bad) {
        chord, ok := input.chord_parse(r.key, resolve)
        if !ok {
            append(&bad, fmt.aprintf("%s:%d: %s is not a chord", file, r.line, r.key))
            continue
        }
        bind_put(binds, chord, r.value == "none" ? "" : r.value, input.Section(r.section), r.line)
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

// Defaults, then binds.conf over them.
binds_load :: proc(a: ^App) {
    bad := binds_parse(&a.binds, DEFAULT_BINDS, "defaults", key_layout_code)
    assert(len(bad) == 0, "a default bind row does not parse")
    delete(bad)
    if text, path, found := conf_read(a, "binds.conf", DEFAULT_BINDS); found {
        report_bad(a, binds_parse(&a.binds, text, path, key_layout_code))
    }
}

// The key's line for where focus is, run as if typed. True if a row answered.
bind_run :: proc(a: ^App, ev: sdl.KeyboardEvent) -> bool {
    code := input.Code(ev.scancode)
    if input.code_is_modifier(code) {
        return false
    }
    path := []input.Section{SEC_PANES, SEC_GLOBAL}
    if a.mode == .Sidebar {
        path = {SEC_SIDEBAR, SEC_GLOBAL}
    } else if pane.is_pick(&a.panes[a.active]) {
        path = {SEC_PICK, SEC_PANES, SEC_GLOBAL}
    }
    b, ok := input.bind_lookup(a.binds[:], {code, mods_of(ev.mod)}, path)
    if !ok {
        return false
    }
    a.key = {code, ev.repeat}
    run_line(a, b.line)
    a.key = {}
    return true
}
