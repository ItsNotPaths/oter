package oter

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import "oket:gfx"
import "oket:pty"
import "../pane"

// Each pane: a path row, then the list.
list_rows :: proc(a: ^App) -> int {
    if a.active >= len(a.frame.panes) {
        return 1 // not drawn yet
    }
    _, rows := region_cells(a, &a.frame.panes[a.active])
    return rows - 1
}

draw :: proc(a: ^App) {
    w, h: i32
    sdl.GetWindowSizeInPixels(a.window, &w, &h)
    frame_fit(a, w, h)
    f := &a.frame

    draw_sidebar(a, &f.sidebar)
    for &p, i in a.panes {
        draw_pane(a, &p, &f.panes[i], i == a.active && a.mode != .Sidebar)
    }
    draw_term(a, &f.drawer)
    draw_cl(a, &f.cl)

    gfx.gl_clear(w, h, gfx.theme_behind(a.theme, BEHIND))
    region_paint(a, &f.sidebar)
    for &r in f.panes {
        region_paint(a, &r)
    }
    region_paint(a, &f.drawer)
    region_paint(a, &f.cl)
    region_rim(a, &f.sidebar)
    for &r in f.panes {
        region_rim(a, &r)
    }
    region_rim(a, &f.drawer)
}

draw_sidebar :: proc(a: ^App, r: ^Region) {
    th := a.theme
    bg := gfx.opaque(th[.Bg])
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], bg)
    cols, rows := region_cells(a, r)
    header(g, cols, "places", a.mode == .Sidebar, th)
    for i in 0 ..< min(place_slots(a), rows - 1) {
        pl := i < len(a.places) ? a.places[i] : Place{}
        row_bg := bg
        if i == a.place && a.mode == .Sidebar {
            row_bg = gfx.opaque(th[.Dim])
            row_fill(g, i + 1, th[.Fg], row_bg)
        }
        write_clipped(g, 0, i + 1, 3, fmt.tprintf("%02d", i + 1), th[.Dim], row_bg, {}) // `:place` counts these
        write_clipped(g, 3, i + 1, cols - 3, pl.text, pl.ok ? th[.Fg] : th[.Dim], row_bg, {})
    }
}

draw_cl :: proc(a: ^App, r: ^Region) {
    th := a.theme
    bar := gfx.opaque(gfx.theme_behind(th, BAR_BEHIND))
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], bar)
    cols, _ := region_cells(a, r)
    if a.mode != .Line {
        write_clipped(g, 1, 0, cols - 1, a.status, a.status_err ? th[.Alert] : th[.Fg], bar, {})
        return
    }
    text := string(a.line.text[:])
    write_clipped(g, 1, 0, cols - 1, text, th[.Fg], bar, {})
    at := 1 + strings.rune_count(text[:a.line.cursor])
    under := a.line.cursor < len(text) ? utf8.rune_at(text, a.line.cursor) : ' '
    if at < cols {
        gfx.grid_put(g, at, 0, gfx.Cell{under, th[.Fg], bar, {.Reverse}, 0})
    }
}

draw_pane :: proc(a: ^App, p: ^pane.Pane, r: ^Region, active: bool) {
    th := a.theme
    bg := gfx.opaque(th[.Bg])
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], bg)
    cols, rows := region_cells(a, r)
    title := p.dir
    if s, ok := p.src.(pane.Pick); ok {
        title = PICK_TITLES[s.want]
    }
    header(g, cols, title, active, th, marks_note(p))

    rows -= 1
    if p.err != nil {
        write_clipped(g, 0, 1, cols, fmt.tprint(p.err), th[.Alert], bg, {})
        return
    }
    pane.scroll(p, rows)
    for row in 0 ..< rows {
        i := p.top + row
        if i >= len(p.entries) {
            break
        }
        e := p.entries[i]
        fg := e.is_dir ? th[.Accent] : th[.Fg]
        name := e.is_dir ? fmt.tprintf("%s/", e.name) : e.name
        row_bg := bg
        if i == p.cursor {
            row_bg = gfx.opaque(active ? th[.Dim] : gfx.shade(th[.Dim], 50))
            row_fill(g, row + 1, fg, row_bg)
        }
        if pane.is_marked(p, e) {
            gfx.grid_put(g, 0, row + 1, gfx.Cell{'▎', th[.Accent], row_bg, {}, 0})
        }
        write_clipped(g, 1, row + 1, cols - 1, name, fg, row_bg, {}) // col 0 is the mark gutter
    }
    // Items still in flight to this dir, greyed under the list.
    row := len(p.entries) - p.top
    bar := gfx.opaque(gfx.shade(th[.Dim], 50))
    for gh in ghosts(a, p.dir) {
        if row >= rows {
            break
        }
        if row >= 0 {
            filled := 1 + (cols - 1) * gh.pct / 100 // the row fills by bytes as it lands
            col := 1
            for r in gh.name {
                if col >= cols {
                    break
                }
                gfx.grid_put(g, col, row + 1, gfx.Cell{r, th[.Dim], col < filled ? bar : bg, {}, 0})
                col += 1
            }
            for ; col < filled; col += 1 {
                gfx.grid_put(g, col, row + 1, gfx.Cell{' ', th[.Dim], bar, {}, 0})
            }
        }
        row += 1
    }
}

