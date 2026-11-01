package oter

import "base:runtime"
import "core:c"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import stbi "vendor:stb/image"
import "oket:gfx"
import "../pane"

@(private = "file")
PICTURE_EXTS :: [?]string{".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tga", ".psd", ".hdr", ".pic", ".pnm", ".ppm", ".pgm"}

@(private = "file")
GIF_DEFAULT_MS :: 100 // a frame with no delay, as browsers play it

// Decoded on a thread; the main thread uploads it once `finished`.
Picture :: struct {
    path:     string, // owned
    pixels:   [^]u8, // stb's, frames back to back; nil once uploaded or if it would not decode
    delays:   [^]c.int, // stb's, ms per frame; nil for a still
    w, h:     i32,
    frames:   i32,
    finished: bool, // atomic; the fields above are final once set
    gpu:      [dynamic]gfx.Image, // one per frame
    born:     time.Tick,
}

// Each frame: land decoded pictures, drop the ones the focused pane is not on, start the missing one.
preview_poll :: proc(a: ^App) {
    #reverse for pic, k in a.pictures {
        if !sync.atomic_load(&pic.finished) {
            continue
        }
        if want, ok := picture_want(a); !ok || want != pic.path {
            picture_free(pic)
            ordered_remove(&a.pictures, k)
        } else if pic.pixels != nil {
            picture_upload(pic)
        }
    }
    if path, ok := picture_want(a); ok && picture_find(a, path) == nil {
        picture_start(a, path)
    }
}

// At quit. One still decoding is left to the OS.
preview_destroy :: proc(a: ^App) {
    for pic in a.pictures {
        if sync.atomic_load(&pic.finished) {
            picture_free(pic)
        }
    }
    delete(a.pictures)
}

// The landed picture under the pane's cursor, if it has focus.
picture_shown :: proc(a: ^App, p: ^pane.Pane) -> ^Picture {
    path, ok := picture_want(a)
    if !ok || p != &a.panes[a.active] {
        return nil
    }
    pic := picture_find(a, path)
    if pic == nil || len(pic.gpu) == 0 {
        return nil
    }
    return pic
}

// Rows for a picture opened in a list of `list` rows: full pane width, at most half the list.
picture_rows :: proc(list: int, pane_w: f32, img_w, img_h: i32, cell_h: int) -> int {
    want := int(math.ceil(pane_w * f32(img_h) / f32(img_w) / f32(cell_h)))
    return min(want, list / 2)
}

// The picture's current frame, scaled to fit `box` and centred in it.
picture_quad :: proc(pic: ^Picture, box: gfx.Rect) -> gfx.Image_Quad {
    img, _ := picture_frame(pic)
    s := min(box.w / f32(pic.w), box.h / f32(pic.h))
    w, h := f32(pic.w) * s, f32(pic.h) * s
    return {img = img, dst = {box.x + (box.w - w) / 2, box.y + (box.h - h) / 2, w, h}}
}

// The frame to show `ms` into the loop, and ms until the next one; -1 for a still.
frame_at :: proc(delays: []c.int, ms: int) -> (frame, next_ms: int) {
    if len(delays) <= 1 {
        return 0, -1
    }
    total := 0
    for d in delays {
        total += frame_ms(d)
    }
    t := ms % total
    for d, i in delays {
        if t < frame_ms(d) {
            return i, frame_ms(d) - t
        }
        t -= frame_ms(d)
    }
    return 0, -1
}

// The image to draw now and ms until it changes; -1 for a still.
picture_frame :: proc(pic: ^Picture) -> (gfx.Image, int) {
    ms := int(time.duration_milliseconds(time.tick_since(pic.born)))
    delays := pic.delays != nil ? pic.delays[:len(pic.gpu)] : nil
    i, next := frame_at(delays, ms)
    return pic.gpu[i], next
}

// How long the loop may sleep before a GIF needs its next frame; -1 for forever.
preview_wait_ms :: proc(a: ^App) -> int {
    wait := -1
    for pic in a.pictures {
        if len(pic.gpu) < 2 {
            continue
        }
        _, next := picture_frame(pic)
        wait = wait < 0 ? next : min(wait, next)
    }
    return wait
}

@(private = "file")
frame_ms :: proc(d: c.int) -> int {
    return d > 0 ? int(d) : GIF_DEFAULT_MS
}

@(private = "file")
picture_path :: proc(p: ^pane.Pane) -> (path: string, ok: bool) {
    e := pane.current(p) or_return
    // (hole preview-archive :tags preview :sev gap) no picture for a file inside an archive.
    if e.is_dir || !pane.is_real(p) {
        return
    }
    ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
    for x in PICTURE_EXTS {
        if x == ext {
            return pane.path_of(p, e.name), true
        }
    }
    return
}

// The picture under the focused pane's cursor, while previews are on.
@(private = "file")
picture_want :: proc(a: ^App) -> (path: string, ok: bool) {
    if !a.preview || a.active >= len(a.panes) {
        return
    }
    return picture_path(&a.panes[a.active])
}

@(private = "file")
picture_find :: proc(a: ^App, path: string) -> ^Picture {
    for pic in a.pictures {
        if pic.path == path {
            return pic
        }
    }
    return nil
}

@(private = "file")
picture_start :: proc(a: ^App, path: string) {
    pic := new(Picture)
    pic.path = strings.clone(path)
    append(&a.pictures, pic)
    ctx := runtime.default_context() // own temp allocator, as archive listing does
    ctx.allocator = context.allocator
    thread.create_and_start_with_poly_data(pic, picture_work, ctx, self_cleanup = true)
}

@(private = "file")
picture_work :: proc(pic: ^Picture) {
    defer push_wake() // after `finished`: defers run last first
    defer sync.atomic_store(&pic.finished, true)
    data, err := os.read_entire_file(pic.path, context.allocator)
    if err != nil {
        return
    }
    defer delete(data)
    x, y, comp: c.int
    frames: c.int = 1
    if strings.has_prefix(string(data), "GIF") {
        pic.pixels = stbi.load_gif_from_memory(raw_data(data), c.int(len(data)), &pic.delays, &x, &y, &frames, &comp, 4)
    } else {
        pic.pixels = stbi.load_from_memory(raw_data(data), c.int(len(data)), &x, &y, &comp, 4)
    }
    pic.w, pic.h, pic.frames = i32(x), i32(y), i32(frames)
}

// GL thread only.
@(private = "file")
picture_upload :: proc(pic: ^Picture) {
    size := int(pic.w) * int(pic.h) * 4
    for i in 0 ..< int(pic.frames) {
        img := gfx.image_upload(pic.pixels[i * size:], pic.w, pic.h) or_break
        append(&pic.gpu, img)
    }
    stbi.image_free(pic.pixels)
    pic.pixels = nil
    pic.born = time.tick_now()
}

@(private = "file")
picture_free :: proc(pic: ^Picture) {
    for &img in pic.gpu {
        gfx.image_free(&img)
    }
    delete(pic.gpu)
    if pic.pixels != nil {
        stbi.image_free(pic.pixels)
    }
    if pic.delays != nil {
        stbi.image_free(pic.delays)
    }
    delete(pic.path)
    free(pic)
}
