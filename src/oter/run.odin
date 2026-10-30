package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oket:cl"
import "../pane"

// Builtins in-process, piped shell steps as filters, a lone shell step in term0.
run_line :: proc(a: ^App, line: string) {
    ch := &a.chain
    if ch.waiting {
        status_set(a, "a shell step is still running", true)
        return
    }
    cl.parse(ch, line, a, proc(a: ^App, name: string) -> string {return ""}, proc(a: ^App, name: string) -> bool {
        return name == "line" // `:line <text>` takes the rest raw, operators and all
    })
    p := &a.panes[a.active]
    vars: cl.Vars
    if e, ok := pane.current(p); ok {
        vars[var("src")] = filepath.join({p.dir, e.name}, context.temp_allocator) or_else ""
    }
    vars[var("dir")] = p.dir
    cl.vars_set(ch, vars)
    chain_pump(a)
}

// Steps until the chain ends, or waits on a term0 step (term0_pump resumes it).
chain_pump :: proc(a: ^App) {
    ch := &a.chain
    for {
        step, ok := cl.next(ch)
        if !ok {
            return
        }
        if !step.shell {
            cl.done(ch, run_builtin(a, step))
            continue
        }
        cmd, missing, filled := cl.fill(ch.vars, step.text)
        if !filled {
            cl.done(ch, fail(a, fmt.tprintf("no $o_%s here", missing)))
            continue
        }
        if _, piped := cl.piped(ch, step); piped || step.feeds {
            cl.done(ch, run_filter_step(a, step, cmd))
            continue
        }
        if !term0_run(a, cmd) {
            cl.done(ch, false)
            continue
        }
        ch.waiting = true
        return
    }
}

@(private = "file")
var :: proc(name: string) -> int {
    i, ok := cl.var_index(name)
    assert(ok)
    return i
}

@(private = "file")
fail :: proc(a: ^App, msg: string) -> bool {
    status_set(a, msg, true)
    return false
}

@(private = "file")
run_builtin :: proc(a: ^App, step: cl.Step) -> bool {
    name := cl.first_field(step.text)
    args := strings.trim_space(step.text[len(name):])
    p := &a.panes[a.active]
    switch name {
    case "sel":
        return builtin_sel(a)
    case "copy", "move":
        return builtin_send(a, step, args, name == "move")
    case "quit":
        a.running = false
    case "line":
        if a.mode == .Panes {
            cl_open(a, args)
        }
    case "sidebar":
        #partial switch a.mode {
        case .Panes:
            mode_set(a, .Sidebar)
        case .Sidebar:
            mode_set(a, .Panes)
        }
    case "drawer":
        switch args {
        case "open":
            tray_up(a)
        case "close":
            tray_down(a)
        case:
            return fail(a, ":drawer takes open or close")
        }
    case "up":
        pane.move(p, -1)
    case "down":
        pane.move(p, +1)
    case "pgup":
        pane.move(p, -max(list_rows(a) - 1, 1))
    case "pgdn":
        pane.move(p, +max(list_rows(a) - 1, 1))
    case "top":
        pane.move(p, -len(p.entries))
    case "bottom":
        pane.move(p, +len(p.entries))
    case "enter":
        pane.enter(p)
    case "parent":
        pane.up(p)
    case "mark":
        pane.toggle_mark(p)
    case "focus", "swap":
        i, ok := pane_target(a, args)
        if !ok {
            return fail(a, fmt.tprintf(":%s: %s is not a pane", name, args))
        }
        if name == "swap" {
            a.panes[a.active], a.panes[i] = a.panes[i], a.panes[a.active]
        }
        a.active = i
    case:
        return fail(a, fmt.tprintf(":%s: no such builtin", name))
    }
    return true
}

// `@N` / `@±N`: one pane, not a slot or a set.
@(private = "file")
pane_ref :: proc(args: string) -> (cl.Target, bool) {
    t, _, parsed := cl.target_parse(args)
    return t, parsed && t.slot == 0 && !t.slots && t.how != .Showing && t.how != .All
}

// A pane ref as a pane index. No pane there is not ok.
@(private = "file")
pane_target :: proc(a: ^App, args: string) -> (i: int, ok: bool) {
    t := pane_ref(args) or_return
    return cl.target_index(t, a.active, len(a.panes))
}

