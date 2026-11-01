package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "oter:oter"

@(private = "file")
theme_after_pick :: proc(t: ^testing.T, text: string) -> string {
    cfg: oter.Config
    defer oter.config_destroy(&cfg)
    bad := oter.config_parse(&cfg, oter.conf_with_theme(text, "nord"), "config.conf")
    defer oter.bad_free(bad)
    testing.expect_value(t, len(bad), 0)
    testing.expect_value(t, cfg.panes, 3)
    return fmt.tprint(cfg.theme)
}

// Whatever shape config.conf is in, a pick is the theme it reads, and the rest stays.
@(test)
a_pick_is_what_config_reads :: proc(t: ^testing.T) {
    testing.expect_value(t, theme_after_pick(t, "[launch]\npanes = 3\n[theme]\nname = gruvbox\n"), "nord")
    testing.expect_value(t, theme_after_pick(t, "[theme]\n[launch]\npanes = 3\n"), "nord")
    testing.expect_value(t, theme_after_pick(t, "[launch]\npanes = 3\n"), "nord")
}

// Themes on disk first, pulled ones marked, repo-only ones after; no name twice.
@(test)
here_before_away_and_pulled_marked :: proc(t: ^testing.T) {
    dir, err := os.make_directory_temp("", "oter-themer-*", context.temp_allocator)
    testing.expect(t, err == nil)
    defer os.remove_all(dir)
    for f in ([?]string{"zed.toml", "mine.toml", "notes.txt"}) {
        _ = os.write_entire_file(fmt.tprintf("%s/%s", dir, f), "")
    }
    _ = os.write_entire_file(fmt.tprintf("%s/.themer", dir), "zed\ngone\n")
    _ = os.write_entire_file(fmt.tprintf("%s/.list", dir), "nord\nzed\nacme\n")

    rows := oter.themes_scan(dir)
    defer {
        for r in rows {
            delete(r.name)
        }
        delete(rows)
    }
    want := [?]oter.Theme_Row{{"mine", .Here}, {"zed", .Pulled}, {"acme", .Away}, {"nord", .Away}}
    testing.expect_value(t, len(rows), len(want))
    for w, i in want {
        if i < len(rows) {
            testing.expect_value(t, rows[i], w)
        }
    }
}
