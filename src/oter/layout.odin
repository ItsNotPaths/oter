package oter

import "core:math"
import "oket:gfx"
import "oket:strip"

GAP :: 4 // px between regions
TAU :: 0.09 // seconds a slide decays by 1/e
SIDEBAR_COLS :: 24
BEHIND :: 12 // the ground in the gaps: Bg darkened
RING_DARK :: 45 // a region's 1px rim, off the ground
BAR_BEHIND :: 45 // the CL bar: Bg darkened

Drawer :: enum {
    Closed,
    Open, // slides up from the CL bar, panes shrink above it
    Full, // term0 is on the alt screen (a TUI): everything above the CL bar
}

// A grid drawn at a pixel rect.
Region :: struct {
    rect: gfx.Rect,
    clip: gfx.Rect, // the part on screen; a pane scrolled off the strip is cut
    now:  strip.Span, // a pane's slot as drawn; slides to where it rests
    grid: gfx.Grid,
    pic:  gfx.Image_Quad, // drawn over the grid; no handle draws nothing
}

Frame :: struct {
    sidebar:  Region,
    panes:    [dynamic]Region, // by position, not by pane
    drawer:   Region,
    cl:       Region,
    drawer_h: f32, // on screen now; slides toward drawer_dest
    strip:    strip.Strip, // the panes' camera
    win:      [2]i32,
}

frame_destroy :: proc(f: ^Frame) {
    gfx.grid_destroy(&f.sidebar.grid)
    gfx.grid_destroy(&f.drawer.grid)
    gfx.grid_destroy(&f.cl.grid)
    for &r in f.panes {
        gfx.grid_destroy(&r.grid)
    }
    delete(f.panes)
}

// The drawer's resting height for its state, in px.
drawer_dest :: proc(a: ^App) -> f32 {
    return drawer_height(a, a.drawer)
}

drawer_height :: proc(a: ^App, d: Drawer) -> f32 {
    _, ch := gfx.painter_cell(&a.painter)
    above := f32(a.frame.win.y) - f32(ch) - GAP
    switch d {
    case .Closed:
        return 0
    case .Open:
        return max(math.floor(above / 3), f32(3 * ch))
    case .Full:
        return above
    }
    return 0
}

// One step of motion on the clock. True while something still moves.
frame_step :: proc(a: ^App, dt: f32) -> bool {
    dest := drawer_dest(a)
    a.frame.drawer_h = strip.approach(a.frame.drawer_h, dest, dt, TAU)
    moving := a.frame.drawer_h != dest
    slots := pane_slots(a)
    for &r, i in a.frame.panes[:min(len(slots), len(a.frame.panes))] {
        if r.now != slots[i] {
            r.now = strip.approach_span(r.now, slots[i], dt, TAU)
            moving = true
        }
    }
    s := &a.frame.strip
    s.aim = strip.look_at(s^, slots, a.active)
    s.camera = strip.approach(s.camera, s.aim, dt, TAU)
    return moving || s.camera != s.aim
}

// The frame's pane regions follow the panes, so a pane keeps its slide when the list changes.
frame_pane_insert :: proc(f: ^Frame, i: int) {
    if i <= len(f.panes) {
        inject_at(&f.panes, i, Region{})
    }
}

frame_pane_remove :: proc(f: ^Frame, i: int) {
    if i < len(f.panes) {
        gfx.grid_destroy(&f.panes[i].grid)
        ordered_remove(&f.panes, i)
    }
}

frame_pane_swap :: proc(f: ^Frame, i, j: int) {
    if max(i, j) < len(f.panes) {
        f.panes[i], f.panes[j] = f.panes[j], f.panes[i]
    }
}

// Every pane is half the strip wide, so two are on screen. Measured from the strip's left edge.
@(private = "file")
pane_slots :: proc(a: ^App) -> []strip.Span {
    w := max((a.frame.strip.view - GAP) / 2, 0)
    it := make([]strip.Span, len(a.panes), context.temp_allocator)
    for &sp, i in it {
        sp = {f32(i) * (w + GAP), w}
    }
    return it
}

