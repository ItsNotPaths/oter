// hatchzip's archive listing, through the `hz` crate (`hz/`, built by build.sh).
package hz

import "core:strings"

foreign import lib {"../../hz/target/release/libhz.a", "system:gcc_s", "system:util", "system:rt"}

Error :: enum i32 {
    None        = 0,
    Not_Archive = 1,
    Password    = 2,
}

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
    hz_list :: proc(path: cstring, out: ^C_List) -> Error ---
    hz_free :: proc(list: ^C_List) ---
}

// Every item of the archive at `path`, paths as stored. Read-only.
list :: proc(path: string, alloc := context.allocator) -> (items: []Item, err: Error) {
    l: C_List
    if err = hz_list(strings.clone_to_cstring(path, context.temp_allocator), &l); err != .None {
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

delete_items :: proc(items: []Item, alloc := context.allocator) {
    for it in items {
        delete(it.path, alloc)
    }
    delete(items, alloc)
}
