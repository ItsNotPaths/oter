package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "oter:pane"

@(private = "file")
make_tree :: proc(t: ^testing.T) -> string {
    root, err := os.make_directory_temp("", "oter-test-*", context.allocator)
    testing.expect(t, err == nil)
    for d in ([]string{"zeta", "Alpha"}) {
        path, _ := filepath.join({root, d}, context.temp_allocator)
        testing.expect(t, os.make_directory(path) == nil)
    }
    for f in ([]string{"b.txt", "A.txt"}) {
        path, _ := filepath.join({root, f}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, []u8{}) == nil)
    }
    return root
}

@(test)
dirs_come_first_then_names_ignore_case :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)

    names: [dynamic]string
    defer delete(names)
    for e in p.entries {
        append(&names, e.name)
    }
    testing.expect_value(t, len(names), 4)
    testing.expect_value(t, names[0], "Alpha")
    testing.expect_value(t, names[1], "zeta")
    testing.expect_value(t, names[2], "A.txt")
    testing.expect_value(t, names[3], "b.txt")
}

@(test)
going_up_selects_the_dir_we_left :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)
    p.cursor = 1 // zeta
    entered, _ := pane.enter(&p)
    testing.expect(t, entered)
    pane.up(&p)

    e, ok := pane.current(&p)
    testing.expect(t, ok)
    testing.expect_value(t, e.name, "zeta")
}

@(test)
enter_on_a_file_does_nothing :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)
    p.cursor = 2 // A.txt
    entered, _ := pane.enter(&p)
    testing.expect(t, !entered)
    testing.expect_value(t, p.dir, root)
}

@(test)
cursor_stays_in_view_and_in_range :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)

    pane.move(&p, +100)
    testing.expect_value(t, p.cursor, 3)
    pane.scroll(&p, 2)
    testing.expect_value(t, p.top, 2)

    pane.move(&p, -100)
    testing.expect_value(t, p.cursor, 0)
    pane.scroll(&p, 2)
    testing.expect_value(t, p.top, 0)
}

@(test)
selection_is_marks_else_cursor :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root) // Alpha, zeta, A.txt, b.txt

    sel := pane.selection(&p)
    testing.expect_value(t, len(sel), 1)
    testing.expect_value(t, filepath.base(sel[0]), "Alpha")

    pane.move(&p, 2)
    pane.toggle_mark(&p) // A.txt
    pane.move(&p, 1)
    pane.toggle_mark(&p) // b.txt
    sel = pane.selection(&p)
    testing.expect_value(t, len(sel), 2)
    testing.expect_value(t, sel[0], filepath.join({root, "A.txt"}, context.temp_allocator) or_else "")
    testing.expect_value(t, filepath.base(sel[1]), "b.txt")

    pane.toggle_mark(&p) // unmark b.txt
    testing.expect_value(t, len(pane.selection(&p)), 1)
}

// Yank in one folder, go into another, yank more: the selection holds both.
@(test)
marks_survive_a_folder_change :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}
    inner, _ := filepath.join({root, "zeta", "c.txt"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(inner, []u8{}) == nil)

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root) // Alpha, zeta, A.txt, b.txt
    pane.move(&p, 2)
    pane.toggle_mark(&p) // A.txt
    pane.move(&p, -1)
    pane.enter(&p) // zeta: c.txt
    pane.toggle_mark(&p)

    sel := pane.selection(&p)
    testing.expect_value(t, len(sel), 2)
    testing.expect_value(t, filepath.base(sel[0]), "A.txt")
    testing.expect_value(t, sel[1], inner)

    pane.up(&p)
    testing.expect(t, pane.is_marked(&p, p.entries[2]), "A.txt lost its mark on the way back")
}

@(test)
unmark_a_dir_drops_only_its_marks :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}
    inner, _ := filepath.join({root, "zeta", "c.txt"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(inner, []u8{}) == nil)

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)
    pane.move(&p, 2)
    pane.toggle_mark(&p) // A.txt
    pane.open(&p, filepath.dir(inner))
    pane.toggle_mark(&p) // c.txt

    pane.unmark(&p, p.dir)
    sel := pane.selection(&p)
    testing.expect_value(t, len(p.marks), 1)
    testing.expect_value(t, filepath.base(sel[0]), "A.txt")

    pane.unmark(&p)
    testing.expect_value(t, len(p.marks), 0)
}

// A deleted or renamed file stops being yanked once the pane re-lists.
@(test)
relist_drops_marks_on_gone_paths :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)
    pane.move(&p, 2)
    pane.toggle_mark(&p) // A.txt
    pane.move(&p, 1)
    pane.toggle_mark(&p) // b.txt
    testing.expect(t, os.remove(pane.path_of(&p, "b.txt")) == nil)

    pane.relist(&p)
    testing.expect_value(t, len(p.marks), 1)
    testing.expect_value(t, filepath.base(p.marks[0]), "A.txt")
}

@(test)
relist_shows_new_files_and_keeps_cursor :: proc(t: ^testing.T) {
    root := make_tree(t)
    defer {os.remove_all(root); delete(root)}

    p: pane.Pane
    defer pane.destroy(&p)
    pane.open(&p, root)
    pane.move(&p, 3) // b.txt
    testing.expect(t, os.write_entire_file(filepath.join({root, "a2.txt"}, context.temp_allocator) or_else "", []u8{}) == nil)

    pane.relist(&p)
    testing.expect_value(t, p.err, nil)
    testing.expect_value(t, len(p.entries), 5)
    e, _ := pane.current(&p)
    testing.expect_value(t, e.name, "b.txt")
}
