package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oter:oter"

@(private = "file")
path :: proc(parts: ..string) -> string {
    p, _ := filepath.join(parts, context.temp_allocator)
    return p
}

// A fake home under a temp dir, and a fake binary to install.
@(private = "file")
setup :: proc(t: ^testing.T) -> (root, exe: string, tg: oter.Install_Target) {
    err: os.Error
    root, err = os.make_directory_temp("", "oter-install-*", context.allocator)
    testing.expect(t, err == nil)
    exe = path(root, "build", "oter")
    testing.expect(t, os.make_directory_all(path(root, "build")) == nil)
    testing.expect(t, os.write_entire_file(exe, "binary") == nil)
    tg = {
        config  = strings.clone(path(root, ".config", "oter")),
        bin     = strings.clone(path(root, ".local", "bin", "oter")),
        desktop = strings.clone(path(root, ".local", "share", "applications", "oter.desktop")),
    }
    return
}

@(private = "file")
teardown :: proc(root: string, tg: ^oter.Install_Target) {
    oter.install_target_destroy(tg)
    os.remove_all(root)
    delete(root)
}

@(test)
an_install_lands_binary_config_and_launcher :: proc(t: ^testing.T) {
    root, exe, tg := setup(t)
    defer teardown(root, &tg)

    ok, _ := oter.install_run(tg, exe)
    testing.expect(t, ok)
    data, _ := os.read_entire_file(tg.bin, context.temp_allocator)
    testing.expect_value(t, string(data), "binary")
    testing.expect(t, os.exists(path(tg.config, "binds.conf")))
    testing.expect(t, os.exists(path(tg.config, "config.conf")))
    entry, _ := os.read_entire_file(tg.desktop, context.temp_allocator)
    testing.expect(t, strings.contains(string(entry), strings.concatenate({"Exec=", tg.bin}, context.temp_allocator)))
}

// An uninstall you have to finish by hand is not one.
@(test)
an_uninstall_leaves_nothing :: proc(t: ^testing.T) {
    root, exe, tg := setup(t)
    defer teardown(root, &tg)
    oter.install_run(tg, exe)
    testing.expect(t, os.write_entire_file(path(tg.config, "places"), "~\n") == nil)

    ok, _ := oter.install_remove(tg)
    testing.expect(t, ok)
    for p in ([]string{tg.config, tg.bin, tg.desktop}) {
        testing.expect(t, !os.exists(p), p)
    }
}

@(test)
uninstalling_nothing_says_so :: proc(t: ^testing.T) {
    root, _, tg := setup(t)
    defer teardown(root, &tg)

    ok, _ := oter.install_remove(tg)
    testing.expect(t, !ok)
}
