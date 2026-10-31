package oter

import "core:fmt"
import "core:os"
import "core:time"
import sdl "vendor:sdl3"
import "oket:cl"
import "oket:gfx"
import "oket:input"
import "oket:pty"
import "../fsop"
import "../pane"

TITLE :: "oter"
APP_ID :: "oter"
PICK_APP_ID :: "oter-pick" // so a WM rule can float the file dialog

// Who gets the keys. Panes is the hub: the sidebar and the line open only from it, and
// Line > Term is one offshoot. Term covers the tray and a TUI's full drawer.
Mode :: enum {
    Panes,
    Sidebar,
    Line,
    Term,
}

App :: struct {
    window:  ^sdl.Window,
    painter: gfx.Painter,
    font_px:     int, // baked now
    font_system: int, // what the display asked for; :font.reset goes back to it
    frame:   Frame,
    theme:   gfx.Theme,
    home:    Home,
    config:  Config,
    panes:   [dynamic]pane.Pane,
    places:  [dynamic]Place,
    place:   int, // the sidebar cursor
    places_file: string, // owned; "" saves nowhere
    active:  int,
    drawer:  Drawer,
    mode:    Mode,
    sends:   [dynamic]Send,
    listings: [dynamic]^Listing, // archives being listed
    archives: [dynamic]Cached, // listed ones, oldest first
    passwords: map[string]string, // archive file -> its password; memory only
    ask:     Maybe(Ask), // the password question the tray is showing
    filter:  ^Filter, // the piped step the chain waits on
    line:    Cl,
    chain:   cl.Chain,
    binds:   [dynamic]input.Bind,
    term0:   pty.Terminal,
    step_id: u64, // the term0 step the chain waits on
    drawer_before: Drawer, // what a TUI's full drawer goes back to
    status:  string, // owned; the CL bar's text until the next one replaces it
    status_err: bool,
    key:     struct {
        code:   input.Code, // the key whose bind is running; 0 outside one
        repeat: bool,
    },
    paint:     Maybe(bool), // while the key that ran `:mark` is held, up/down set this mark
    paint_key: input.Code,
    pick_out: string, // the file dialog's answer file; "" when not one
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
    if handled, ok := install_cli(os.args[1:]); handled {
        os.exit(ok ? 0 : 1)
    }
    pk, picking, pick_ok := pick_args(os.args[1:])
    if picking && !pick_ok {
        fmt.eprintln(USAGE_PICK)
        os.exit(2)
    }
    sdl.SetHint(sdl.HINT_APP_ID, picking ? PICK_APP_ID : APP_ID)
    if !sdl.Init({.VIDEO}) {
        fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
        os.exit(1)
    }
    defer sdl.Quit()

    sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, gfx.GL_MAJOR)
    sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, gfx.GL_MINOR)
    sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(transmute(u32)sdl.GL_CONTEXT_PROFILE_CORE))

    w, h: i32 = picking ? 900 : 1200, picking ? 560 : 700
    window := sdl.CreateWindow(TITLE, w, h, {.OPENGL, .RESIZABLE, .HIGH_PIXEL_DENSITY})
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
    faces, font_px := gfx.face_stack_load(sx)
    atlas, atlas_ok := gfx.atlas_make(faces)
    if !atlas_ok {
        fmt.eprintln("the built-in fallback atlas failed to parse")
        os.exit(1)
    }

    fsop.wake_hook = push_wake

    a := App{window = window, home = home_resolve(), running = true}
    if !gfx.painter_init(&a.painter, atlas) {
        os.exit(1)
    }
    defer gfx.painter_destroy(&a.painter)
    font_init(&a, font_px)
    gfx.painter_set_scale(&a.painter, len(faces) > 0 ? 1 : sx)
    defer frame_destroy(&a.frame)
    defer delete(a.status)
    defer delete(a.line.text)
    defer cl.destroy(&a.chain)
    defer input.binds_destroy(&a.binds)
    defer home_destroy(&a.home)
    defer config_destroy(&a.config)
    binds_load(&a)
    config_load(&a)
    places_load(&a)
    defer {
        places_clear(&a.places)
        delete(a.places)
        delete(a.places_file)
    }
    defer delete(a.sends) // a send still running at quit is left to the OS
    defer archives_destroy(&a)

    start := os.get_working_directory(context.allocator) or_else "/"
    defer delete(start)
    if picking {
        pick_open(&a, pk, start)
    } else {
        for _ in 0 ..< a.config.panes {
            p: pane.Pane
            pane.open(&p, start)
            append(&a.panes, p)
        }
    }
    defer {
        for &p in a.panes {
            pane.destroy(&p)
        }
        delete(a.panes)
    }

    term0_start(&a)
    defer pty.terminal_close(&a.term0)

    // Redraw only when something happened, or while something slides.
    last := time.tick_now()
    for a.running {
        jobs_poll(&a)
        term0_pump(&a)
        moving := frame_step(&a, f32(time.duration_seconds(time.tick_lap_time(&last))))
        draw(&a)
        sdl.GL_SwapWindow(a.window)
        free_all(context.temp_allocator)

        ev: sdl.Event
        if !moving { // while something slides the swap paces the frames, as in oket
            if !sdl.WaitEvent(&ev) {
                continue
            }
            last = time.tick_now() // the wait is not motion time
            handle(&a, ev)
        }
        for sdl.PollEvent(&ev) {
            handle(&a, ev)
        }
    }
}
