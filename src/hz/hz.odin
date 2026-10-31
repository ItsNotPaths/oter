// hatchzip's archive listing and extraction, through the `hz` crate (`hz/`, built by build.sh).
package hz

import "core:strings"

foreign import lib {"../../hz/target/release/libhz.a", "system:gcc_s", "system:util", "system:rt"}

Error :: enum i32 {
    None           = 0,
    Failed         = 1, // for a listing: not an archive
    Password       = 2,
    Wrong_Password = 3,
}

State :: enum i32 {
    Progress = 0,
    Done     = 1,
    Skipped  = 2,
}

// Called on the extracting thread: pick `i` is at `pct` percent by bytes, or done, or skipped.
Report :: proc "c" (data: rawptr, i: uint, pct: u8, state: State)

Item :: struct {
    path:   string,
    is_dir: bool,
}

@(private)
C_Item :: struct {
    path:   cstring,
    is_dir: bool,
}

@(private)
C_List :: struct {
    items: [^]C_Item,
    count: uint,
}

@(private, default_calling_convention = "c")
foreign lib {
    hz_list :: proc(path, password: cstring, out: ^C_List) -> Error ---
    hz_free :: proc(list: ^C_List) ---
    hz_extract :: proc(archive, password: cstring, picks: [^]cstring, n: uint, dst_dir: cstring, report: Report, data: rawptr, err: ^cstring) -> Error ---
    hz_free_str :: proc(s: cstring) ---
}

// Every item of the archive at `path`, paths as stored. Read-only. "" is no password.
list :: proc(path: string, password := "", alloc := context.allocator) -> (items: []Item, err: Error) {
    tmp := context.temp_allocator
    l: C_List
    if err = hz_list(strings.clone_to_cstring(path, tmp), strings.clone_to_cstring(password, tmp), &l); err != .None {
        return
    }
    defer hz_free(&l)
    items = make([]Item, l.count, alloc)
    for &it, i in items {
        c := l.items[i]
        it = {strings.clone_from_cstring(c.path, alloc), c.is_dir}
    }
    return
}

clone_items :: proc(items: []Item, alloc := context.allocator) -> []Item {
    out := make([]Item, len(items), alloc)
    for it, i in items {
        out[i] = {strings.clone(it.path, alloc), it.is_dir}
    }
    return out
}

delete_items :: proc(items: []Item, alloc := context.allocator) {
    for it in items {
        delete(it.path, alloc)
    }
    delete(items, alloc)
}

// Each of `picks` (paths inside the archive, a file or a dir's tree) to `dst_dir/<base name>`.
// One already there is skipped. `msg` is temp-allocated.
extract :: proc(archive, password: string, picks: []string, dst_dir: string, report: Report, data: rawptr) -> (err: Error, msg: string) {
    tmp := context.temp_allocator
    cs := make([]cstring, len(picks), tmp)
    for p, i in picks {
        cs[i] = strings.clone_to_cstring(p, tmp)
    }
    c_msg: cstring
    archive_c, password_c := strings.clone_to_cstring(archive, tmp), strings.clone_to_cstring(password, tmp)
    err = hz_extract(archive_c, password_c, raw_data(cs), len(cs), strings.clone_to_cstring(dst_dir, tmp), report, data, &c_msg)
    if c_msg != nil {
        msg = strings.clone_from_cstring(c_msg, tmp)
        hz_free_str(c_msg)
    }
    return
}
