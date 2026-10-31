package pane

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../hz"

Entry :: struct {
    name:   string,
    is_dir: bool,
}

Pane :: struct {
    dir:     string,
    entries: [dynamic]Entry,
    cursor:  int,
    top:     int, // first visible row
    err:     os.Error,
    marks:   [dynamic]string, // owned full paths, from any dir, in mark order
    src:     Source,
}

// Where the rows come from when `dir` is not a real dir.
Source :: union {
    Archive,
}

// Inside an archive: `dir` is `file` plus the path within it.
Archive :: struct {
    file:  string, // owned
    items: []hz.Item, // owned
}

is_real :: proc(p: ^Pane) -> bool {
    return p.src == nil
}

// Dirs first, then by name, case-insensitive.
entry_less :: proc(a, b: Entry) -> bool {
    if a.is_dir != b.is_dir {
        return a.is_dir
    }
    return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
}

// Lists the real dir `dir`, leaving any archive, and puts the cursor on `select`.
open :: proc(p: ^Pane, dir: string, select := "") {
    drop_source(p)
    show(p, dir, select)
}

// Lists `dir` from the pane's source.
@(private)
show :: proc(p: ^Pane, dir: string, select := "") {
    clear_entries(p)
    new_dir := strings.clone(dir) // `dir` may be p.dir itself
    delete(p.dir)
    p.dir = new_dir
    p.cursor, p.top = 0, 0
    p.err = nil

    switch s in p.src {
    case nil:
        list_dir(p)
    case Archive:
        list_archive(p, s)
    }
    slice.sort_by(p.entries[:], entry_less)

    for e, i in p.entries {
        if e.name == select {
            p.cursor = i
            break
        }
    }
}

@(private)
list_dir :: proc(p: ^Pane) {
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
}

// The items directly under `dir`. A dir the archive only implies, by a deeper path, is listed too.
@(private)
list_archive :: proc(p: ^Pane, s: Archive) {
    inner := strings.trim_prefix(strings.trim_prefix(p.dir, s.file), "/")
    seen := make(map[string]bool, context.temp_allocator)
    for it in s.items {
        rest := it.path
        if inner != "" {
            if !strings.has_prefix(rest, inner) || !strings.has_prefix(rest[len(inner):], "/") {
                continue
            }
            rest = rest[len(inner) + 1:]
        }
        name, _, deeper := strings.partition(rest, "/")
        if name == "" || name in seen {
            continue
        }
        seen[name] = true
        append(&p.entries, Entry{name = strings.clone(name), is_dir = it.is_dir || deeper != ""})
    }
}

@(private)
drop_source :: proc(p: ^Pane) {
    if s, ok := p.src.(Archive); ok {
        delete(s.file)
        hz.delete_items(s.items)
    }
    p.src = nil
}

// A path under a file, not a dir: inside an archive.
in_archive :: proc(path: string) -> bool {
    for dir := filepath.dir(path); ; dir = filepath.dir(dir) {
        if st, err := os.stat(dir, context.temp_allocator); err == nil {
            return st.type != .Directory
        }
        if dir == filepath.dir(dir) {
            return false
        }
    }
}

// Lists the same dir again, cursor kept by name. Marks on paths that are gone are dropped.
relist :: proc(p: ^Pane) {
    #reverse for m, i in p.marks {
        if _, err := os.lstat(m, context.temp_allocator); err != nil && !in_archive(m) {
            delete(m)
            ordered_remove(&p.marks, i)
        }
    }
    name := ""
    if e, ok := current(p); ok {
        name = strings.clone(e.name, context.temp_allocator)
    }
    show(p, p.dir, name)
}

destroy :: proc(p: ^Pane) {
    clear_entries(p)
    delete(p.entries)
    unmark(p)
    delete(p.marks)
    drop_source(p)
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

// Temp-allocated.
path_of :: proc(p: ^Pane, name: string) -> string {
    return filepath.join({p.dir, name}, context.temp_allocator) or_else ""
}

mark_index :: proc(p: ^Pane, path: string) -> int {
    for m, i in p.marks {
        if m == path {
            return i
        }
    }
    return -1
}

is_marked :: proc(p: ^Pane, e: Entry) -> bool {
    return mark_index(p, path_of(p, e.name)) >= 0
}

// Marks or unmarks the cursor item.
mark_cursor :: proc(p: ^Pane, on: bool) {
    e, ok := current(p)
    if !ok {
        return
    }
    path := path_of(p, e.name)
    i := mark_index(p, path)
    if on && i < 0 {
        append(&p.marks, strings.clone(path))
    } else if !on && i >= 0 {
        delete(p.marks[i])
        ordered_remove(&p.marks, i)
    }
}

// Flips the mark on the cursor item. Returns its new state.
toggle_mark :: proc(p: ^Pane) -> (on: bool) {
    e := current(p) or_return
    on = !is_marked(p, e)
    mark_cursor(p, on)
    return
}

// Drops every mark, or with `dir` only those directly in it.
unmark :: proc(p: ^Pane, dir := "") {
    #reverse for m, i in p.marks {
        if dir == "" || filepath.dir(m) == dir {
            delete(m)
            ordered_remove(&p.marks, i)
        }
    }
}

// The marks, in any dir, else the cursor item. Full paths.
selection :: proc(p: ^Pane, alloc := context.temp_allocator) -> []string {
    if len(p.marks) > 0 {
        return slice.clone(p.marks[:], alloc)
    }
    out := make([dynamic]string, alloc)
    if e, ok := current(p); ok {
        append(&out, filepath.join({p.dir, e.name}, alloc) or_else "")
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

// Opens the dir or archive under the cursor. False if it is neither; `err` when that is worth saying.
enter :: proc(p: ^Pane) -> (ok: bool, err: string) {
    e, has := current(p)
    if !has {
        return
    }
    path := path_of(p, e.name)
    if e.is_dir {
        show(p, path)
        return true, ""
    }
    if !is_real(p) {
        return // no archives inside archives
    }
    items, herr := hz.list(path)
    switch herr {
    case .None:
    case .Not_Archive:
        return
    case .Password:
        // (hole archive-password :tags files :sev gap) no prompt; a 7z with locked headers only says so.
        return false, "needs a password"
    }
    p.src = Archive{strings.clone(path), items}
    show(p, path)
    return true, ""
}

// Opens the parent, with the cursor on the dir we came from.
up :: proc(p: ^Pane) {
    parent := strings.clone(filepath.dir(p.dir), context.temp_allocator)
    if parent == "" || parent == p.dir {
        return
    }
    came_from := strings.clone(filepath.base(p.dir), context.temp_allocator)
    if s, ok := p.src.(Archive); ok && p.dir == s.file {
        drop_source(p) // up from its root leaves the archive
    }
    show(p, parent, came_from)
}
