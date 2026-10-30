package pane

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Entry :: struct {
    name:   string,
    is_dir: bool,
    marked: bool,
}

Pane :: struct {
    dir:     string,
    entries: [dynamic]Entry,
    cursor:  int,
    top:     int, // first visible row
    err:     os.Error,
}

// Dirs first, then by name, case-insensitive.
entry_less :: proc(a, b: Entry) -> bool {
    if a.is_dir != b.is_dir {
        return a.is_dir
    }
    return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
}

// Lists `dir` and puts the cursor on `select`, if it is there.
open :: proc(p: ^Pane, dir: string, select := "") {
    clear_entries(p)
    new_dir := strings.clone(dir) // `dir` may be p.dir itself
    delete(p.dir)
    p.dir = new_dir
    p.cursor, p.top = 0, 0

    infos, err := os.read_all_directory_by_path(p.dir, context.temp_allocator)
    p.err = err
    for fi in infos {
        is_dir := fi.type == .Directory
        if fi.type == .Symlink {
            st, serr := os.stat(fi.fullpath, context.temp_allocator)
            is_dir = serr == nil && st.type == .Directory
        }
        append(&p.entries, Entry{name = strings.clone(fi.name), is_dir = is_dir})
    }
    slice.sort_by(p.entries[:], entry_less)

    for e, i in p.entries {
        if e.name == select {
            p.cursor = i
            break
        }
    }
}

// Lists the same dir again, cursor kept by name. Marks are dropped.
relist :: proc(p: ^Pane) {
    name := ""
    if e, ok := current(p); ok {
        name = strings.clone(e.name, context.temp_allocator)
    }
    open(p, p.dir, name)
}

destroy :: proc(p: ^Pane) {
    clear_entries(p)
    delete(p.entries)
    delete(p.dir)
    p^ = {}
}

@(private)
clear_entries :: proc(p: ^Pane) {
    for e in p.entries {
        delete(e.name)
    }
    clear(&p.entries)
}

current :: proc(p: ^Pane) -> (Entry, bool) {
    if p.cursor < 0 || p.cursor >= len(p.entries) {
        return {}, false
    }
    return p.entries[p.cursor], true
}

// Flips the mark on the cursor item and steps down, so repeats mark a run.
toggle_mark :: proc(p: ^Pane) {
    if p.cursor < 0 || p.cursor >= len(p.entries) {
        return
    }
    p.entries[p.cursor].marked = !p.entries[p.cursor].marked
    move(p, +1)
}

clear_marks :: proc(p: ^Pane) {
    for &e in p.entries {
        e.marked = false
    }
}

// Full paths of the marked items, else of the cursor item.
selection :: proc(p: ^Pane, alloc := context.temp_allocator) -> []string {
    out := make([dynamic]string, alloc)
    for e in p.entries {
        if e.marked {
            append(&out, filepath.join({p.dir, e.name}, alloc) or_else "")
        }
    }
    if len(out) == 0 {
        if e, ok := current(p); ok {
            append(&out, filepath.join({p.dir, e.name}, alloc) or_else "")
        }
    }
    return out[:]
}

move :: proc(p: ^Pane, delta: int) {
    p.cursor = clamp(p.cursor + delta, 0, max(len(p.entries) - 1, 0))
}

// Keeps the cursor inside a window of `rows` visible rows.
scroll :: proc(p: ^Pane, rows: int) {
    if rows <= 0 {
        return
    }
    if p.cursor < p.top {
        p.top = p.cursor
    } else if p.cursor >= p.top + rows {
        p.top = p.cursor - rows + 1
    }
    p.top = clamp(p.top, 0, max(len(p.entries) - rows, 0))
}

// Opens the dir under the cursor. False if it is not a dir.
enter :: proc(p: ^Pane) -> bool {
    e, ok := current(p)
    if !ok || !e.is_dir {
        return false
    }
    path, _ := filepath.join({p.dir, e.name}, context.temp_allocator)
    open(p, path)
    return true
}

// Opens the parent, with the cursor on the dir we came from.
up :: proc(p: ^Pane) {
    parent := strings.clone(filepath.dir(p.dir), context.temp_allocator)
    if parent == "" || parent == p.dir {
        return
    }
    came_from := strings.clone(filepath.base(p.dir), context.temp_allocator)
    open(p, parent, came_from)
}
