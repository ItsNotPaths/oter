package fsop

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "oket:cl"

// Wakes the host's loop from the worker when an item or the job ends. The host sets it once.
wake_hook := proc() {}

// One top-level source. A dir is one item for its whole tree.
Item :: struct {
    src:  string,
    name: string, // as it lands in dst_dir
    done: bool,   // atomic
}

Job :: struct {
    dst_dir:  string,
    move:     bool,
    lines:    []string, // the host's; sh lines, best first, the first whose program is installed runs
    items:    []Item,
    done:     int,
    skipped:  int,    // name clash in dst_dir; never overwrites
    err:      string, // stderr of the item that stopped the job
    finished: bool,   // atomic; the fields above are final once set
}

// `lines` must outlive the job. In them `$o_src` is the item, `$o_dir` the target dir,
// `$o_dst` the item's path in it.
new_job :: proc(srcs: []string, dst_dir: string, move: bool, lines: []string) -> ^Job {
    j := new(Job)
    j.dst_dir = strings.clone(dst_dir)
    j.move = move
    j.lines = lines
    j.items = make([]Item, len(srcs))
    for src, i in srcs {
        j.items[i].src = strings.clone(src)
        j.items[i].name = filepath.base(j.items[i].src)
    }
    return j
}

destroy :: proc(j: ^Job) {
    for it in j.items {
        delete(it.src)
    }
    delete(j.items)
    delete(j.dst_dir)
    delete(j.err)
    free(j)
}

// Runs `send` on a worker thread. Free with `destroy` once `is_finished`.
start :: proc(srcs: []string, dst_dir: string, move: bool, lines: []string) -> ^Job {
    j := new_job(srcs, dst_dir, move, lines)
    ctx := runtime.default_context() // own temp allocator; the main loop frees its own each frame
    ctx.allocator = context.allocator
    thread.create_and_start_with_poly_data(j, send, ctx, self_cleanup = true)
    return j
}

is_finished :: proc(j: ^Job) -> bool {
    return sync.atomic_load(&j.finished)
}

// Copies or moves each item in order. Stops at the first failure.
send :: proc(j: ^Job) {
    defer wake_hook() // after `finished`: defers run last first
    defer sync.atomic_store(&j.finished, true)
    line, found := pick(j.lines)
    if !found {
        j.err = strings.clone(j.move ? "no move tool installed" : "no copy tool installed")
        return
    }
    for &it in j.items {
        dst, _ := filepath.join({j.dst_dir, it.name}, context.temp_allocator)
        if _, err := os.lstat(dst, context.temp_allocator); err == nil {
            j.skipped += 1
        } else {
            msg, ok := run_line(line, {it.src, j.dst_dir, dst})
            if !ok {
                j.err = strings.clone(msg)
                return
            }
            j.done += 1
        }
        sync.atomic_store(&it.done, true)
        wake_hook()
    }
}

// The first line whose program (its first word) is installed.
pick :: proc(lines: []string) -> (string, bool) {
    for line in lines {
        fields := strings.fields(line, context.temp_allocator)
        if len(fields) > 0 && installed(fields[0]) {
            return line, true
        }
    }
    return "", false
}

@(private = "file")
installed :: proc(tool: string) -> bool {
    if strings.contains_rune(tool, '/') {
        return os.exists(tool)
    }
    for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
        path, _ := filepath.join({dir, tool}, context.temp_allocator)
        if os.is_file(path) {
            return true
        }
    }
    return false
}

// Runs `line` in sh with vars filled in. Returns its stderr.
run_line :: proc(line: string, vars: cl.Vars) -> (msg: string, ok: bool) {
    cmd, missing, filled := cl.fill(vars, line)
    if !filled {
        return fmt.tprintf("no $o_%s", missing), false
    }
    // (hole rsync-progress :tags files :sev gap) rsync's progress2 output is dropped; a row fills only when its item ends.
    state, _, stderr, err := os.process_exec({command = {"sh", "-c", cmd}}, context.temp_allocator)
    if err != nil {
        return os.error_string(err), false
    }
    return strings.trim_space(string(stderr)), state.success
}