// The marked items, else the cursor item, one full path per line.
@(private = "file")
builtin_sel :: proc(a: ^App) -> bool {
    paths := pane.selection(&a.panes[a.active])
    for p in paths {
        if strings.contains_rune(p, '\n') {
            return fail(a, "a filename with a newline in it? why the fuck do you have that")
        }
    }
    cl.feed_set(&a.chain, strings.join(paths, "\n", context.temp_allocator))
    return true
}

// `:copy <target>` / `:move <target>`: the piped paths, else the selection.
@(private = "file")
builtin_send :: proc(a: ^App, step: cl.Step, args: string, move: bool) -> bool {
    dst, ok := target_dir(a, args)
    if !ok {
        return fail(a, fmt.tprintf(":%s: %s is not a pane or a dir", move ? "move" : "copy", args))
    }
    if dst == "" {
        return true // no pane there: nothing to do
    }
    from := &a.panes[a.active]
    srcs: []string
    if feed, piped := cl.piped(&a.chain, step); piped {
        srcs = feed_paths(feed, from.dir)
    } else {
        srcs = pane.selection(from)
    }
    if len(srcs) == 0 {
        return true
    }
    if dst == from.dir {
        return fail(a, "same dir on both sides")
    }
    send_start(a, srcs, from.dir, dst, move)
    pane.clear_marks(from)
    return true
}

// `@N` / `@±N` names a pane's dir, anything else a path. "" with ok: no pane there.
@(private = "file")
target_dir :: proc(a: ^App, args: string) -> (dir: string, ok: bool) {
    if args == "" || args[0] == '@' || args[0] == '#' {
        t := pane_ref(args) or_return
        i, has := cl.target_index(t, a.active, len(a.panes))
        return has ? a.panes[i].dir : "", true // no pane there is ok: nothing to do
    }
    dir = abs_path(args, a.panes[a.active].dir)
    return dir, os.is_dir(dir)
}

// `~` is home; a relative path is under `base`.
@(private = "file")
abs_path :: proc(path, base: string) -> string {
    p := path
    if p == "~" || strings.has_prefix(p, "~/") {
        p = fmt.tprintf("%s%s", os.get_env("HOME", context.temp_allocator), p[1:])
    }
    if !filepath.is_abs(p) {
        p = filepath.join({base, p}, context.temp_allocator) or_else p
    }
    return filepath.clean(p, context.temp_allocator) or_else p
}

@(private = "file")
feed_paths :: proc(feed, base: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for line in strings.split_lines(feed, context.temp_allocator) {
        if line != "" {
            append(&out, abs_path(line, base))
        }
    }
    return out[:]
}

// A shell step inside a pipe: `sh -c` in the pane's dir, the feed on stdin, stdout passed on.
@(private = "file")
run_filter_step :: proc(a: ^App, step: cl.Step, cmd: string) -> bool {
    feed, _ := cl.piped(&a.chain, step)
    // (hole filter-async :tags input :sev gap) a filter runs on the main thread; a slow one freezes the UI.
    out, msg, ok := run_filter(cmd, feed, a.panes[a.active].dir)
    if !ok {
        return fail(a, msg)
    }
    if step.feeds {
        cl.feed_set(&a.chain, out)
    }
    return true
}

// The feed goes through a temp file: a pipe would block on a feed bigger than its buffer.
@(private = "file")
run_filter :: proc(cmd, feed, dir: string) -> (out, msg: string, ok: bool) {
    f, err := os.create_temp_file("", "oter-feed-*")
    if err != nil {
        return "", os.error_string(err), false
    }
    path := strings.clone(os.name(f), context.temp_allocator) // close frees the name
    defer os.remove(path)
    defer os.close(f)
    os.write_string(f, feed)
    os.seek(f, 0, .Start)
    state, stdout, stderr, perr := os.process_exec(
        {command = {"sh", "-c", cmd}, working_dir = dir, stdin = f},
        context.temp_allocator,
    )
    if perr != nil {
        return "", os.error_string(perr), false
    }
    if !state.success {
        why := strings.trim_space(string(stderr))
        return "", fmt.tprintf("%s: %s", cmd, why != "" ? why : fmt.tprintf("exit %d", state.exit_code)), false
    }
    return string(stdout), "", true
}
