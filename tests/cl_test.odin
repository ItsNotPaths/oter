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
    oter.config_load(a) // no home: the defaults
    return
}

@(private = "file")
settle :: proc(a: ^oter.App) {
    deadline := time.tick_now()
    for (len(a.sends) > 0 || a.filter != nil) && time.tick_since(deadline) < 5 * time.Second {
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
    oter.config_destroy(&a.config)
    os.remove_all(root)
    delete(root)
}

@(test)
sel_through_a_filter_copies_only_matches :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)
    for _ in a.panes[0].entries {
        pane.toggle_mark(&a.panes[0])
        pane.move(&a.panes[0], 1)
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
    settle(&a)
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

// Space down marks, held down paints each row moved onto, a key repeat changes nothing.
@(test)
holding_the_mark_key_paints_a_run :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)
    p := &a.panes[0] // a.jpg, b.txt, c.jpg

    a.key = {code = 44}
    oter.run_line(&a, ":mark")
    a.key.repeat = true
    oter.run_line(&a, ":mark")
    a.key = {}
    oter.run_line(&a, ":down")
    oter.run_line(&a, ":down")
    testing.expect_value(t, len(p.marks), 3)

    a.paint = nil // the key came up
    oter.run_line(&a, ":up")
    testing.expect_value(t, len(p.marks), 3)
}

// The staged delete: every mark goes, the pane re-lists, the yank empties.
@(test)
deleting_the_selection_removes_the_marked_files :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)
    p := &a.panes[0] // a.jpg, b.txt, c.jpg
    pane.toggle_mark(p)
    pane.move(p, 2)
    pane.toggle_mark(p)

    oter.run_line(&a, ":sel | xargs -d '\\n' rm -rf --")
    settle(&a)
    testing.expect(t, !os.exists(path(root, "left", "a.jpg")))
    testing.expect(t, !os.exists(path(root, "left", "c.jpg")))
    testing.expect(t, os.exists(path(root, "left", "b.txt")))
    testing.expect_value(t, len(p.entries), 1)
    testing.expect_value(t, len(p.marks), 0)
}

@(test)
np_opens_a_pane_right_of_the_focused_one_at_its_dir :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":np")
    testing.expect_value(t, len(a.panes), 3)
    testing.expect_value(t, a.active, 1)
    testing.expect_value(t, a.panes[1].dir, a.panes[0].dir)
    testing.expect_value(t, a.panes[2].dir, path(root, "right"))
}

@(test)
close_drops_the_focused_pane_but_never_the_last :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    a.active = 1
    oter.run_line(&a, ":close")
    testing.expect_value(t, len(a.panes), 1)
    testing.expect_value(t, a.active, 0)
    testing.expect_value(t, a.panes[0].dir, path(root, "left"))

    oter.run_line(&a, ":close")
    testing.expect_value(t, len(a.panes), 1)
}

// A slow filter runs off the main thread: the line returns at once, and the chain ends after it.
@(test)
a_slow_filter_does_not_block :: proc(t: ^testing.T) {
    a: oter.App
    root := two_panes(t, &a)
    defer teardown(&a, root)

    start := time.tick_now()
    oter.run_line(&a, ":sel | sleep 0.3 && cat | :copy @+1")
    testing.expect(t, time.tick_since(start) < 100 * time.Millisecond)
    testing.expect(t, a.chain.waiting)

    settle(&a)
    testing.expect(t, !a.chain.waiting)
    testing.expect(t, os.exists(path(root, "right", "a.jpg")))
}
