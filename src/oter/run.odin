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
        status_set(a, "a step is still running", true)
        return
    }
    cl.parse(ch, line, a, proc(a: ^App, name: string) -> string {return ""}, proc(a: ^App, name: string) -> bool {
        return name == "stage" // `:stage <text>` takes the rest raw, operators and all
    })
    p := &a.panes[a.active]
    vars: cl.Vars
    if a.mode == .Sidebar {
        if path, ok := place_current(a); ok {
            vars[var("src")] = path
        }
    } else if e, ok := pane.current(p); ok {
        vars[var("src")] = pane.path_of(p, e.name)
    }
    if src, ok := vars[var("src")].?; ok {
        vars[var("name")] = filepath.base(src)
    }
    vars[var("dir")] = p.dir
    cl.vars_set(ch, vars)
    chain_pump(a)
}

// Steps until the chain ends, or waits on a term0 step or a filter (their polls resume it).
chain_pump :: proc(a: ^App) {
    ch := &a.chain
    for {
        step, ok := cl.next(ch)
        if !ok {
            return
        }
        cmd, missing, filled := cl.fill(ch.vars, step.text)
        if !filled {
            cl.done(ch, fail(a, fmt.tprintf("no $o_%s here", missing)))
            continue
        }
        shell := step.shell
        if !shell && cl.first_field(cmd) == "oter" {
            line, ok := oter_line(a, strings.trim_space(cmd[len("oter"):]))
            if !ok {
                cl.done(ch, false)
                continue
            }
            cmd, shell = line, true
        }
        if !shell {
            filled_step := step
            filled_step.text = cmd
            cl.done(ch, run_builtin(a, filled_step))
            continue
        }
        if !pane.is_real(&a.panes[a.active]) {
            cl.done(ch, fail(a, NO_SHELL))
            continue
        }
        if _, piped := cl.piped(ch, step); piped || step.feeds {
            filter_start(a, step, cmd)
            return
        }
        if !term0_run(a, cmd) {
            cl.done(ch, false)
            continue
        }
        ch.waiting = true
        return
    }
}

NO_SHELL :: "can't run shell inside an archive"

@(private = "file")
var :: proc(name: string) -> int {
    i, ok := cl.var_index(name)
    assert(ok)
    return i
}

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
    case "stage":
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
    case "place":
        return builtin_place(a, args)
    case "open":
        raw, path := cl.first_arg(args)
        i, ok := pane_target(a, args[len(raw):])
        if !ok {
            return fail(a, ":open <dir> [@N]")
        }
        if os.is_dir(path) {
            pane.open(&a.panes[i], path)
        } else if !archive_open(a, i, path) {
            return fail(a, fmt.tprintf(":open: no dir or archive at %s", path))
        }
        a.active = i
        if a.mode == .Sidebar {
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
    case "up", "down":
        pane.move(p, name == "up" ? -1 : +1)
        if on, painting := a.paint.?; painting {
            pane.mark_cursor(p, on)
        }
    case "pgup":
        pane.move(p, -max(list_rows(a) - 1, 1))
    case "pgdn":
        pane.move(p, +max(list_rows(a) - 1, 1))
    case "top":
        pane.move(p, -len(p.entries))
    case "bottom":
        pane.move(p, +len(p.entries))
    case "enter":
        if e, ok := pane.current(p); ok && !pane.enter(p) && pane.is_real(p) {
            archive_open(a, a.active, pane.path_of(p, e.name)) // no archives in archives
        }
    case "parent":
        pane.up(p)
    case "mark":
        if a.key.repeat {
            return true // holding the key paints, it does not flicker
        }
        on := pane.toggle_mark(p)
        if a.key.code != 0 {
            a.paint, a.paint_key = on, a.key.code
        }
    case "unmark":
        _, dir := cl.first_arg(args)
        pane.unmark(p, dir)
    case "font.bigger":
        return font_zoom(a, +1)
    case "font.smaller":
        return font_zoom(a, -1)
    case "font.reset":
        return font_reset(a)
    case "np":
        dir, real := strings.clone(p.dir, context.temp_allocator), pane.is_real(p) // inject_at moves `p`
        np: pane.Pane
        pane.open(&np, real ? dir : filepath.dir(dir))
        a.active += 1
        inject_at(&a.panes, a.active, np)
        frame_pane_insert(&a.frame, a.active)
        if !real {
            archive_open(a, a.active, dir) // cached, so at once
        }
    case "close":
        if len(a.panes) < 2 {
            return fail(a, ":close: one pane left")
        }
        pane.destroy(p)
        ordered_remove(&a.panes, a.active)
        frame_pane_remove(&a.frame, a.active)
        a.active = min(a.active, len(a.panes) - 1)
    case "focus", "swap":
        i, ok := pane_target(a, args)
        if !ok {
            return fail(a, fmt.tprintf(":%s: %s is not a pane", name, args))
        }
        if name == "swap" {
            a.panes[a.active], a.panes[i] = a.panes[i], a.panes[a.active]
            frame_pane_swap(&a.frame, a.active, i)
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
    if i, is_pane := pane_target(a, args); is_pane && !pane.is_real(&a.panes[i]) {
        return fail(a, "can't copy into an archive")
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
    archive, one_side := srcs_archive(srcs)
    if !one_side {
        return fail(a, "archive and disk items in one send")
    }
    if archive != "" && move {
        return fail(a, "archives are read-only: copy, not move")
    }
    if dst == from.dir {
        return fail(a, "same dir on both sides")
    }
    send_start(a, srcs, from.dir, dst, move, archive)
    pane.unmark(from)
    return true
}

// The archive every src is inside, "" if none is. Not ok if some are and some are not.
@(private = "file")
srcs_archive :: proc(srcs: []string) -> (archive: string, ok: bool) {
    for src, k in srcs {
        file, has := pane.archive_of(src)
        if !has || file == src {
            file = "" // a real file or dir
        }
        if k > 0 && file != archive {
            return "", false
        }
        archive = file
    }
    return archive, true
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
