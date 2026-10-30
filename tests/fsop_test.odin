package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import "oter:fsop"

@(private = "file")
join :: proc(parts: ..string) -> string {
    p, _ := filepath.join(parts, context.temp_allocator)
    return p
}

@(private = "file")
read :: proc(path: string) -> string {
    data, _ := os.read_entire_file(path, context.temp_allocator)
    return string(data)
}

// src/{a.txt, tree/{x.sh (0755), link -> x.sh}}, dst/
@(private = "file")
make_dirs :: proc(t: ^testing.T) -> (root, src, dst: string) {
    err: os.Error
    root, err = os.make_directory_temp("", "oter-fsop-*", context.allocator)
    testing.expect(t, err == nil)
    src, dst = join(root, "src"), join(root, "dst")
    testing.expect(t, os.make_directory_all(join(src, "tree")) == nil)
    testing.expect(t, os.make_directory(dst) == nil)
    testing.expect(t, os.write_entire_file(join(src, "a.txt"), "hello") == nil)
    testing.expect(t, os.write_entire_file(join(src, "tree", "x.sh"), "#!") == nil)
    testing.expect(t, os.chmod(join(src, "tree", "x.sh"), {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) == nil)
    testing.expect(t, os.symlink("x.sh", join(src, "tree", "link")) == nil)
    return
}

@(private = "file")
run :: proc(srcs: []string, dst: string, move: bool) -> ^fsop.Job {
    j := fsop.new_job(srcs, dst, move)
    fsop.send(j)
    return j
}

@(test)
copy_keeps_tree_links_and_mode :: proc(t: ^testing.T) {
    root, src, dst := make_dirs(t)
    defer {os.remove_all(root); delete(root)}

    j := run({join(src, "a.txt"), join(src, "tree")}, dst, false)
    defer fsop.destroy(j)

    testing.expect_value(t, j.done, 2)
    testing.expect_value(t, j.err, "")
    testing.expect_value(t, read(join(dst, "a.txt")), "hello")
    testing.expect(t, os.exists(join(src, "a.txt")))

    target, _ := os.read_link(join(dst, "tree", "link"), context.temp_allocator)
    testing.expect_value(t, target, "x.sh")
    fi, _ := os.stat(join(dst, "tree", "x.sh"), context.temp_allocator)
    testing.expect(t, .Execute_User in fi.mode)
    testing.expect(t, .Execute_Other in fi.mode)
}

@(test)
clash_skips_and_never_overwrites :: proc(t: ^testing.T) {
    root, src, dst := make_dirs(t)
    defer {os.remove_all(root); delete(root)}
    testing.expect(t, os.write_entire_file(join(dst, "a.txt"), "mine") == nil)
    testing.expect(t, os.make_directory(join(dst, "tree")) == nil)

    j := run({join(src, "a.txt"), join(src, "tree")}, dst, true)
    defer fsop.destroy(j)

    testing.expect_value(t, j.skipped, 2)
    testing.expect_value(t, j.done, 0)
    testing.expect_value(t, read(join(dst, "a.txt")), "mine")
    testing.expect(t, !os.exists(join(dst, "tree", "x.sh")))
    testing.expect(t, os.exists(join(src, "a.txt")))
}

@(test)
move_removes_source :: proc(t: ^testing.T) {
    root, src, dst := make_dirs(t)
    defer {os.remove_all(root); delete(root)}

    j := run({join(src, "tree")}, dst, true)
    defer fsop.destroy(j)

    testing.expect_value(t, j.done, 1)
    testing.expect(t, !os.exists(join(src, "tree")))
    testing.expect_value(t, read(join(dst, "tree", "x.sh")), "#!")
}

@(test)
failure_stops_with_error :: proc(t: ^testing.T) {
    root, src, dst := make_dirs(t)
    defer {os.remove_all(root); delete(root)}

    j := run({join(src, "missing"), join(src, "a.txt")}, dst, false)
    defer fsop.destroy(j)

    testing.expect(t, j.err != "")
    testing.expect_value(t, j.done, 0)
    testing.expect(t, !os.exists(join(dst, "a.txt")))
}

@(test)
copy_into_itself_fails :: proc(t: ^testing.T) {
    root, src, _ := make_dirs(t)
    defer {os.remove_all(root); delete(root)}

    j := run({join(src, "tree")}, join(src, "tree"), false)
    defer fsop.destroy(j)

    testing.expect(t, j.err != "")
}

@(test)
start_finishes_on_worker :: proc(t: ^testing.T) {
    root, src, dst := make_dirs(t)
    defer {os.remove_all(root); delete(root)}

    j := fsop.start({join(src, "a.txt")}, dst, false)
    defer fsop.destroy(j)
    deadline := time.tick_now()
    for !fsop.is_finished(j) && time.tick_since(deadline) < 5 * time.Second {
        time.sleep(time.Millisecond)
    }
    testing.expect(t, fsop.is_finished(j))
    testing.expect_value(t, j.done, 1)
    testing.expect(t, j.items[0].done)
}

@(test)
picks_first_installed_line :: proc(t: ^testing.T) {
    line, ok := fsop.pick({"oter-no-such-tool $o_src", "sh -c true", "cp $o_src $o_dst"})
    testing.expect(t, ok)
    testing.expect_value(t, line, "sh -c true")

    _, none := fsop.pick({"oter-no-such-tool"})
    testing.expect(t, !none)
}

@(test)
or_in_a_line_is_plain_sh :: proc(t: ^testing.T) {
    root, _, dst := make_dirs(t)
    defer {os.remove_all(root); delete(root)}
    out := join(dst, "out")

    _, ok := fsop.run_line("ls /oter-no-such-path 2>/dev/null || touch $o_dst", {"", dst, out})
    testing.expect(t, ok)
    testing.expect(t, os.exists(out))
}
