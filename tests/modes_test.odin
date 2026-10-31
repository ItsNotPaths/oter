package tests

import "core:testing"
import "oter:oter"
import "oter:pane"

@(private = "file")
one_pane :: proc(a: ^oter.App, mode: oter.Mode) {
    append(&a.panes, pane.Pane{})
    a.mode = mode
}

@(private = "file")
teardown :: proc(a: ^oter.App) {
    for &p in a.panes {
        pane.destroy(&p)
    }
    delete(a.panes)
    delete(a.status)
}

@(test)
tab_goes_between_panes_and_sidebar :: proc(t: ^testing.T) {
    a: oter.App
    one_pane(&a, .Panes)
    defer teardown(&a)

    oter.run_line(&a, ":sidebar")
    testing.expect_value(t, a.mode, oter.Mode.Sidebar)
    oter.run_line(&a, ":sidebar")
    testing.expect_value(t, a.mode, oter.Mode.Panes)
}

@(test)
the_sidebar_opens_no_line_or_tray :: proc(t: ^testing.T) {
    a: oter.App
    one_pane(&a, .Sidebar)
    defer teardown(&a)

    oter.run_line(&a, ":stage")
    testing.expect_value(t, a.mode, oter.Mode.Sidebar)
    oter.run_line(&a, ":drawer open")
    testing.expect_value(t, a.mode, oter.Mode.Sidebar)
    testing.expect_value(t, a.drawer, oter.Drawer.Closed)
}

@(test)
the_terminal_offshoot_opens_no_sidebar :: proc(t: ^testing.T) {
    for mode in ([]oter.Mode{.Line, .Term}) {
        a: oter.App
        one_pane(&a, mode)
        defer teardown(&a)

        oter.run_line(&a, ":sidebar")
        testing.expect_value(t, a.mode, mode)
    }
}