// Every rect, from the window down. A window resize lands; it does not slide.
frame_fit :: proc(a: ^App, win_w, win_h: i32) {
    f := &a.frame
    if f.win != {win_w, win_h} {
        f.win = {win_w, win_h}
        f.drawer_h = drawer_dest(a)
    }
    cw, ch := gfx.painter_cell(&a.painter)
    W, H := f32(win_w), f32(win_h)

    f.cl.rect = {0, H - f32(ch), W, f32(ch)}
    above := H - f32(ch) - GAP
    dh := clamp(f.drawer_h, 0, above)
    f.drawer.rect = {0, above - dh, W, dh}

    body_h := max(above - dh - min(dh, GAP), 0) // the gap grows in with the drawer, no jump

    side_w := min(f32(SIDEBAR_COLS * cw), W / 3)
    f.sidebar.rect = {0, 0, side_w, body_h}

    along := side_w + GAP
    s := &f.strip
    land := s.view != W - along // a resize lands
    if land {
        s.view = W - along
        s.camera = strip.look_at(s^, pane_slots(a), a.active)
        s.aim = s.camera
    }
    view := gfx.Rect{along, 0, s.view, body_h}

    n := len(a.panes)
    for &r in f.panes[min(n, len(f.panes)):] {
        gfx.grid_destroy(&r.grid)
    }
    resize(&f.panes, n)
    dest := pane_slots(a)
    slots := make([]strip.Span, n, context.temp_allocator)
    for &r, i in f.panes {
        if land || r.now.w <= 0 {
            r.now = dest[i] // nothing slides in from nothing
        }
        slots[i] = r.now
    }
    for &r, i in f.panes {
        sp := strip.span(s^, slots, i)
        r.rect = {along + sp.x, 0, sp.w, body_h}
        region_fit(&r, cw, ch)
        x0, x1 := max(r.rect.x, view.x), min(r.rect.x + r.rect.w, view.x + view.w)
        r.clip = {x0, 0, max(x1 - x0, 0), body_h}
    }

    region_fit(&f.sidebar, cw, ch)
    region_fit(&f.drawer, cw, ch)
    region_fit(&f.cl, cw, ch)
}

// The grid CEILS the rect so its bg covers every pixel; text uses `region_cells`, which floors.
@(private = "file")
region_fit :: proc(r: ^Region, cw, ch: int) {
    gfx.grid_resize(&r.grid, int(math.ceil(r.rect.w / f32(cw))), int(math.ceil(r.rect.h / f32(ch))))
    r.clip = r.rect
}

// The whole cells a region's text may use.
region_cells :: proc(a: ^App, r: ^Region) -> (cols, rows: int) {
    cw, ch := gfx.painter_cell(&a.painter)
    return int(r.rect.w) / cw, int(r.rect.h) / ch
}

region_shown :: proc(r: ^Region) -> bool {
    return r.clip.w >= 1 && r.clip.h >= 1 && r.grid.cols > 0 && r.grid.rows > 0
}

region_paint :: proc(a: ^App, r: ^Region) {
    if !region_shown(r) {
        return
    }
    w, h := a.frame.win.x, a.frame.win.y
    gfx.painter_draw(&a.painter, &r.grid, w, h, {r.rect.x, r.rect.y}, r.clip)
}

// A 1px ring in the gap round `r`: two rims meet as the double line between regions.
region_rim :: proc(a: ^App, r: ^Region) {
    if !region_shown(r) {
        return
    }
    c := gfx.shade(gfx.theme_behind(a.theme, BEHIND), RING_DARK)
    x, y, w, h := r.clip.x - 1, r.clip.y - 1, r.clip.w + 2, r.clip.h + 2
    win_h := a.frame.win.y
    gfx.fill({x, y, w, 1}, c, win_h)
    gfx.fill({x, y, 1, h}, c, win_h)
    gfx.fill({x, y + h - 1, w, 1}, c, win_h)
    gfx.fill({x + w - 1, y, 1, h}, c, win_h)
}
