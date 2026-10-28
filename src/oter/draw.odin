package oter

import "core:fmt"
import sdl "vendor:sdl3"
import "oket:gfx"
import "../pane"

// Each pane: a path row, then the list. The last window row is the CL.
list_rows :: proc(a: ^App) -> int {
    return a.grid.rows - 2
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

    n := len(a.panes)
    width := (a.grid.cols - (n - 1)) / n
    for &p, i in a.panes {
        x := i * (width + 1)
        draw_pane(a, &p, x, width, i == a.active)
        if i < n - 1 {
            for y in 0 ..< a.grid.rows - 1 {
                gfx.grid_put(&a.grid, x + width, y, gfx.Cell{'│', th[.Dim], gfx.opaque(th[.Bg]), {}, 0})
            }
        }
    }
    gfx.grid_write(&a.grid, 0, a.grid.rows - 1, ":", th[.Dim], gfx.opaque(th[.Bg]))

    gfx.gl_clear(w, h, th[.Bg])
    gfx.painter_draw(&a.painter, &a.grid, w, h, {0, 0}, gfx.Rect{0, 0, f32(w), f32(h)})
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
