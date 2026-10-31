package oter

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "oket:cl"
import "../fsop"
import "../pane"

// A piped shell step on a worker thread. The chain waits on it as it waits on a term0 step.
Filter :: struct {
    step:     cl.Step,
    cmd:      string, // owned, as are the rest
    feed:     string,
    dir:      string,
    out:      string,
    msg:      string,
    ok:       bool,
    finished: bool, // atomic; the fields above are final once set
    stop:     bool, // atomic; ^C in the drawer sets it
}

filter_start :: proc(a: ^App, step: cl.Step, cmd: string) {
    feed, _ := cl.piped(&a.chain, step)
    f := new(Filter)
    f^ = {step = step, cmd = strings.clone(cmd), feed = strings.clone(feed), dir = strings.clone(a.panes[a.active].dir)}
    a.filter = f
    a.chain.waiting = true
    status_set(a, fmt.tprintf("running: %s", cmd))
    ctx := runtime.default_context() // own temp allocator; the main loop frees its own each frame
    ctx.allocator = context.allocator
    thread.create_and_start_with_poly_data(f, filter_work, ctx, self_cleanup = true)
}

@(private = "file")
filter_work :: proc(f: ^Filter) {
    defer fsop.wake_hook() // after `finished`: defers run last first
    defer sync.atomic_store(&f.finished, true)
    out, msg, ok := run_filter(f)
    f.out, f.msg, f.ok = strings.clone(out), strings.clone(msg), ok
    free_all(context.temp_allocator)
}

// Each frame: once the filter ends, hand its output on and resume the chain.
filter_poll :: proc(a: ^App) {
    f := a.filter
    if f == nil || !sync.atomic_load(&f.finished) {
        return
    }
    a.filter = nil
    a.chain.waiting = false
    defer filter_destroy(f)
    switch {
    case sync.atomic_load(&f.stop):
        status_set(a, fmt.tprintf("stopped: %s", f.cmd))
        cl.reset(&a.chain) // the whole line, not just this step
        return
    case !f.ok:
        fail(a, f.msg)
    case f.step.feeds:
        cl.feed_set(&a.chain, f.out)
        status_set(a, "")
    case:
        status_set(a, "")
        pane.relist(&a.panes[a.active]) // the pipe's end may have changed what is here
    }
    cl.done(&a.chain, f.ok)
    chain_pump(a)
}

@(private = "file")
filter_destroy :: proc(f: ^Filter) {
    delete(f.cmd)
    delete(f.feed)
    delete(f.dir)
    delete(f.out)
    delete(f.msg)
    free(f)
}

// ^C in the drawer: the running filter if there is one. False leaves the key to the shell.
filter_stop :: proc(a: ^App) -> bool {
    if a.filter == nil {
        return false
    }
    sync.atomic_store(&a.filter.stop, true)
    return true
}

// The feed goes through a temp file: a pipe would block on a feed bigger than its buffer.
@(private = "file")
run_filter :: proc(f: ^Filter) -> (out, msg: string, ok: bool) {
    feed, err := os.create_temp_file("", "oter-feed-*")
    if err != nil {
        return "", os.error_string(err), false
    }
    path := strings.clone(os.name(feed), context.temp_allocator) // close frees the name
    defer os.remove(path)
    defer os.close(feed)
    os.write_string(feed, f.feed)
    os.seek(feed, 0, .Start)
    out, msg, ok = fsop.exec(f.cmd, {dir = f.dir, stdin = feed, stop = &f.stop})
    if !ok {
        msg = fmt.tprintf("%s: %s", f.cmd, msg != "" ? msg : "failed")
    }
    return
}
