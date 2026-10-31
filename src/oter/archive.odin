package oter

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../fsop"
import "../hz"
import "../pane"

// An archive listed on a thread for pane `pane`, which must still show `from` when it lands.
Listing :: struct {
    file:     string, // owned, as are the rest
    dir:      string, // where in it the pane lands
    from:     string,
    pane:     int,
    password: string,
    items:    []hz.Item,
    err:      hz.Error,
    finished: bool, // atomic; the fields above are final once set
}

// A listing kept for going back in. Stale once the file's size or mtime moves.
Cached :: struct {
    file:  string, // owned, as is `items`
    size:  i64,
    mtime: time.Time,
    items: []hz.Item,
}

@(private = "file")
CACHE_MAX :: 8

// Pane `i` goes to `path` in an archive: at once if it is cached, else once listed.
// False if no file in `path` could be one.
archive_open :: proc(a: ^App, i: int, path: string) -> bool {
    file := pane.archive_of(path) or_return
    if items, hit := cache_get(a, file); hit {
        pane.open_archive(&a.panes[i], file, items, path)
        return true
    }
    l := new(Listing)
    l^ = {file = strings.clone(file), dir = strings.clone(path), from = strings.clone(a.panes[i].dir), pane = i}
    l.password = strings.clone(a.passwords[file])
    append(&a.listings, l)
    status_set(a, fmt.tprintf("opening %s…", filepath.base(file)))
    ctx := runtime.default_context() // own temp allocator; the main loop frees its own each frame
    ctx.allocator = context.allocator
    thread.create_and_start_with_poly_data(l, listing_work, ctx, self_cleanup = true)
    return true
}

@(private = "file")
listing_work :: proc(l: ^Listing) {
    defer fsop.wake_hook() // after `finished`: defers run last first
    defer sync.atomic_store(&l.finished, true)
    l.items, l.err = hz.list(l.file, l.password)
    free_all(context.temp_allocator)
}

// Each frame: land the listings that finished.
archives_poll :: proc(a: ^App) {
    #reverse for l, k in a.listings {
        if !sync.atomic_load(&l.finished) {
            continue
        }
        ordered_remove(&a.listings, k)
        listing_land(a, l)
        delete(l.file)
        delete(l.dir)
        delete(l.from)
        delete(l.password)
        free(l)
    }
}

@(private = "file")
listing_land :: proc(a: ^App, l: ^Listing) {
    name := filepath.base(l.file)
    switch l.err {
    case .Failed:
        if l.dir == l.file {
            status_set(a, "") // enter on a plain file: nothing to say
        } else {
            fail(a, fmt.tprintf("%s is not an archive", name))
        }
    case .Password:
        ask_password(a, l.file, Retry_Open{l.pane, strings.clone(l.dir), strings.clone(l.from)})
    case .Wrong_Password:
        password_forget(a, l.file)
        fail(a, fmt.tprintf("wrong password for %s", name))
    case .None:
        if l.pane < len(a.panes) && a.panes[l.pane].dir == l.from {
            pane.open_archive(&a.panes[l.pane], l.file, hz.clone_items(l.items), l.dir)
        }
        cache_put(a, l.file, l.items)
        status_set(a, "")
    }
}

@(private = "file")
cache_get :: proc(a: ^App, file: string) -> ([]hz.Item, bool) {
    st, err := os.stat(file, context.temp_allocator)
    if err != nil {
        return nil, false
    }
    for c in a.archives {
        if c.file == file && c.size == st.size && c.mtime == st.modification_time {
            return hz.clone_items(c.items), true
        }
    }
    return nil, false
}

// Takes `items`. The oldest entry goes once there are CACHE_MAX.
@(private = "file")
cache_put :: proc(a: ^App, file: string, items: []hz.Item) {
    st, _ := os.stat(file, context.temp_allocator)
    for c, k in a.archives {
        if c.file == file {
            cached_free(c)
            ordered_remove(&a.archives, k)
            break
        }
    }
    if len(a.archives) == CACHE_MAX {
        cached_free(a.archives[0])
        ordered_remove(&a.archives, 0)
    }
    append(&a.archives, Cached{strings.clone(file), st.size, st.modification_time, items})
}

@(private = "file")
cached_free :: proc(c: Cached) {
    delete(c.file)
    hz.delete_items(c.items)
}

// What a password unlocks once given: the open or the copy that needed it. Owned.
Retry :: union {
    Retry_Open,
    Retry_Copy,
}

Retry_Open :: struct {
    pane:       int,
    path, from: string, // pane `pane`, still showing `from`, goes to `path`
}

Retry_Copy :: struct {
    srcs:             []string,
    src_dir, dst_dir: string,
}

// A question in the tray. `id` is the term0 report that answers it.
Ask :: struct {
    id:    u64,
    file:  string, // owned
    retry: Retry,
}

// Takes `retry`. One question at a time, and only to a shell at its prompt.
ask_password :: proc(a: ^App, file: string, retry: Retry) {
    name := filepath.base(file)
    if a.ask != nil || a.chain.waiting || !term0_ask(a, fmt.tprintf("password for %s: ", name)) {
        retry_free(retry)
        fail(a, fmt.tprintf("%s needs a password, and the shell is busy", name))
        return
    }
    status_set(a, "")
    a.ask = Ask{a.step_id, strings.clone(file), retry}
}

// The tray closes. An answer is kept for the file and the retry runs; ^C or Esc ran nothing.
ask_answered :: proc(a: ^App, ask: Ask, answered: bool, password: string) {
    defer ask_free(ask)
    a.drawer = .Closed
    mode_set(a, .Panes)
    if !answered || password == "" {
        return
    }
    password_forget(a, ask.file)
    a.passwords[strings.clone(ask.file)] = strings.clone(password)
    switch r in ask.retry {
    case Retry_Open:
        if r.pane < len(a.panes) && a.panes[r.pane].dir == r.from {
            archive_open(a, r.pane, r.path)
        }
    case Retry_Copy:
        send_start(a, r.srcs, r.src_dir, r.dst_dir, false, ask.file)
    }
}

// The shell died under the question.
ask_drop :: proc(a: ^App) {
    if ask, asking := a.ask.?; asking {
        ask_free(ask)
        a.ask = nil
    }
}

password_forget :: proc(a: ^App, file: string) {
    key, value := delete_key(&a.passwords, file) // zero strings if it had none
    delete(key)
    delete(value)
}

@(private = "file")
ask_free :: proc(ask: Ask) {
    delete(ask.file)
    retry_free(ask.retry)
}

@(private = "file")
retry_free :: proc(r: Retry) {
    switch r in r {
    case Retry_Open:
        delete(r.path)
        delete(r.from)
    case Retry_Copy:
        for s in r.srcs {
            delete(s)
        }
        delete(r.srcs)
        delete(r.src_dir)
        delete(r.dst_dir)
    }
}

// A listing still running at quit is left to the OS, as a send is.
archives_destroy :: proc(a: ^App) {
    for c in a.archives {
        cached_free(c)
    }
    delete(a.archives)
    delete(a.listings)
    for key, value in a.passwords {
        delete(key)
        delete(value)
    }
    delete(a.passwords)
    ask_drop(a)
}
