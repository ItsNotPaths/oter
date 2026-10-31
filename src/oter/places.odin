package oter

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "oket:cl"

DEFAULT_PLACES :: "~\n~/Downloads\n"

// Line N of the places file is slot N. A blank line is an empty slot; a separator is just a
// line that is not a dir.
Place :: struct {
    text: string, // as written in the file
    path: string, // `~` expanded
    ok:   bool, // an existing dir
}

// ~/.config/oter/places. A missing file is written from the defaults.
places_load :: proc(a: ^App) {
    a.places_file = strings.clone(config_path("places"))
    text := DEFAULT_PLACES
    if data, err := os.read_entire_file(a.places_file, context.temp_allocator); err == nil {
        text = string(data)
    } else {
        os.make_directory_all(filepath.dir(a.places_file))
        _ = os.write_entire_file(a.places_file, DEFAULT_PLACES)
    }
    places_parse(&a.places, text)
}

places_parse :: proc(places: ^[dynamic]Place, text: string) {
    places_clear(places)
    for raw in strings.split_lines(strings.trim_right_space(text), context.temp_allocator) {
        append(places, place_make(strings.trim_space(raw)))
    }
    if len(places) == 1 && places[0].text == "" {
        places_clear(places) // an empty file
    }
}

places_clear :: proc(places: ^[dynamic]Place) {
    for pl in places {
        delete(pl.text)
        delete(pl.path)
    }
    clear(places)
}

// The place under the sidebar cursor, if it is a dir.
place_current :: proc(a: ^App) -> (string, bool) {
    if a.place < len(a.places) && a.places[a.place].ok {
        return a.places[a.place].path, true
    }
    return "", false
}

// Every slot the sidebar shows, filled or not.
place_slots :: proc(a: ^App) -> int {
    return max(len(a.places), a.frame.sidebar.grid.rows - 1, 1) // row 0 is the header
}

// `:place cur ±N`, `move ±N`, `set [N] <text>`, `clear [N]`. N is the slot, from 1; none is the cursor's.
builtin_place :: proc(a: ^App, args: string) -> bool {
    sub := cl.first_field(args)
    rest := strings.trim_space(args[len(sub):])
    n, has_n := strconv.parse_int(cl.first_field(rest))
    if has_n {
        rest = strings.trim_space(rest[len(cl.first_field(rest)):])
    }
    at := has_n ? n - 1 : a.place
    switch sub {
    case "cur":
        a.place = clamp(a.place + n, 0, place_slots(a) - 1)
        return true
    case "move":
        to := a.place + n
        if to < 0 || to >= place_slots(a) {
            return false
        }
        place_grow(a, max(a.place, to))
        a.places[a.place], a.places[to] = a.places[to], a.places[a.place]
        a.place = to
    case "set", "clear":
        if at < 0 || at >= place_slots(a) {
            status_set(a, fmt.tprintf(":place: no slot %d", at + 1), true)
            return false
        }
        if sub == "set" && rest == "" {
            status_set(a, ":place set [N] <text>", true)
            return false
        }
        if rest != "" && (rest[0] == '\'' || rest[0] == '"') {
            _, rest = cl.first_arg(rest) // a $o_ path, quoted by the fill
        }
        place_grow(a, at)
        delete(a.places[at].text)
        delete(a.places[at].path)
        a.places[at] = place_make(sub == "set" ? home_shorten(rest) : "")
    case:
        status_set(a, ":place takes cur, move, set or clear", true)
        return false
    }
    places_save(a)
    return true
}

// Empty slots up to and with `at`.
@(private = "file")
place_grow :: proc(a: ^App, at: int) {
    for len(a.places) <= at {
        append(&a.places, place_make(""))
    }
}

// Trailing empty slots are dropped; the ones between keep the numbers.
@(private = "file")
places_save :: proc(a: ^App) {
    if a.places_file == "" {
        return
    }
    b := strings.builder_make(context.temp_allocator)
    for pl in a.places {
        strings.write_string(&b, pl.text)
        strings.write_byte(&b, '\n')
    }
    text := strings.trim_right_space(strings.to_string(b))
    if text != "" {
        text = strings.concatenate({text, "\n"}, context.temp_allocator)
    }
    if os.write_entire_file(a.places_file, text) != nil {
        status_set(a, fmt.tprintf("could not write %s", a.places_file), true)
    }
}

@(private = "file")
place_make :: proc(text: string) -> Place {
    path := strings.clone(text)
    if text == "~" || strings.has_prefix(text, "~/") {
        delete(path)
        path = strings.concatenate({os.get_env("HOME", context.temp_allocator), text[1:]})
    }
    return Place{strings.clone(text), path, os.is_dir(path)}
}

@(private = "file")
home_shorten :: proc(path: string) -> string {
    home := os.get_env("HOME", context.temp_allocator)
    if home != "" && (path == home || strings.has_prefix(path, strings.concatenate({home, "/"}, context.temp_allocator))) {
        return strings.concatenate({"~", path[len(home):]}, context.temp_allocator)
    }
    return path
}
