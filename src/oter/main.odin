package oter

import "core:fmt"
import "core:os"
import "core:time"
import sdl "vendor:sdl3"
import "oket:gfx"
import "../fsop"
import "../pane"

TITLE :: "oter"
APP_ID :: "oter"

App :: struct {
    window:  ^sdl.Window,
    painter: gfx.Painter,
    frame:   Frame,
    theme:   gfx.Theme,
    panes:   [dynamic]pane.Pane,
    active:  int,
    drawer:  Drawer,
    in_sidebar: bool, // Tab enters it and leaves it; `active` is the pane to return to
    sends:   [dynamic]Send,
    status:  string, // owned; the CL bar's text until the next one replaces it
    status_err: bool,
    running: bool,
}

// Wakes `WaitEvent` from any thread; the redraw that follows reads the new state.
push_wake :: proc() {
    ev: sdl.Event
    ev.type = .USER
    _ = sdl.PushEvent(&ev) // thread-safe
}

gl_loader :: proc(p: rawptr, name: cstring) {
    (^sdl.FunctionPointer)(p)^ = sdl.GL_GetProcAddress(name)
}

main :: proc() {
    sdl.SetHint(sdl.HINT_APP_ID, APP_ID)
    if !sdl.Init({.VIDEO}) {
        fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.Quit()

    sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, gfx.GL_MAJOR)
    sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, gfx.GL_MINOR)
    sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))

    window := sdl.CreateWindow(TITLE, 1200, 700, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
    if window == nil {
        fmt.eprintfln("SDL_CreateWindow failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.DestroyWindow(window)

    glctx := sdl.GL_CreateContext(window)
    if glctx == nil {
        fmt.eprintfln("SDL_GL_CreateContext failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.GL_DestroyContext(glctx)
    sdl.GL_SetSwapInterval(1)
    gfx.gl_init(gl_loader)

    sx := sdl.GetWindowDisplayScale(window)
    if sx <= 0 {
        sx = 1
    }
    faces, _ := gfx.face_stack_load(sx)
    atlas, atlas_ok := gfx.atlas_make(faces)
    if !atlas_ok {
        fmt.eprintln("the built-in fallback atlas failed to parse")
        os.exit(1)
    }

    fsop.wake_hook = push_wake

    a := App{window = window, theme = gfx.DEFAULT_THEME, running = true}
    if !gfx.painter_init(&a.painter, atlas) {
        os.exit(1)
    }
    defer gfx.painter_destroy(&a.painter)
    gfx.painter_set_scale(&a.painter, len(faces) > 0 ? 1 : sx)
    defer frame_destroy(&a.frame)
    defer delete(a.status)
    defer delete(a.sends) // a send still running at quit is left to the OS

    start := os.get_working_directory(context.allocator) or_else "/"
    defer delete(start)
    // (hole config :tags config :sev gap) pane count and theme are fixed; no config.conf.
    for _ in 0 ..< 2 {
        p: pane.Pane
        pane.open(&p, start)
        append(&a.panes, p)
    }
    defer {
        for &p in a.panes {
            pane.destroy(&p)
        }
        delete(a.panes)
    }

    term0_start(&a)

    // Redraw only when something happened, or while something slides.
    last := time.tick_now()
    for a.running {
        jobs_poll(&a)
        moving := frame_step(&a, f32(time.duration_seconds(time.tick_lap_time(&last))))
        draw(&a)
        sdl.GL_SwapWindow(a.window)
        free_all(context.temp_allocator)

        ev: sdl.Event
        if moving {
            if !sdl.WaitEventTimeout(&ev, 8) {
                continue
            }
        } else {
            if !sdl.WaitEvent(&ev) {
                continue
            }
            last = time.tick_now() // the wait is not motion time
        }
        handle(&a, ev)
        for sdl.PollEvent(&ev) {
            handle(&a, ev)
        }
    }
}
