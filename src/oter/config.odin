package oter

import "core:fmt"
import "core:strconv"
import "core:strings"
import "oket:gfx"
import "oket:theme"

@(rodata)
CONFIG_SECTIONS := [?]string{"launch", "theme", "copy", "move"}

// Every default, in config.conf's own words. The file is written from this on first start.
DEFAULT_CONFIG :: `[launch]
panes = 2
# the file dialog's window, as a share of the screen
pick = 0.6

# helix TOML from themes/<name>.toml beside this file; gruvbox is built in
[theme]
name = gruvbox

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
    theme: string, // owned
    copy:  [dynamic]string, // owned
    move:  [dynamic]string, // owned
}

// Rows from `text` over `cfg`. A list's first row drops what was there. One message per bad row.
config_parse :: proc(cfg: ^Config, text, file: string) -> (bad: [dynamic]string) {
    started: [2]bool
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
        case "copy.line", "move.line":
            move := CONFIG_SECTIONS[r.section] == "move"
            list := move ? &cfg.move : &cfg.copy
            if !started[int(move)] {
                lines_clear(list)
                started[int(move)] = true
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
    lines_clear(&cfg.copy)
    lines_clear(&cfg.move)
    delete(cfg.copy)
    delete(cfg.move)
    cfg^ = {}
}

@(private = "file")
lines_clear :: proc(list: ^[dynamic]string) {
    for l in list {
        delete(l)
    }
    clear(list)
}

// Defaults, then config.conf over them, then its theme.
config_load :: proc(a: ^App) {
    bad := config_parse(&a.config, DEFAULT_CONFIG, "defaults")
    assert(len(bad) == 0, "a default config row does not parse")
    delete(bad)
    if text, path, found := conf_read(a, "config.conf", DEFAULT_CONFIG); found {
        report_bad(a, config_parse(&a.config, text, path))
    }

    a.theme = gfx.DEFAULT_THEME
    if a.home.config == "" {
        return // "themes/" relative is somebody's cwd
    }
    scopes: map[string]theme.Entry
    defer theme.forget(&scopes) // oter draws no syntax
    problem: string
    a.theme, problem = theme.load(&scopes, a.home.config, a.config.theme)
    if problem != "" {
        status_set(a, problem, true)
    }
}
