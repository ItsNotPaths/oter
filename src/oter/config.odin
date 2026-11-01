package oter

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "oket:gfx"
import "oket:pty"
import "oket:theme"
import "../fsop"

@(rodata)
CONFIG_SECTIONS := [?]string{"launch", "theme", "editor", "copy", "move"}

// Every default, in config.conf's own words. The file is written from this on first start.
DEFAULT_CONFIG :: `[launch]
panes = 2
# the file dialog's window, as a share of the screen
pick = 0.6

# helix TOML from themes/<name>.toml beside this file; gruvbox is built in
[theme]
name = gruvbox

# Tried in order; the first whose program is installed is $OTER_EDITOR in binds.
[editor]
line = oket
line = micro
line = vi
line = vim
line = nvim
line = hx

# Tried in order; the first whose program is installed runs. A list here replaces the default.
# $o_src is the item, $o_dir the target dir, $o_dst the item's path in it.
[copy]
line = rsync -a --ignore-existing --info=progress2 -- $o_src $o_dir/
line = cp -aT --update=none -- $o_src $o_dst

[move]
line = mv -T --update=none -- $o_src $o_dst
`

Config :: struct {
    panes: int, // open at launch
    pick:  f32, // the pick window's share of the display
    theme:  string, // owned
    editor: [dynamic]string, // owned
    copy:   [dynamic]string, // owned
    move:   [dynamic]string, // owned
}

// Rows from `text` over `cfg`. A list's first row drops what was there. One message per bad row.
config_parse :: proc(cfg: ^Config, text, file: string) -> (bad: [dynamic]string) {
    started: [len(CONFIG_SECTIONS)]bool
    for r in conf_rows(text, file, CONFIG_SECTIONS[:], &bad) {
        switch fmt.tprintf("%s.%s", CONFIG_SECTIONS[r.section], r.key) {
        case "launch.panes":
            n, ok := strconv.parse_int(r.value)
            if !ok || n < 1 {
                append(&bad, fmt.aprintf("%s:%d: panes takes a number from 1", file, r.line))
                continue
            }
            cfg.panes = n
        case "launch.pick":
            f, ok := strconv.parse_f32(r.value)
            if !ok || f < 0.1 || f > 1 {
                append(&bad, fmt.aprintf("%s:%d: pick takes a share from 0.1 to 1", file, r.line))
                continue
            }
            cfg.pick = f
        case "theme.name":
            delete(cfg.theme)
            cfg.theme = strings.clone(r.value)
        case "editor.line", "copy.line", "move.line":
            list := &cfg.editor
            switch CONFIG_SECTIONS[r.section] {
            case "copy": list = &cfg.copy
            case "move": list = &cfg.move
            }
            if !started[r.section] {
                lines_clear(list)
                started[r.section] = true
            }
            append(list, strings.clone(r.value))
        case:
            append(&bad, fmt.aprintf("%s:%d: no %s in [%s]", file, r.line, r.key, CONFIG_SECTIONS[r.section]))
        }
    }
    return
}

config_destroy :: proc(cfg: ^Config) {
    delete(cfg.theme)
    for list in ([]^[dynamic]string{&cfg.editor, &cfg.copy, &cfg.move}) {
        lines_clear(list)
        delete(list^)
    }
    cfg^ = {}
}

@(private = "file")
lines_clear :: proc(list: ^[dynamic]string) {
    for l in list {
        delete(l)
    }
    clear(list)
}

// Defaults, then config.conf over them, then its theme and editor.
config_load :: proc(a: ^App) {
    report_bad(a, config_read(a, &a.config))
    theme_apply(a)
    editor_export(a)
}

// Inherited by the drawer shell, so set before it starts.
@(private = "file")
editor_export :: proc(a: ^App) {
    line, found := fsop.pick(a.config.editor[:])
    if !found {
        status_set(a, "no editor installed", true)
        return
    }
    _ = os.set_env("OTER_EDITOR", line)
}

// config.conf's theme again, applied if `oter --theme` moved it.
theme_reload :: proc(a: ^App) {
    cfg: Config
    defer config_destroy(&cfg)
    bad_free(config_read(a, &cfg)) // reported once, at start
    if cfg.theme != a.config.theme {
        a.config.theme, cfg.theme = cfg.theme, a.config.theme
        theme_apply(a)
    }
}

@(private = "file")
config_read :: proc(a: ^App, cfg: ^Config) -> (bad: [dynamic]string) {
    bad = config_parse(cfg, DEFAULT_CONFIG, "defaults")
    assert(len(bad) == 0, "a default config row does not parse")
    if text, path, found := conf_read(a, "config.conf", DEFAULT_CONFIG); found {
        delete(bad)
        bad = config_parse(cfg, text, path)
    }
    return
}

@(private = "file")
theme_apply :: proc(a: ^App) {
    a.theme = gfx.DEFAULT_THEME
    if a.home.config != "" { // "themes/" relative is somebody's cwd
        scopes: map[string]theme.Entry
        defer theme.forget(&scopes) // oter draws no syntax
        problem: string
        a.theme, problem = theme.load(&scopes, a.home.config, a.config.theme)
        if problem != "" {
            status_set(a, problem, true)
        }
    }
    if pty.terminal_alive(&a.term0) {
        pty.terminal_set_default_colors(&a.term0, a.theme[.Fg], a.theme[.Bg])
    }
}
