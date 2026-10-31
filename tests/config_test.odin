package tests

import "core:testing"
import "oter:oter"

@(private = "file")
load :: proc(cfg: ^oter.Config, file: string) -> [dynamic]string {
    delete(oter.config_parse(cfg, oter.DEFAULT_CONFIG, "defaults"))
    return oter.config_parse(cfg, file, "config.conf")
}

@(private = "file")
free_bad :: proc(bad: [dynamic]string) {
    for m in bad {
        delete(m)
    }
    delete(bad)
}

@(test)
defaults_open_two_panes_in_gruvbox :: proc(t: ^testing.T) {
    cfg: oter.Config
    defer oter.config_destroy(&cfg)
    bad := load(&cfg, "")
    defer free_bad(bad)

    testing.expect_value(t, len(bad), 0)
    testing.expect_value(t, cfg.panes, 2)
    testing.expect_value(t, cfg.theme, "gruvbox")
    testing.expect(t, len(cfg.copy) > 0 && len(cfg.move) > 0)
}

// A copy list in the file is the whole list; move keeps its default.
@(test)
a_file_list_replaces_the_default :: proc(t: ^testing.T) {
    cfg: oter.Config
    defer oter.config_destroy(&cfg)
    bad := load(&cfg, "[copy]\nline = a $o_src\nline = b $o_src\n")
    defer free_bad(bad)

    testing.expect_value(t, len(bad), 0)
    testing.expect_value(t, len(cfg.copy), 2)
    testing.expect_value(t, cfg.copy[0], "a $o_src")
    testing.expect_value(t, cfg.copy[1], "b $o_src")
    testing.expect_value(t, len(cfg.move), 1)
}

@(test)
bad_settings_are_reported_and_the_rest_lands :: proc(t: ^testing.T) {
    cfg: oter.Config
    defer oter.config_destroy(&cfg)
    bad := load(&cfg, "[launch]\npanes = 0\ncolour = red\nnot a row\n[nope]\n[theme]\nname = nord\n[launch]\npanes = 3\n")
    defer free_bad(bad)

    testing.expect_value(t, len(bad), 4)
    testing.expect_value(t, cfg.theme, "nord")
    testing.expect_value(t, cfg.panes, 3)
}
