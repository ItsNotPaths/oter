package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "oket:cl"

USAGE_OTER :: ":oter status | install | uninstall | update | theme"
UPDATE_LINE :: "curl -fsSL https://github.com/ItsNotPaths/oter/releases/latest/download/install.sh | sh"

// A template: its `oter` command word becomes the installed binary's full path.
DESKTOP_SRC :: #load("../../oter.desktop", string)
// A template like the launcher: termfilechooser runs it, it runs `oter --pick`.
PICK_SRC :: #load("../../oter-pick.sh", string)
// Found by name (`Icon=oter`) through the icon theme.
ICON_SRC :: #load("../../assets/oter.svg", string)

// Where an install writes. Owned; all "" with no $HOME.
Install_Target :: struct {
    config:  string,
    bin:     string,
    desktop: string,
    icon:    string,
}

// The file dialog's wrapper, beside the binary. Temp-allocated.
pick_script :: proc(t: Install_Target) -> string {
    return filepath.join({filepath.dir(t.bin), "oter-pick.sh"}, context.temp_allocator) or_else ""
}

install_target :: proc() -> (t: Install_Target) {
    home := os.get_env("HOME", context.temp_allocator)
    if home == "" {
        return
    }
    t.config = xdg_config()
    t.bin, _ = filepath.join({home, ".local/bin", APP_DIR})
    data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
    if !filepath.is_abs(data) {
        data, _ = filepath.join({home, ".local/share"}, context.temp_allocator)
    }
    t.desktop, _ = filepath.join({data, "applications", "oter.desktop"})
    t.icon, _ = filepath.join({data, "icons/hicolor/scalable/apps", "oter.svg"})
    return
}

install_target_destroy :: proc(t: ^Install_Target) {
    delete(t.config)
    delete(t.bin)
    delete(t.desktop)
    delete(t.icon)
    t^ = {}
}

PICK_HOWTO :: `  oter as the file dialog needs xdg-desktop-portal-termfilechooser, and two files of yours:
    ~/.config/xdg-desktop-portal-termfilechooser/config
      [filechooser]
      cmd=%s
    ~/.config/xdg-desktop-portal/portals.conf
      [preferred]
      org.freedesktop.impl.portal.FileChooser=termfilechooser`

// Idempotent. Binary, binds.conf and config.conf are replaced; places is left alone.
install_run :: proc(t: Install_Target, exe: string) -> (ok: bool, msg: string) {
    if t.bin == "" {
        return false, "install: no $HOME, so there is nowhere to install to"
    }
    b := strings.builder_make(context.temp_allocator)
    for dir in ([?]string{filepath.dir(t.bin), t.config, filepath.dir(t.desktop), filepath.dir(t.icon)}) {
        if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
            return false, fmt.tprintf("install: cannot create %s (%v)", dir, err)
        }
    }

    if exe != t.bin {
        if err := publish(t.bin, exe); err != nil {
            return false, fmt.tprintf("install: cannot write %s (%v)", t.bin, err)
        }
        fmt.sbprintfln(&b, "  %s -> %s", exe, t.bin)
    }
    tmp := context.temp_allocator
    exec, _ := strings.replace_all(DESKTOP_SRC, "Exec=oter", strings.concatenate({"Exec=", t.bin}, tmp), tmp)
    files := [?][2]string {
        {filepath.join({t.config, "binds.conf"}, tmp) or_else "", DEFAULT_BINDS},
        {filepath.join({t.config, "config.conf"}, tmp) or_else "", DEFAULT_CONFIG},
        {t.desktop, exec},
        {t.icon, ICON_SRC},
    }
    for f in files {
        dst := f[0]
        if err := os.write_entire_file(dst, f[1]); err != nil {
            return false, fmt.tprintf("install: cannot write %s (%v)", dst, err)
        }
        fmt.sbprintfln(&b, "  %s", dst)
    }
    pick, _ := strings.replace_all(PICK_SRC, "exec oter ", strings.concatenate({"exec ", t.bin, " "}, tmp), tmp)
    if err := os.write_entire_file(pick_script(t), pick, os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}); err != nil {
        return false, fmt.tprintf("install: cannot write %s (%v)", pick_script(t), err)
    }
    fmt.sbprintfln(&b, "  %s", pick_script(t))

    bin_dir := filepath.dir(t.bin)
    if !on_path(bin_dir) {
        fmt.sbprintfln(&b, "  %s is not on your PATH. Add it:\n    export PATH=\"%s:$PATH\"", bin_dir, bin_dir)
    }
    fmt.sbprintfln(&b, PICK_HOWTO, pick_script(t))
    fmt.sbprintf(&b, "installed %s%s", t.bin, exe != t.bin ? "; restart to run it" : "")
    return true, strings.to_string(b)
}

