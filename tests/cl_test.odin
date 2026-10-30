package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import "oter:oter"
import "oter:pane"

@(private = "file")
path :: proc(parts: ..string) -> string {
    p, _ := filepath.join(parts, context.temp_allocator)
    return p
}

@(private = "file")
two_panes :: proc(t: ^testing.T, a: ^oter.App) -> (root: string) {
    err: os.Error
    root, err = os.make_directory_temp("", "oter-cl-*", context.allocator)
    testing.expect(t, err == nil)
    testing.expect(t, os.make_directory(path(root, "left")) == nil)
    testing.expect(t, os.make_directory(path(root, "right")) == nil)
    for name in ([]string{"a.jpg", "b.txt", "c.jpg"}) {
        testing.expect(t, os.write_entire_file(path(root, "left", name), "x") == nil)
    }
    for side in ([]string{"left", "right"}) {
        p: pane.Pane
        pane.open(&p, path(root, side))
        append(&a.panes, p)
    }
    return
}

@(private = "file")
settle :: proc(a: ^oter.App) {
    deadline := time.tick_now()
    for len(a.sends) > 0 && time.tick_since(deadline) < 5 * time.Second {
        oter.jobs_poll(a)
        time.sleep(time.Millisecond)
    }
}

@(private = "file")
teardown :: proc(a: ^oter.App, root: string) {
    for &p in a.panes {
        pane.destroy(&p)
    }
    delete(a.panes)
    delete(a.sends)
    delete(a.status)
    os.remove_all(root)
    delete(root)
}

@(test)
sel_through_a_filter_copies_only_matches :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)
    for &e in a.panes[0].entries {
        e.marked = true
    }

    oter.run_line(&a, ":sel | grep jpg | :copy @+1")
    settle(&a)

    testing.expect(t, os.exists(path(root, "right", "a.jpg")))
    testing.expect(t, os.exists(path(root, "right", "c.jpg")))
    testing.expect(t, !os.exists(path(root, "right", "b.txt")))
    testing.expect_value(t, a.status_err, false)
}

@(test)
a_target_with_no_pane_does_nothing :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":sel | :copy @-1") // nothing left of pane 1
    testing.expect_value(t, len(a.sends), 0)
    testing.expect_value(t, a.status_err, false)
}

@(test)
a_failing_filter_stops_the_chain :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":sel | false | :copy @+1")
    testing.expect_value(t, len(a.sends), 0)
    testing.expect(t, a.status_err)
}

@(test)
a_copy_into_its_own_dir_is_refused :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":copy .")
    testing.expect_value(t, len(a.sends), 0)
    testing.expect(t, a.status_err)
}

@(test)
an_unknown_builtin_reports :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":nope")
    testing.expect(t, a.status_err)
}
