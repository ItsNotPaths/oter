package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "oter:oter"
import "oter:pane"

// top.txt, docs/a.txt, docs/deep/b.txt (docs/ implied, no entry), empty/ (an entry).
@(private = "file")
DATA :: #directory + "data"

@(private = "file")
ZIP :: DATA + "/nested.zip"

@(private = "file")
names :: proc(p: ^pane.Pane) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for e in p.entries {
        append(&out, e.is_dir ? fmt.tprintf("%s/", e.name) : e.name)
    }
    return out[:]
}

@(private = "file")
cursor_on :: proc(p: ^pane.Pane, name: string) {
    for e, i in p.entries {
        if e.name == name {
            p.cursor = i
        }
    }
}

@(private = "file")
into_zip :: proc(t: ^testing.T, p: ^pane.Pane) {
    pane.open(p, DATA)
    cursor_on(p, "nested.zip")
    entered, err := pane.enter(p)
    testing.expect(t, entered)
    testing.expect_value(t, err, "")
}

@(test)
an_archive_opens_as_a_dir :: proc(t: ^testing.T) {
    p: pane.Pane
    defer pane.destroy(&p)
    into_zip(t, &p)

    testing.expect_value(t, p.dir, ZIP)
    testing.expect(t, !pane.is_real(&p))
    got := names(&p)
    testing.expect_value(t, len(got), 3)
    testing.expect_value(t, got[0], "docs/")
    testing.expect_value(t, got[1], "empty/")
    testing.expect_value(t, got[2], "top.txt")
}

@(test)
dirs_inside_an_archive_browse_and_up_leaves_it :: proc(t: ^testing.T) {
    p: pane.Pane
    defer pane.destroy(&p)
    into_zip(t, &p)

    cursor_on(&p, "docs")
    entered, _ := pane.enter(&p)
    testing.expect(t, entered)
    got := names(&p)
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0], "deep/")
    testing.expect_value(t, got[1], "a.txt")

    pane.up(&p)
    testing.expect_value(t, p.dir, ZIP)
    pane.up(&p)
    testing.expect_value(t, p.dir, DATA)
    testing.expect(t, pane.is_real(&p))
    e, _ := pane.current(&p)
    testing.expect_value(t, e.name, "nested.zip")
}

@(test)
marks_inside_an_archive_survive_a_relist :: proc(t: ^testing.T) {
    p: pane.Pane
    defer pane.destroy(&p)
    into_zip(t, &p)

    cursor_on(&p, "top.txt")
    pane.toggle_mark(&p)
    pane.relist(&p)
    testing.expect_value(t, len(p.marks), 1)
}

@(private = "file")
archive_and_real :: proc(a: ^oter.App) -> (root: string) {
    root, _ = os.make_directory_temp("", "oter-arc-*", context.allocator)
    left, right: pane.Pane
    pane.open(&left, DATA)
    cursor_on(&left, "nested.zip")
    pane.enter(&left)
    pane.open(&right, root)
    append(&a.panes, left, right)
    oter.config_load(a)
    return
}

@(private = "file")
teardown :: proc(a: ^oter.App, root: string) {
    for &p in a.panes {
        pane.destroy(&p)
    }
    delete(a.panes)
    delete(a.sends)
    delete(a.status)
    oter.config_destroy(&a.config)
    os.remove_all(root)
    delete(root)
}

@(test)
no_shell_runs_inside_an_archive :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(&a)
    defer teardown(&a, root)

    oter.run_line(&a, "touch oops")
    testing.expect(t, a.status_err)
    oter.run_line(&a, ":sel | cat")
    testing.expect(t, a.status_err)
    testing.expect(t, a.filter == nil)
}

@(test)
nothing_is_copied_out_of_or_into_an_archive :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(&a)
    defer teardown(&a, root)

    oter.run_line(&a, ":copy @+1")
    testing.expect(t, a.status_err)
    a.active = 1
    oter.run_line(&a, ":copy @-1")
    testing.expect(t, a.status_err)
    testing.expect_value(t, len(a.sends), 0)
}