// Everything: the binary, the launcher entry, the icon and the whole config dir, your edits with it.
install_remove :: proc(t: Install_Target) -> (ok: bool, msg: string) {
    if t.bin == "" {
        return false, "uninstall: no $HOME, so nothing could have been installed"
    }
    b := strings.builder_make(context.temp_allocator)
    for path in ([?]string{t.config, t.desktop, t.icon, pick_script(t), t.bin}) {
        if !os.exists(path) {
            continue
        }
        if err := os.remove_all(path); err != nil {
            return false, fmt.tprintf("uninstall: cannot remove %s (%v)", path, err)
        }
        fmt.sbprintfln(&b, "  removed %s", path)
    }
    if len(b.buf) == 0 {
        return false, "uninstall: nothing of an install is here to remove"
    }
    strings.write_string(&b, "uninstalled")
    return true, strings.to_string(b)
}

install_status :: proc(h: Home, t: Install_Target) -> string {
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintfln(&b, "binary:    %s", exe_path())
    fmt.sbprintfln(&b, "config:    %s%s", h.config, os.is_dir(h.config) ? "" : "   (not there)")
    fmt.sbprintfln(&b, "launcher:  %s", os.exists(t.desktop) ? t.desktop : "not in the application list")
    fmt.sbprintf(&b, "mode:      %s", h.portable ? "portable: config beside the binary, never written on start" : "installed")
    return strings.to_string(b)
}

// `--status`, `--install`, `--uninstall`, `--update`: before the window, so they work with no display.
install_cli :: proc(args: []string) -> (handled, ok: bool) {
    for arg in args {
        if arg != "--status" && arg != "--install" && arg != "--uninstall" && arg != "--update" {
            continue
        }
        t := install_target()
        defer install_target_destroy(&t)
        h := home_resolve()
        defer home_destroy(&h)
        msg: string
        switch arg {
        case "--status":
            ok, msg = true, install_status(h, t)
        case "--install":
            ok, msg = install_run(t, exe_path())
        case "--uninstall":
            ok, msg = install_remove(t)
        case "--update":
            if !h.portable {
                return true, update_run()
            }
            msg = "update: this copy is portable; oter --install first"
        }
        fmt.println(msg)
        return true, ok
    }
    return
}

// install.sh on this terminal, so its output is the answer.
@(private = "file")
update_run :: proc() -> bool {
    p, err := os.process_start({command = {"sh", "-c", UPDATE_LINE}, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
    if err != nil {
        fmt.eprintfln("update: %v", err)
        return false
    }
    state, _ := os.process_wait(p)
    return state.success
}

// `:oter <verb>` as the line term0 runs: this binary's own flag.
oter_line :: proc(a: ^App, verb: string) -> (line: string, ok: bool) {
    switch verb {
    case "", "status", "install", "uninstall", "update", "theme":
        return fmt.tprintf("%s --%s", cl.sh_quote(exe_path(), context.temp_allocator), verb == "" ? "status" : verb), true
    }
    status_set(a, USAGE_OTER, true)
    return
}

// Staged beside the target and renamed over it, so a running copy keeps its old inode.
@(private = "file")
publish :: proc(dst, src: string) -> os.Error {
    stage := fmt.tprintf("%s.tmp", dst)
    _ = os.remove(stage)
    os.copy_file(stage, src) or_return
    if err := os.rename(stage, dst); err != nil {
        _ = os.remove(stage)
        return err
    }
    return nil
}

@(private = "file")
on_path :: proc(dir: string) -> bool {
    rest := os.get_env("PATH", context.temp_allocator)
    for entry in strings.split_iterator(&rest, ":") {
        if entry == dir {
            return true
        }
    }
    return false
}
