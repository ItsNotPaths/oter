package oter

import "core:fmt"
import sdl "vendor:sdl3"
import "oket:gfx"
import "../pane"

// Each pane: a path row, then the list.
list_rows :: proc(a: ^App) -> int {
    return layout(a).panes.h - 1
}

draw :: proc(a: ^App) {
    w, h: i32
    sdl.GetWindowSizeInPixels(a.window, &w, &h)
    cw, ch := gfx.painter_cell(&a.painter)
    if !gfx.grid_resize(&a.grid, max(int(w) / cw, 1), max(int(h) / ch, 1)) {
        return
    }
    th := a.theme
    gfx.grid_clear(&a.grid, th[.Fg], gfx.opaque(th[.Bg]))

    l := layout(a)
    draw_sidebar(a, l.sidebar)
    draw_panes(a, l.panes)
    draw_drawer(a, l.drawer)
    draw_cl(a, l.cl)

    gfx.gl_clear(w, h, th[.Bg])
    gfx.painter_draw(&a.painter, &a.grid, w, h, {0, 0}, gfx.Rect{0, 0, f32(w), f32(h)})
}

// (hole places :tags ui :sev gap) sidebar is an empty box; no places file.
draw_sidebar :: proc(a: ^App, r: Rect) {
    th := a.theme
    bg := gfx.opaque(th[.Bg])
    header := a.in_sidebar ? gfx.Attrs{.Reverse} : gfx.Attrs{}
    for col in r.x ..< r.x + r.w - 1 {
        gfx.grid_put(&a.grid, col, r.y, gfx.Cell{' ', th[.Accent], bg, header, 0})
    }
    write_clipped(&a.grid, r.x, r.y, r.w - 1, "places", th[.Accent], bg, header)
    vline(a, r.x + r.w - 1, r.y, r.h)
}

draw_panes :: proc(a: ^App, r: Rect) {
    if r.h < 2 {
        return
    }
    n := len(a.panes)
    width := (r.w - (n - 1)) / n
    for &p, i in a.panes {
        x := r.x + i * (width + 1)
        draw_pane(a, &p, x, width, i == a.active && !a.in_sidebar)
        if i < n - 1 {
            vline(a, x + width, r.y, r.h)
        }
    }
}

// (hole drawer :tags (ui term) :sev gap :needs term0) drawer is an empty box; no terminal cells.
draw_drawer :: proc(a: ^App, r: Rect) {
    if r.h == 0 {
        return
    }
    th := a.theme
    bg := gfx.opaque(th[.Bg])
    for col in r.x ..< r.x + r.w {
        gfx.grid_put(&a.grid, col, r.y, gfx.Cell{'─', th[.Dim], bg, {}, 0})
    }
    label := a.drawer == .Full ? " term0 (full) " : " term0 "
    write_clipped(&a.grid, r.x + 2, r.y, r.w - 2, label, th[.Dim], bg, {})
}

draw_cl :: proc(a: ^App, r: Rect) {
    th := a.theme
    bar := gfx.opaque(gfx.shade(th[.Dim], 50))
    for col in r.x ..< r.x + r.w {
        gfx.grid_put(&a.grid, col, r.y, gfx.Cell{' ', th[.Fg], bar, {}, 0})
    }
    // (hole status-line :tags ui :sev blocker) CL row is a bare ":"; no result or error text.
    // (hole cl-input :tags (ui input) :sev gap :needs status-line) CL row takes no typing.
    write_clipped(&a.grid, r.x, r.y, r.w, ":", th[.Fg], bar, {})
}

vline :: proc(a: ^App, x, y, h: int) {
    th := a.theme
    for row in y ..< y + h {
        gfx.grid_put(&a.grid, x, row, gfx.Cell{'│', th[.Dim], gfx.opaque(th[.Bg]), {}, 0})
    }
}

draw_pane :: proc(a: ^App, p: ^pane.Pane, x, width: int, active: bool) {
    th := a.theme
    bg := gfx.opaque(th[.Bg])
    g := &a.grid

    header := active ? gfx.Attrs{.Reverse} : gfx.Attrs{}
    for col in x ..< x + width {
        gfx.grid_put(g, col, 0, gfx.Cell{' ', th[.Accent], bg, header, 0})
    }
    write_clipped(g, x, 0, width, p.dir, th[.Accent], bg, header)

    rows := list_rows(a)
    if p.err != nil {
        write_clipped(g, x, 1, width, fmt.tprint(p.err), th[.Alert], bg, {})
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
            for col in x ..< x + width {
                gfx.grid_put(g, col, row + 1, gfx.Cell{' ', fg, row_bg, {}, 0})
            }
        }
        write_clipped(g, x, row + 1, width, name, fg, row_bg, {})
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
