package tests

import "core:testing"
import "oket:input"
import "oter:oter"

// A fake layout: letters at their QWERTY scancodes.
@(private = "file")
qwerty :: proc(name: string) -> (input.Code, bool) {
    if len(name) == 1 && name[0] >= 'a' && name[0] <= 'z' {
        return input.Code(4 + int(name[0] - 'a')), true
    }
    if name == ";" {
        return 51, true
    }
    return 0, false
}

@(private = "file")
line_for :: proc(binds: []input.Bind, chord: string, path: []input.Section) -> (string, bool) {
    c, _ := input.chord_parse(chord, qwerty)
    b, ok := input.bind_lookup(binds, c, path)
    return b.line, ok
}

@(private = "file")
load :: proc(binds: ^[dynamic]input.Bind, file: string) -> [dynamic]string {
    defaults := oter.binds_parse(binds, oter.DEFAULT_BINDS, "defaults", qwerty)
    delete(defaults)
    return oter.binds_parse(binds, file, "binds.conf", qwerty)
}

@(private = "file")
PANES := []input.Section{oter.SEC_PANES, oter.SEC_GLOBAL}

@(test)
a_file_row_replaces_the_default :: proc(t: ^testing.T) {
    binds: [dynamic]input.Bind
    defer input.binds_destroy(&binds)
    bad := load(&binds, "[panes]\ny = :sel | :copy @+1\n")
    defer delete(bad)

    testing.expect_value(t, len(bad), 0)
    line, ok := line_for(binds[:], "y", PANES)
    testing.expect(t, ok)
    testing.expect_value(t, line, ":sel | :copy @+1")
    line, _ = line_for(binds[:], "alt+;", PANES) // untouched defaults stay
    testing.expect_value(t, line, ":line :")
}

@(test)
none_unbinds :: proc(t: ^testing.T) {
    binds: [dynamic]input.Bind
    defer input.binds_destroy(&binds)
    bad := load(&binds, "[global]\nctrl+q = none\n")
    defer delete(bad)

    _, ok := line_for(binds[:], "ctrl+q", PANES)
    testing.expect(t, !ok)
}

@(test)
bad_rows_are_reported_and_the_rest_lands :: proc(t: ^testing.T) {
    binds: [dynamic]input.Bind
    defer input.binds_destroy(&binds)
    bad := load(&binds, "[nope]\nnot a row\nctrl+notakey = :quit\n[panes]\ny = :up\n")
    defer {
        for m in bad {
            delete(m)
        }
        delete(bad)
    }

    testing.expect_value(t, len(bad), 3)
    line, _ := line_for(binds[:], "y", PANES)
    testing.expect_value(t, line, ":up")
}

@(test)
the_sidebar_swallows_pane_keys :: proc(t: ^testing.T) {
    binds: [dynamic]input.Bind
    defer input.binds_destroy(&binds)
    bad := load(&binds, "")
    defer delete(bad)

    sidebar := []input.Section{oter.SEC_SIDEBAR, oter.SEC_GLOBAL}
    _, ok := line_for(binds[:], "down", sidebar)
    testing.expect(t, !ok)
    line, _ := line_for(binds[:], "tab", sidebar)
    testing.expect_value(t, line, ":sidebar")
}
