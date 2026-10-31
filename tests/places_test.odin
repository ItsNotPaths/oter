package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oter:oter"
import "oter:pane"

@(private = "file")
path :: proc(parts: ..string) -> string {
    p, _ := filepath.join(parts, context.temp_allocator)
    return p
}

// Two panes at root; places `root/here` (a dir) and `root/gone` (not one); focus in the sidebar.
@(private = "file")
setup :: proc(t: ^testing.T, a: ^oter.App) -> (root: string) {
    err: os.Error
    root, err = os.make_directory_temp("", "oter-places-*", context.allocator)
    testing.expect(t, err == nil)
    testing.expect(t, os.make_directory(path(root, "here")) == nil)
    oter.places_parse(&a.places, strings.concatenate({path(root, "here"), "\n\n", path(root, "gone"), "\n"}, context.temp_allocator))
    a.places_file = strings.clone(path(root, "places"))
    for _ in 0 ..< 2 {
        p: pane.Pane
        pane.open(&p, root)
        append(&a.panes, p)
    }
    a.mode = .Sidebar
    return
}

@(private = "file")
teardown :: proc(a: ^oter.App, root: string) {
    os.remove_all(root)
    delete(root)
    for &p in a.panes {
        pane.destroy(&p)
    }
    delete(a.panes)
    oter.places_clear(&a.places)
    delete(a.places)
    delete(a.places_file)
    delete(a.status)
}

@(private = "file")
saved :: proc(a: ^oter.App) -> string {
    data, _ := os.read_entire_file(a.places_file, context.temp_allocator)
    return string(data)
}

@(test)
a_blank_line_is_an_empty_slot :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    testing.expect_value(t, len(a.places), 3)
    testing.expect(t, a.places[0].ok)
    testing.expect_value(t, a.places[1].text, "")
    testing.expect(t, !a.places[2].ok)
}

@(test)
tilde_is_home :: proc(t: ^testing.T) {
    places: [dynamic]oter.Place
    defer {
        oter.places_clear(&places)
        delete(places)
    }
    oter.places_parse(&places, "~\n~/x\n")
    home := os.get_env("HOME", context.temp_allocator)
    testing.expect_value(t, places[0].path, home)
    testing.expect_value(t, places[1].path, strings.concatenate({home, "/x"}, context.temp_allocator))
    testing.expect_value(t, places[1].text, "~/x")
}

@(test)
open_lands_in_the_named_pane_and_leaves_the_sidebar :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":open $o_src @2")
    testing.expect_value(t, a.panes[1].dir, path(root, "here"))
    testing.expect_value(t, a.panes[0].dir, root)
    testing.expect_value(t, a.active, 1)
    testing.expect_value(t, a.mode, oter.Mode.Panes)
}

@(test)
open_without_a_dir_or_pane_stays_put :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    a.place = 2 // `gone`, so no $o_src
    for line in ([]string{":open $o_src", ":open ~ @3", ":open /no/such/dir"}) {
        a.status_err = false
        oter.run_line(&a, line)
        testing.expect_value(t, a.panes[0].dir, root)
        testing.expect_value(t, a.mode, oter.Mode.Sidebar)
        testing.expect(t, a.status_err)
    }
}

@(test)
set_replaces_the_slot_under_the_cursor_and_saves :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":place set $o_dir")
    testing.expect_value(t, len(a.places), 3)
    testing.expect_value(t, a.places[0].path, root)
    testing.expect_value(t, saved(&a), strings.concatenate({root, "\n\n", path(root, "gone"), "\n"}, context.temp_allocator))
}

@(test)
set_past_the_end_fills_the_gap_with_empty_slots :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    a.frame.sidebar.grid.rows = 10 // a header and 9 slots on screen
    oter.run_line(&a, ":place set 5 =-= music =-=")
    testing.expect_value(t, len(a.places), 5)
    testing.expect_value(t, a.places[3].text, "")
    testing.expect_value(t, a.places[4].text, "=-= music =-=")
}

@(test)
clear_leaves_a_gap_and_numbers_stay :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":place clear 1")
    testing.expect_value(t, len(a.places), 3)
    testing.expect_value(t, a.places[0].text, "")
    testing.expect_value(t, a.places[2].path, path(root, "gone"))
    oter.run_line(&a, ":place clear 3")
    testing.expect_value(t, saved(&a), "") // trailing empty slots are not written
}

@(test)
move_swaps_with_the_next_slot :: proc(t: ^testing.T) {
    a: oter.App
    root := setup(t, &a)
    defer teardown(&a, root)

    oter.run_line(&a, ":place move +1")
    testing.expect_value(t, a.places[0].text, "")
    testing.expect_value(t, a.places[1].path, path(root, "here"))
    testing.expect_value(t, a.place, 1)
}
