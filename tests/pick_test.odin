package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "oter:oter"
import "oter:pane"

@(private = "file")
path :: proc(parts: ..string) -> string {
    p, _ := filepath.join(parts, context.temp_allocator)
    return p
}

// A dialog over a dir holding a.png, b.png and sub/.
@(private = "file")
dialog :: proc(t: ^testing.T, a: ^oter.App, want: pane.Want, suggested := "") -> (root: string) {
    err: os.Error
    root, err = os.make_directory_temp("", "oter-pick-*", context.allocator)
    testing.expect(t, err == nil)
    testing.expect(t, os.make_directory(path(root, "sub")) == nil)
    for name in ([]string{"a.png", "b.png"}) {
        testing.expect(t, os.write_entire_file(path(root, name), "x") == nil)
    }
    start := suggested != "" ? path(root, suggested) : root
    oter.pick_open(a, {want, start, path(root, "out")}, root)
    a.running = true
    return
}

@(private = "file")
teardown :: proc(a: ^oter.App, root: string) {
    for &p in a.panes {
        pane.destroy(&p)
    }
    delete(a.panes)
    delete(a.status)
    os.remove_all(root)
    delete(root)
}

// Puts the cursor of the file pane on `name` and throws it to the pick pane.
@(private = "file")
throw :: proc(a: ^oter.App, name: string) {
    a.active = 1
    p := &a.panes[1]
    for e, i in p.entries {
        if e.name == name {
            p.cursor = i
        }
    }
    oter.run_line(a, ":sel | :copy @-1")
}

@(private = "file")
rows :: proc(a: ^oter.App) -> []string {
    return pane.picked(&a.panes[0])
}

@(test)
one_file_keeps_the_last_thrown :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .File)
    defer teardown(&a, root)

    throw(&a, "a.png")
    throw(&a, "b.png")
    testing.expect_value(t, len(rows(&a)), 1)
    testing.expect_value(t, rows(&a)[0], path(root, "b.png"))
    testing.expect(t, os.exists(path(root, "b.png")), "nothing on disk moves")
}

@(test)
files_keep_every_one_thrown :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .Files)
    defer teardown(&a, root)

    throw(&a, "a.png")
    throw(&a, "b.png")
    throw(&a, "a.png")
    testing.expect_value(t, len(rows(&a)), 2)
}

@(test)
the_wrong_kind_is_refused :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .Dir)
    defer teardown(&a, root)

    throw(&a, "a.png")
    testing.expect_value(t, len(rows(&a)), 0)
    testing.expect(t, a.status_err)
    throw(&a, "sub")
    testing.expect_value(t, len(rows(&a)), 1)
}

@(test)
save_keeps_the_name_in_a_thrown_folder :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .Save, "new.png")
    defer teardown(&a, root)

    testing.expect_value(t, rows(&a)[0], path(root, "new.png"))
    throw(&a, "sub")
    testing.expect_value(t, len(rows(&a)), 1)
    testing.expect_value(t, rows(&a)[0], path(root, "sub", "new.png"))
}

@(test)
rename_changes_only_the_name :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .Save, "new.png")
    defer teardown(&a, root)

    a.active = 0
    oter.run_line(&a, "mv -- new.png other.png")
    testing.expect_value(t, rows(&a)[0], path(root, "other.png"))
    oter.run_line(&a, "mv -- other.png sub/other.png")
    testing.expect(t, a.status_err)
    testing.expect_value(t, rows(&a)[0], path(root, "other.png"))
    oter.run_line(&a, "rm -rf -- other.png")
    testing.expect(t, a.status_err, "no shell in the pick pane")
}

@(test)
move_back_and_unpick_drop_rows :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .Files)
    defer teardown(&a, root)
    throw(&a, "a.png")
    throw(&a, "b.png")

    a.active = 0
    a.panes[0].cursor = 0
    oter.run_line(&a, ":sel | :copy @+1")
    testing.expect_value(t, len(rows(&a)), 1)
    throw(&a, "a.png")
    a.active = 0
    a.panes[0].cursor = 0
    oter.run_line(&a, ":sel | :move @+1")
    testing.expect_value(t, len(rows(&a)), 1)
    oter.run_line(&a, ":unpick")
    testing.expect_value(t, len(rows(&a)), 0)
    testing.expect(t, os.exists(path(root, "a.png")) && os.exists(path(root, "b.png")), "nothing on disk moves")
}

@(test)
confirm_answers_and_quits :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .Files)
    defer teardown(&a, root)
    throw(&a, "a.png")
    throw(&a, "b.png")

    oter.run_line(&a, ":confirm")
    testing.expect(t, !a.running)
    out, _ := os.read_entire_file(path(root, "out"), context.temp_allocator)
    testing.expect_value(t, string(out), fmt.tprintf("%s\n%s\n", path(root, "a.png"), path(root, "b.png")))
}

@(test)
quitting_answers_nothing :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .File)
    defer teardown(&a, root)
    throw(&a, "a.png")

    oter.run_line(&a, ":quit")
    testing.expect(t, !a.running)
    testing.expect(t, !os.exists(path(root, "out")))
}

@(test)
the_pick_pane_stays :: proc(t: ^testing.T) {
    a: oter.App
    root := dialog(t, &a, .File)
    defer teardown(&a, root)

    a.active = 0
    oter.run_line(&a, ":close")
    oter.run_line(&a, fmt.tprintf(":open %s @1", root))
    testing.expect_value(t, len(a.panes), 2)
    testing.expect(t, pane.is_pick(&a.panes[0]))
}
