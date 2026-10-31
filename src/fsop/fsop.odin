package fsop

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "oket:cl"
import "../hz"

// Wakes the host's loop from the worker when an item or the job ends. The host sets it once.
wake_hook := proc() {}

// One top-level source. A dir is one item for its whole tree.
Item :: struct {
    src:  string,
    name: string, // as it lands in dst_dir
    done: bool,   // atomic
    pct:  int,    // atomic; from a line that prints `NN%`, as rsync's progress2 does
}

Job :: struct {
    dst_dir:  string,
    archive:  string, // set: every item is inside this archive, and is extracted
    password: string, // the archive's; "" is none
    move:     bool,
    lines:    []string, // the host's; sh lines, best first, the first whose program is installed runs
    items:    []Item,
    done:     int,
    skipped:  int,    // name clash in dst_dir; never overwrites
    err:      string, // stderr of the item that stopped the job
    locked:   hz.Error, // .Password or .Wrong_Password when that is what stopped it
    finished: bool,   // atomic; the fields above are final once set
}

// `lines` must outlive the job. In them `$o_src` is the item, `$o_dir` the target dir,
// `$o_dst` the item's path in it.
new_job :: proc(srcs: []string, dst_dir: string, move: bool, lines: []string, archive := "", password := "") -> ^Job {
    j := new(Job)
    j.dst_dir = strings.clone(dst_dir)
    j.archive = strings.clone(archive)
    j.password = strings.clone(password)
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
    delete(j.archive)
    delete(j.password)
    delete(j.err)
    free(j)
}

