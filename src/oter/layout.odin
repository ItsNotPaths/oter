package oter

// Grid cells.
Rect :: struct {
    x, y, w, h: int,
}

// (hole drawer-auto :tags (ui term) :sev gap :needs term0) drawer does not open on a failed or waiting step, nor go full while term0 is on the alt screen.
Drawer :: enum {
    Closed,
    Open, // slides up from the CL row, panes shrink above it
    Full, // term0 is on the alt screen (a TUI): everything above the CL row
}

SIDEBAR_COLS :: 24

Layout :: struct {
    sidebar: Rect,
    panes:   Rect,
    drawer:  Rect, // h == 0 when closed
    cl:      Rect, // the last row
}

layout :: proc(a: ^App) -> (l: Layout) {
    cols, rows := a.grid.cols, a.grid.rows
    l.cl = {0, rows - 1, cols, 1}
    above := rows - 1

    drawer_h: int
    switch a.drawer {
    case .Closed:
    case .Open:
        drawer_h = max(above / 3, 3)
    case .Full:
        drawer_h = above
    }
    drawer_h = min(drawer_h, above)
    l.drawer = {0, above - drawer_h, cols, drawer_h}

    side_w := min(SIDEBAR_COLS, cols / 3)
    l.sidebar = {0, 0, side_w, above - drawer_h}
    l.panes = {side_w, 0, cols - side_w, above - drawer_h}
    return
}
