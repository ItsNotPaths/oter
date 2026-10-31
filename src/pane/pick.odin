package pane

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

is_pick :: proc(p: ^Pane) -> bool {
    _, ok := p.src.(Pick)
    return ok
}

// Makes `p` the pick pane. Save starts with its suggested path as the one row.
open_pick :: proc(p: ^Pane, want: Want, suggested := "") {
    drop_source(p)
    s := Pick{want = want}
    if want == .Save && suggested != "" {
        append(&s.paths, strings.clone(suggested))
    }
    p.src = s
    show(p, "")
}

picked :: proc(p: ^Pane) -> []string {
    return p.src.(Pick).paths[:]
}

// Puts `path` in the pick pane. "" when it landed, else why not.
pick_add :: proc(p: ^Pane, path: string) -> string {
    s := &p.src.(Pick)
    row := path
    is_dir := os.is_dir(path)
    switch s.want {
    case .Dir:
        if !is_dir {
            return "pick a folder, not a file"
        }
    case .File, .Files:
        if is_dir {
            return "pick files, not a folder"
        }
    case .Save:
        if is_dir { // a folder keeps the name
            if len(s.paths) == 0 {
                return "no name to save as yet: throw a file"
            }
            row = filepath.join({path, filepath.base(s.paths[0])}, context.temp_allocator) or_else ""
        }
    }
    if s.want != .Files {
        pick_drop(p, s.paths[:])
    }
    if !slice.contains(s.paths[:], row) {
        append(&s.paths, strings.clone(row))
    }
    show(p, "", row)
    return ""
}

// Takes `paths` out of the pick pane, marks with them.
pick_drop :: proc(p: ^Pane, paths: []string) {
    s := &p.src.(Pick)
    gone := make([dynamic]string, context.temp_allocator) // `paths` may be s.paths itself
    for path in paths {
        append(&gone, strings.clone(path, context.temp_allocator))
    }
    for path in gone {
        if i := mark_index(p, path); i >= 0 {
            delete(p.marks[i])
            ordered_remove(&p.marks, i)
        }
        #reverse for q, i in s.paths {
            if q == path {
                delete(q)
                ordered_remove(&s.paths, i)
            }
        }
    }
    relist(p)
}

// Renames the row named `old` to `new` in the same folder. "" when done, else why not.
pick_rename :: proc(p: ^Pane, old, new: string) -> string {
    if new == "" || strings.contains_rune(new, '/') {
        return "a new name only, no folder"
    }
    s := &p.src.(Pick)
    for &q in s.paths {
        if filepath.base(q) == old {
            row := filepath.join({filepath.dir(q), new}) or_else ""
            delete(q)
            q = row
            show(p, "", row)
            return ""
        }
    }
    return "no row by that name"
}