// Runs `send` on a worker thread. Free with `destroy` once `is_finished`.
start :: proc(srcs: []string, dst_dir: string, move: bool, lines: []string, archive := "", password := "") -> ^Job {
    j := new_job(srcs, dst_dir, move, lines, archive, password)
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
    if j.archive != "" {
        extract(j)
        return
    }
    line, found := pick(j.lines)
    if !found {
        j.err = strings.clone(j.move ? "no move tool installed" : "no copy tool installed")
        return
    }
    for &it in j.items {
        if inside(j.dst_dir, it.src) { // rsync would do it; cp refuses
            j.err = fmt.aprintf("%s cannot go inside itself", it.name)
            return
        }
        dst, _ := filepath.join({j.dst_dir, it.name}, context.temp_allocator)
        if _, err := os.lstat(dst, context.temp_allocator); err == nil {
            j.skipped += 1
        } else {
            msg, ok := run_line(line, {it.src, j.dst_dir, dst, it.name}, &it.pct)
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

// One pass over the archive: each unit it needs is decoded once.
@(private = "file")
extract :: proc(j: ^Job) {
    picks := make([]string, len(j.items), context.temp_allocator)
    for it, i in j.items {
        picks[i] = strings.trim_prefix(it.src[len(j.archive):], "/")
    }
    err, msg := hz.extract(j.archive, j.password, picks, j.dst_dir, report, j)
    if err != .None {
        j.err = strings.clone(msg)
    }
    if err == .Password || err == .Wrong_Password {
        j.locked = err
    }
}

@(private = "file")
report :: proc "c" (data: rawptr, i: uint, pct: u8, state: hz.State) {
    context = runtime.default_context()
    j := (^Job)(data)
    it := &j.items[i]
    switch state {
    case .Progress:
        sync.atomic_store(&it.pct, int(pct))
    case .Done:
        j.done += 1
        sync.atomic_store(&it.done, true)
    case .Skipped:
        j.skipped += 1
        sync.atomic_store(&it.done, true)
    }
    wake_hook()
}

@(private = "file")
inside :: proc(path, dir: string) -> bool {
    return path == dir || strings.has_prefix(path, dir) && path[len(dir)] == '/'
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

// Runs `line` in sh with vars filled in. Returns its stderr. The last `NN%` on stdout goes in `pct`.
run_line :: proc(line: string, vars: cl.Vars, pct: ^int) -> (msg: string, ok: bool) {
    cmd, missing, filled := cl.fill(vars, line)
    if !filled {
        return fmt.tprintf("no $o_%s", missing), false
    }
    _, msg, ok = exec(cmd, {pct = pct})
    return
}

// How `exec` runs a command. Every field is optional.
Exec :: struct {
    dir:   string,
    stdin: ^os.File,
    pct:   ^int,  // atomic; stdout is read for `NN%` instead of kept
    stop:  ^bool, // atomic; once set, the command is killed
}

// `sh -c cmd`, its output read as it comes, so a long one can report progress or be stopped.
// Temp-allocated. A stopped command is not ok; its stderr is "stopped".
exec :: proc(cmd: string, e: Exec) -> (stdout, stderr: string, ok: bool) {
    out_r, out_w, perr := os.pipe()
    if perr != nil {
        return "", os.error_string(perr), false
    }
    defer os.close(out_r)
    err_r, err_w, eerr := os.pipe()
    if eerr != nil {
        os.close(out_w)
        return "", os.error_string(eerr), false
    }
    defer os.close(err_r)
    proc_, serr := os.process_start({command = {"sh", "-c", cmd}, working_dir = e.dir, stdin = e.stdin, stdout = out_w, stderr = err_w})
    os.close(out_w)
    os.close(err_w)
    if serr != nil {
        return "", os.error_string(serr), false
    }

    out := make([dynamic]u8, context.temp_allocator)
    errs := make([dynamic]u8, context.temp_allocator)
    seg := make([dynamic]u8, context.temp_allocator) // stdout since the last \r or \n
    buf: [4096]u8
    out_open, err_open := true, true
    for out_open || err_open {
        if e.stop != nil && sync.atomic_load(e.stop) {
            _ = os.process_kill(proc_) // a child it left gets SIGPIPE on its next write
            _, _ = os.process_wait(proc_)
            return "", "stopped", false
        }
        got := false
        if out_open {
            n, rerr := drain(out_r, buf[:])
            out_open = rerr == nil
            got |= n > 0
            if e.pct == nil {
                append(&out, ..buf[:n])
            } else {
                progress_feed(&seg, buf[:n], e.pct)
            }
        }
        if err_open {
            n, rerr := drain(err_r, buf[:])
            err_open = rerr == nil
            got |= n > 0
            append(&errs, ..buf[:n])
        }
        if !got {
            time.sleep(10 * time.Millisecond)
        }
    }
    state, _ := os.process_wait(proc_)
    return string(out[:]), strings.trim_space(string(errs[:])), state.exit_code == 0
}

@(private = "file")
progress_feed :: proc(seg: ^[dynamic]u8, bytes: []u8, pct: ^int) {
    for c in bytes {
        if c != '\r' && c != '\n' {
            append(seg, c)
            continue
        }
        if v, has := progress_pct(string(seg[:])); has {
            sync.atomic_store(pct, v)
            wake_hook()
        }
        clear(seg)
    }
}

// What is in the pipe now, without blocking. An error is the writer gone and the pipe empty.
@(private = "file")
drain :: proc(r: ^os.File, buf: []u8) -> (int, os.Error) {
    if has, err := os.pipe_has_data(r); err == nil && !has {
        return 0, nil
    }
    return os.read(r, buf) // after a hangup this still gets what is left, then EOF
}

// The last `NN%` field of a line: rsync's `  1,234  45%  1.2MB/s  0:00:03`.
progress_pct :: proc(line: string) -> (int, bool) {
    #reverse for f in strings.fields(line, context.temp_allocator) {
        if len(f) > 1 && f[len(f) - 1] == '%' {
            if v, ok := strconv.parse_int(f[:len(f) - 1], 10); ok && v >= 0 && v <= 100 {
                return v, true
            }
        }
    }
    return 0, false
}
