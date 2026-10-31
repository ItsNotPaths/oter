package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
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
settle :: proc(a: ^oter.App) {
    start := time.tick_now()
    for (len(a.listings) > 0 || len(a.sends) > 0) && time.tick_since(start) < 5 * time.Second {
        oter.jobs_poll(a)
        time.sleep(time.Millisecond)
    }
}

// Pane 0 inside nested.zip, pane 1 on an empty temp dir.
@(private = "file")
archive_and_real :: proc(t: ^testing.T, a: ^oter.App) -> (root: string) {
    root, _ = os.make_directory_temp("", "oter-arc-*", context.allocator)
    left, right: pane.Pane
    pane.open(&left, DATA)
    cursor_on(&left, "nested.zip")
    pane.open(&right, root)
    append(&a.panes, left, right)
    oter.config_load(a)
    oter.run_line(a, ":enter")
    settle(a)
    testing.expect_value(t, a.panes[0].dir, ZIP)
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
    oter.archives_destroy(a)
    oter.config_destroy(&a.config)
    os.remove_all(root)
    delete(root)
}

@(private = "file")
read :: proc(parts: ..string) -> string {
    path, _ := filepath.join(parts, context.temp_allocator)
    data, err := os.read_entire_file(path, context.temp_allocator)
    return err == nil ? string(data) : "<missing>"
}

@(test)
an_archive_opens_as_a_dir :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    p := &a.panes[0]
    testing.expect(t, !pane.is_real(p))
    got := names(p)
    testing.expect_value(t, len(got), 3)
    testing.expect_value(t, got[0], "docs/")
    testing.expect_value(t, got[1], "empty/")
    testing.expect_value(t, got[2], "top.txt")
}

@(test)
dirs_inside_an_archive_browse_and_up_leaves_it :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    p := &a.panes[0]
    cursor_on(p, "docs")
    testing.expect(t, pane.enter(p))
    got := names(p)
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0], "deep/")
    testing.expect_value(t, got[1], "a.txt")

    pane.up(p)
    testing.expect_value(t, p.dir, ZIP)
    pane.up(p)
    testing.expect_value(t, p.dir, DATA)
    testing.expect(t, pane.is_real(p))
    e, _ := pane.current(p)
    testing.expect_value(t, e.name, "nested.zip")
}

@(test)
going_back_into_an_archive_is_instant :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    pane.up(&a.panes[0])
    oter.run_line(&a, ":enter")
    testing.expect_value(t, a.panes[0].dir, ZIP) // no settle: the listing is kept
}

@(test)
enter_on_a_plain_file_does_nothing :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)
    testing.expect(t, os.write_entire_file(filepath.join({root, "plain.txt"}, context.temp_allocator) or_else "", "x") == nil)

    a.active = 1
    pane.relist(&a.panes[1])
    oter.run_line(&a, ":enter")
    settle(&a)
    testing.expect_value(t, a.panes[1].dir, root)
    testing.expect(t, !a.status_err)
}

@(test)
open_takes_a_path_inside_an_archive :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, fmt.tprintf(":open %s/docs/deep @2", ZIP))
    settle(&a)
    testing.expect_value(t, a.panes[1].dir, ZIP + "/docs/deep")
    testing.expect_value(t, names(&a.panes[1])[0], "b.txt")
}

@(test)
a_new_pane_opens_where_the_archive_pane_is :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":np")
    testing.expect_value(t, len(a.panes), 3)
    testing.expect_value(t, a.panes[1].dir, ZIP)
    testing.expect(t, !pane.is_real(&a.panes[1]))
}

@(test)
files_and_dirs_copy_out_of_an_archive :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    p := &a.panes[0]
    for name in ([]string{"docs", "top.txt"}) {
        cursor_on(p, name)
        pane.toggle_mark(p)
    }
    oter.run_line(&a, ":copy @+1")
    settle(&a)

    testing.expect(t, !a.status_err)
    testing.expect_value(t, read(root, "top.txt"), "top")
    testing.expect_value(t, read(root, "docs", "a.txt"), "a")
    testing.expect_value(t, read(root, "docs", "deep", "b.txt"), "b")
}

@(test)
copy_out_never_overwrites :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)
    testing.expect(t, os.write_entire_file(filepath.join({root, "top.txt"}, context.temp_allocator) or_else "", "mine") == nil)

    cursor_on(&a.panes[0], "top.txt")
    oter.run_line(&a, ":copy @+1")
    settle(&a)

    testing.expect_value(t, read(root, "top.txt"), "mine")
    testing.expect(t, strings.contains(a.status, "skipped 1"))
}

@(test)
marks_inside_an_archive_survive_a_relist :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    p := &a.panes[0]
    cursor_on(p, "top.txt")
    pane.toggle_mark(p)
    pane.relist(p)
    testing.expect_value(t, len(p.marks), 1)
}

@(test)
no_shell_runs_inside_an_archive :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, "touch oops")
    testing.expect(t, a.status_err)
    oter.run_line(&a, ":sel | cat")
    testing.expect(t, a.status_err)
    testing.expect(t, a.filter == nil)
}

@(test)
nothing_moves_out_of_or_lands_in_an_archive :: proc(t: ^testing.T) {
    a: oter.App
    root := archive_and_real(t, &a)
    defer teardown(&a, root)

    cursor_on(&a.panes[0], "top.txt")
    oter.run_line(&a, ":move @+1")
    testing.expect(t, a.status_err)
    a.active = 1
    oter.run_line(&a, ":copy @-1")
    testing.expect(t, a.status_err)
    testing.expect_value(t, len(a.sends), 0)
}
