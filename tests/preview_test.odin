package tests

import "core:c"
import "core:testing"
import "oter:oter"

@(test)
a_picture_spans_the_pane_width :: proc(t: ^testing.T) {
    // 800px wide pane, 2:1 picture, 20px cells: 400px tall is 20 rows.
    testing.expect_value(t, oter.picture_rows(100, 800, 1000, 500, 20), 20)
    testing.expect_value(t, oter.picture_rows(100, 800, 1000, 510, 20), 21) // a part row rounds up
}

@(test)
a_picture_takes_at_most_half_the_list :: proc(t: ^testing.T) {
    testing.expect_value(t, oter.picture_rows(30, 800, 500, 5000, 20), 15)
}

@(test)
each_gif_frame_waits_its_own_delay :: proc(t: ^testing.T) {
    delays := []c.int{100, 300}
    frame, next := oter.frame_at(delays, 0)
    testing.expect_value(t, frame, 0)
    testing.expect_value(t, next, 100)
    frame, next = oter.frame_at(delays, 150)
    testing.expect_value(t, frame, 1)
    testing.expect_value(t, next, 250)
    frame, _ = oter.frame_at(delays, 420) // loops
    testing.expect_value(t, frame, 0)
}

@(test)
a_gif_frame_with_no_delay_still_shows :: proc(t: ^testing.T) {
    frame, next := oter.frame_at([]c.int{0, 0}, 50)
    testing.expect_value(t, frame, 0)
    testing.expect(t, next > 0)
}

@(test)
a_still_never_wakes_the_loop :: proc(t: ^testing.T) {
    _, next := oter.frame_at(nil, 5000)
    testing.expect_value(t, next, -1)
}
