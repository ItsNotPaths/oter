package oter

import "core:fmt"
import "oket:gfx"

// oket's zoom: the atlas rebakes and the frame re-fits from the window, so the layout follows.

// The size baked now, and the one the display asked for at start.
font_init :: proc(a: ^App, px: int) {
    a.font_px, a.font_system = px, px
}

// A size out of range, the one already baked, or the fallback bitmap leaves the screen as it was.
@(private = "file")
font_apply :: proc(a: ^App, px: int) -> bool {
    if px == a.font_px || !gfx.face_px_ok(px) {
        return false
    }
    gfx.atlas_resize(&a.painter.atlas, px) or_return
    a.font_px = px
    return true
}

@(private = "file")
NO_FACE :: "the built-in bitmap has one size; there is no system font to resize"

font_zoom :: proc(a: ^App, dir: int) -> bool {
    if gfx.atlas_is_fallback(&a.painter.atlas) {
        return fail(a, NO_FACE)
    }
    px := gfx.face_next_px(&a.painter.atlas.faces[0], a.font_px, dir)
    if !font_apply(a, px) {
        return fail(a, fmt.tprintf("%d px is as %s as the font goes", a.font_px, dir > 0 ? "big" : "small"))
    }
    return true
}

font_reset :: proc(a: ^App) -> bool {
    if font_apply(a, a.font_system) {
        return true
    }
    if gfx.atlas_is_fallback(&a.painter.atlas) {
        return fail(a, NO_FACE)
    }
    return fail(a, fmt.tprintf("already at %d px", a.font_px))
}