// A region's title row; reversed when it has focus.
header :: proc(g: ^gfx.Grid, cols: int, title: string, focused: bool, th: gfx.Theme, right := "") {
    bg := gfx.opaque(th[.Bg])
    attrs := focused ? gfx.Attrs{.Reverse} : gfx.Attrs{}
    for col in 0 ..< g.cols {
        gfx.grid_put(g, col, 0, gfx.Cell{' ', th[.Accent], bg, attrs, 0})
    }
    note := strings.rune_count(right)
    write_clipped(g, 0, 0, note > 0 ? cols - note - 1 : cols, title, th[.Accent], bg, attrs)
    write_clipped(g, max(cols - note, 0), 0, note, right, th[.Accent], bg, attrs)
}

// `5 yanked · 2 here`, so marks out of sight still show.
@(private = "file")
marks_note :: proc(p: ^pane.Pane) -> string {
    if len(p.marks) == 0 {
        return ""
    }
    here := 0
    for m in p.marks {
        here += int(filepath.dir(m) == p.dir)
    }
    return fmt.tprintf("%d yanked · %d here", len(p.marks), here)
}

row_fill :: proc(g: ^gfx.Grid, y: int, fg: [3]f32, bg: gfx.Rgba) {
    for col in 0 ..< g.cols {
        gfx.grid_put(g, col, y, gfx.Cell{' ', fg, bg, {}, 0})
    }
}

write_clipped :: proc(g: ^gfx.Grid, x, y, width: int, text: string, fg: [3]f32, bg: gfx.Rgba, attrs: gfx.Attrs) {
    col := x
    for r in text {
        if col >= x + width {
            break
        }
        gfx.grid_put(g, col, y, gfx.Cell{r, fg, bg, attrs, 0})
        col += 1
    }
}

// term0's cells, its bottom row on the region's bottom row, so a slide shows the prompt first.
draw_term :: proc(a: ^App, r: ^Region) {
    th := a.theme
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], gfx.opaque(th[.Bg]))
    t := &a.term0
    if !pty.terminal_alive(t) {
        cols, _ := region_cells(a, r)
        write_clipped(g, 0, 0, cols, "term0: no shell; the next shell line starts one", th[.Dim], gfx.opaque(th[.Bg]), {})
        return
    }
    _, rows := region_cells(a, r)
    top := t.rows - rows // vt rows above the region
    crow, ccol := pty.terminal_cursor(t)
    for row in max(top, 0) ..< t.rows {
        for col in 0 ..< t.cols {
            cell := pty.terminal_cell(t, row, col) or_continue
            fg, fdef := pty.terminal_color(t, cell.fg)
            bg, bdef := pty.terminal_color(t, cell.bg)
            if fdef {
                fg = th[.Fg]
            }
            if bdef {
                bg = th[.Bg]
            }
            if cell.attrs.reverse != (a.mode == .Term && row == crow && col == ccol) {
                fg, bg = bg, fg
            }
            attrs: gfx.Attrs
            if cell.attrs.bold {
                attrs += {.Bold}
            }
            if cell.attrs.italic {
                attrs += {.Italic}
            }
            if cell.attrs.underline != 0 {
                attrs += {.Underline}
            }
            ch := rune(cell.chars[0])
            if ch == 0 {
                ch = ' '
            }
            gfx.grid_put(g, col, row - top, gfx.Cell{ch, fg, gfx.opaque(bg), attrs, 0})
        }
    }
}
