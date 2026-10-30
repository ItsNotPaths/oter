package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oket:cl"
import "../pane"

// Runs a CL line: builtins in-process, shell steps inside a pipe as filters.
run_line :: proc(a: ^App, line: string) {
    ch := &a.chain
    cl.parse(ch, line, a, proc(a: ^App, name: string) -> string {return ""})
    for {
        step, ok := cl.next(ch)
        if !ok {
            break
        }
        cl.done(ch, step.shell ? run_shell(a, step) : run_builtin(a, step))
    }
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
    switch name {
    case "sel":
        return builtin_sel(a)
    case "copy", "move":
        return builtin_send(a, step, args, name == "move")
    }
    return fail(a, fmt.tprintf(":%s: no such builtin", name))
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
        t, _, parsed := cl.target_parse(args)
        if !parsed || t.slot != 0 || t.slots || t.how == .Showing || t.how == .All {
            return "", false
        }
        i, has := cl.target_index(t, a.active, len(a.panes))
        return has ? a.panes[i].dir : "", true
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
run_shell :: proc(a: ^App, step: cl.Step) -> bool {
    feed, piped := cl.piped(&a.chain, step)
    if !piped && !step.feeds {
        // (hole cl-shell :tags (input term) :sev gap :needs term0) a shell step on its own has no term0 to run in.
        return fail(a, fmt.tprintf("%s: shell steps outside a pipe need term0", step.text))
    }
    // (hole filter-async :tags input :sev gap) a filter runs on the main thread; a slow one freezes the UI.
    out, msg, ok := run_filter(step.text, feed, a.panes[a.active].dir)
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
