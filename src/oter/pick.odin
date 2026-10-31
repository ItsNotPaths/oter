package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oket:cl"
import "../pane"

USAGE_PICK :: "usage: oter --pick <multiple> <directory> <save> <path> <out>"
NO_PICK_SHELL :: "the pick pane runs no shell: mv -- <old> <new> renames a row"

@(rodata)
PICK_TITLES := [pane.Want]string {
    .File  = "open a file",
    .Files = "open files",
    .Dir   = "pick a folder",
    .Save  = "save as",
}

// termfilechooser's wrapper args: three 0/1 flags, the start or suggested path, the answer file.
Pick_Args :: struct {
    want:      pane.Want,
    path, out: string,
}

// `--pick` and its five args. found without ok: it was there but malformed.
pick_args :: proc(args: []string) -> (pk: Pick_Args, found, ok: bool) {
    for arg, i in args {
        if arg != "--pick" {
            continue
        }
        rest := args[i + 1:]
        if len(rest) < 5 || rest[4] == "" {
            return {}, true, false
        }
        switch {
        case rest[2] == "1":
            pk.want = .Save
        case rest[1] == "1":
            pk.want = .Dir
        case rest[0] == "1":
            pk.want = .Files
        }
        return {pk.want, rest[3], rest[4]}, true, true
    }
    return
}

// The pick pane, then one normal pane at the path's dir.
pick_open :: proc(a: ^App, pk: Pick_Args, fallback: string) {
    start := pk.want == .Save || !os.is_dir(pk.path) ? filepath.dir(pk.path) : pk.path
    if !os.is_dir(start) {
        start = fallback
    }
    picks, files: pane.Pane
    pane.open_pick(&picks, pk.want, pk.path)
    pane.open(&files, start)
    append(&a.panes, picks, files)
    a.active = 1
    a.pick_out = pk.out
}

pick_pane :: proc(a: ^App) -> (^pane.Pane, bool) {
    for &p in a.panes {
        if pane.is_pick(&p) {
            return &p, true
        }
    }
    return nil, false
}

// Throws `srcs` into the pick pane `to`.
pick_throw :: proc(a: ^App, to: ^pane.Pane, srcs: []string) -> bool {
    for src in srcs {
        if file, has := pane.archive_of(src); has && file != src {
            return fail(a, "can't pick inside an archive")
        }
        if why := pane.pick_add(to, src); why != "" {
            return fail(a, why)
        }
    }
    pane.unmark(&a.panes[a.active])
    return true
}

// A lone shell step in the pick pane: only `mv [--] <old> <new>`, which renames a row.
pick_mv :: proc(a: ^App, p: ^pane.Pane, cmd: string) -> bool {
    words := sh_words(cmd)
    if len(words) == 0 || words[0] != "mv" {
        return fail(a, NO_PICK_SHELL)
    }
    words = words[1:]
    if len(words) > 0 && words[0] == "--" {
        words = words[1:]
    }
    if len(words) != 2 {
        return fail(a, "mv -- <old> <new>")
    }
    if why := pane.pick_rename(p, words[0], words[1]); why != "" {
        return fail(a, why)
    }
    return true
}

// The rows to the answer file, one per line, then quit.
pick_confirm :: proc(a: ^App) -> bool {
    p, ok := pick_pane(a)
    if !ok {
        return fail(a, ":confirm: this is not a file dialog")
    }
    rows := pane.picked(p)
    if len(rows) == 0 {
        return fail(a, "nothing picked yet")
    }
    text := strings.concatenate({strings.join(rows, "\n", context.temp_allocator), "\n"}, context.temp_allocator)
    if err := os.write_entire_file(a.pick_out, text); err != nil {
        return fail(a, fmt.tprintf(":confirm: cannot write %s (%v)", a.pick_out, err))
    }
    a.running = false
    return true
}

// Shell words, quotes taken off.
@(private = "file")
sh_words :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    rest := strings.trim_left_space(s)
    for rest != "" {
        raw, value := cl.first_arg(rest)
        if raw == "" {
            break
        }
        append(&out, value)
        rest = strings.trim_left_space(rest[len(raw):])
    }
    return out[:]
}
