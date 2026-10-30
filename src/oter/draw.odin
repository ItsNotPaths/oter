package oter

import "core:fmt"
import sdl "vendor:sdl3"
import "oket:gfx"
import "../pane"

// Each pane: a path row, then the list.
list_rows :: proc(a: ^App) -> int {
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
        draw_pane(a, &p, &f.panes[i], i == a.active && !a.in_sidebar)
    }
    draw_drawer(a, &f.drawer)
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

// (hole places :tags ui :sev gap) sidebar is an empty box; no places file.
draw_sidebar :: proc(a: ^App, r: ^Region) {
    th := a.theme
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], gfx.opaque(th[.Bg]))
    cols, _ := region_cells(a, r)
    header(g, cols, "places", a.in_sidebar, th)
}

// (hole drawer :tags (ui term) :sev gap :needs term0) drawer is an empty box; no terminal cells.
draw_drawer :: proc(a: ^App, r: ^Region) {
    th := a.theme
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], gfx.opaque(th[.Bg]))
    cols, _ := region_cells(a, r)
    write_clipped(g, 0, 0, cols, a.drawer == .Full ? "term0 (full)" : "term0", th[.Dim], gfx.opaque(th[.Bg]), {})
}

draw_cl :: proc(a: ^App, r: ^Region) {
    th := a.theme
    bar := gfx.opaque(gfx.theme_behind(th, BAR_BEHIND))
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], bar)
    cols, _ := region_cells(a, r)
    // (hole cl-input :tags (ui input) :sev gap) CL row takes no typing.
    write_clipped(g, 1, 0, cols - 1, a.status, a.status_err ? th[.Alert] : th[.Fg], bar, {})
}

draw_pane :: proc(a: ^App, p: ^pane.Pane, r: ^Region, active: bool) {
    th := a.theme
    bg := gfx.opaque(th[.Bg])
    g := &r.grid
    gfx.grid_clear(g, th[.Fg], bg)
    cols, rows := region_cells(a, r)
    header(g, cols, p.dir, active, th)

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
        // (hole ghost-rows :tags (ui files) :sev blocker) in-flight items do not show as greyed rows.
        if i == p.cursor {
            row_bg = gfx.opaque(active ? th[.Dim] : gfx.shade(th[.Dim], 50))
            for col in 0 ..< g.cols {
                gfx.grid_put(g, col, row + 1, gfx.Cell{' ', fg, row_bg, {}, 0})
            }
        }
        if e.marked {
            gfx.grid_put(g, 0, row + 1, gfx.Cell{'▎', th[.Accent], row_bg, {}, 0})
        }
        write_clipped(g, 1, row + 1, cols - 1, name, fg, row_bg, {}) // col 0 is the mark gutter
    }
}

// A region's title row; reversed when it has focus.
header :: proc(g: ^gfx.Grid, cols: int, title: string, focused: bool, th: gfx.Theme) {
    bg := gfx.opaque(th[.Bg])
    attrs := focused ? gfx.Attrs{.Reverse} : gfx.Attrs{}
    for col in 0 ..< g.cols {
        gfx.grid_put(g, col, 0, gfx.Cell{' ', th[.Accent], bg, attrs, 0})
    }
    write_clipped(g, 0, 0, cols, title, th[.Accent], bg, attrs)
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
