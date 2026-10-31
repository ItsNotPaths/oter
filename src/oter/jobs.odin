package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "../fsop"
import "../pane"

// A send in flight. `landed` is how many items the panes have re-listed for.
Send :: struct {
    job:     ^fsop.Job,
    src_dir: string, // owned; a move re-lists it as items leave
    landed:  int,
}

send_start :: proc(a: ^App, srcs: []string, src_dir, dst_dir: string, move: bool, archive := "") {
    lines := move ? a.config.move[:] : a.config.copy[:]
    job := fsop.start(srcs, dst_dir, move, lines, archive, a.passwords[archive])
    append(&a.sends, Send{job, strings.clone(src_dir), 0})
}

// Each frame: re-list the panes an item landed in; finish what the worker finished.
jobs_poll :: proc(a: ^App) {
    filter_poll(a)
    archives_poll(a)
    #reverse for &s, i in a.sends {
        j := s.job
        finished := fsop.is_finished(j) // read first: once set, every field is final
        landed := 0
        for &it in j.items {
            landed += int(sync.atomic_load(&it.done))
        }
        if landed != s.landed || finished {
            s.landed = landed
            relist_dir(a, j.dst_dir)
            if j.move {
                relist_dir(a, s.src_dir)
            }
        }
        if !finished {
            continue
        }
        send_end(a, &s)
        fsop.destroy(j)
        delete(s.src_dir)
        ordered_remove(&a.sends, i)
    }
}

// The result in the status line, or the password question a locked archive raises.
@(private = "file")
send_end :: proc(a: ^App, s: ^Send) {
    j := s.job
    switch j.locked {
    case .Password:
        srcs := make([]string, len(j.items))
        for it, i in j.items {
            srcs[i] = strings.clone(it.src)
        }
        ask_password(a, j.archive, Retry_Copy{srcs, strings.clone(s.src_dir), strings.clone(j.dst_dir)})
    case .Wrong_Password:
        password_forget(a, j.archive)
        fail(a, fmt.tprintf("wrong password for %s", filepath.base(j.archive)))
    case .None, .Failed:
        status_set(a, send_result(j), j.err != "")
    }
}

Ghost :: struct {
    name: string,
    pct:  int,
}

// The items of running sends into `dir` that have not landed yet.
ghosts :: proc(a: ^App, dir: string, alloc := context.temp_allocator) -> []Ghost {
    out := make([dynamic]Ghost, alloc)
    for &s in a.sends {
        if s.job.dst_dir != dir || fsop.is_finished(s.job) {
            continue
        }
        for &it in s.job.items {
            if !sync.atomic_load(&it.done) {
                append(&out, Ghost{it.name, sync.atomic_load(&it.pct)})
            }
        }
    }
    return out[:]
}

@(private = "file")
relist_dir :: proc(a: ^App, dir: string) {
    for &p in a.panes {
        if p.dir == dir {
            pane.relist(&p)
        }
    }
}

// `copied 3, skipped 1 → ~/Pictures`, or the error that stopped it.
@(private = "file")
send_result :: proc(j: ^fsop.Job) -> string {
    verb := j.move ? "moved" : "copied"
    if j.err != "" {
        return fmt.tprintf("%s %d, then: %s", verb, j.done, j.err)
    }
    skipped := j.skipped > 0 ? fmt.tprintf(", skipped %d", j.skipped) : ""
    return fmt.tprintf("%s %d%s → %s", verb, j.done, skipped, home_short(j.dst_dir))
}

@(private = "file")
home_short :: proc(path: string) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && (path == home || strings.has_prefix(path, fmt.tprintf("%s/", home))) {
        rel, _ := filepath.rel(home, path, context.temp_allocator)
        return rel == "." ? "~" : fmt.tprintf("~/%s", rel)
    }
    return path
}
