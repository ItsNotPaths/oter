package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

APP_DIR :: "oter"

// Where oter's own files live. Installed (the binary is in a bin dir): ~/.config/oter.
// Portable: beside the binary, read but never written on start.
Home :: struct {
    portable: bool,
    config:   string, // owned; "" reads and writes nothing
}

home_resolve :: proc() -> Home {
    dir := filepath.dir(exe_path())
    if filepath.base(dir) != "bin" {
        return {portable = true, config = strings.clone(dir)}
    }
    return {config = xdg_config()}
}

home_destroy :: proc(h: ^Home) {
    delete(h.config)
    h^ = {}
}

// ~/.config/oter, `$XDG_CONFIG_HOME` honoured. Owned; "" with no $HOME.
xdg_config :: proc() -> string {
    root := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
    if !filepath.is_abs(root) {
        home := os.get_env("HOME", context.temp_allocator)
        if home == "" {
            return ""
        }
        root, _ = filepath.join({home, ".config"}, context.temp_allocator)
    }
    dir, _ := filepath.join({root, APP_DIR})
    return dir
}

// Temp-allocated.
exe_path :: proc() -> string {
    return os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0]
}

// Temp-allocated; "" with no config dir.
config_file :: proc(a: ^App, name: string) -> string {
    if a.home.config == "" {
        return ""
    }
    path, _ := filepath.join({a.home.config, name}, context.temp_allocator)
    return path
}

// A config file's text. Missing and installed: written from `defaults` first.
conf_read :: proc(a: ^App, name, defaults: string) -> (text: string, path: string, found: bool) {
    path = config_file(a, name)
    if path == "" {
        return
    }
    if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
        return string(data), path, true
    }
    if !a.home.portable {
        os.make_directory_all(a.home.config)
        _ = os.write_entire_file(path, defaults)
    }
    return
}

Row :: struct {
    section: int, // index into the file's section names
    key:     string,
    value:   string,
    line:    int,
}

// The `key = value` rows of `text`, each under the last known `[section]`. Temp-allocated;
// bad headers and rows go to `bad`.
conf_rows :: proc(text, file: string, sections: []string, bad: ^[dynamic]string) -> []Row {
    rows := make([dynamic]Row, context.temp_allocator)
    section := 0
    lines: for raw, n in strings.split_lines(text, context.temp_allocator) {
        line := strings.trim_space(raw)
        switch {
        case line == "" || line[0] == '#':
        case line[0] == '[' && line[len(line) - 1] == ']':
            name := line[1:len(line) - 1]
            for s, i in sections {
                if s == name {
                    section = i
                    continue lines
                }
            }
            append(bad, fmt.aprintf("%s:%d: no section [%s]", file, n + 1, name))
        case:
            key, eq, value := strings.partition(line, "=")
            if eq == "" {
                append(bad, fmt.aprintf("%s:%d: not `key = value`", file, n + 1))
                continue
            }
            append(&rows, Row{section, strings.trim_space(key), strings.trim_space(value), n + 1})
        }
    }
    return rows[:]
}

// The first bad row in the status line, with a count of the rest. Frees `bad`.
report_bad :: proc(a: ^App, bad: [dynamic]string) {
    defer bad_free(bad)
    if len(bad) > 0 {
        status_set(a, len(bad) == 1 ? bad[0] : fmt.tprintf("%s (and %d more)", bad[0], len(bad) - 1), true)
    }
}

bad_free :: proc(bad: [dynamic]string) {
    for m in bad {
        delete(m)
    }
    delete(bad)
}
