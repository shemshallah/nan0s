; mouse.nas -- PS/2 AUX port + native NaN16 window hit-testing.
; The physical/v86 PS/2 controller is accessed exclusively via raw
; NaN16 INB/OUTB. Browser JS never decides window focus, drag, or resize.
; 0x64 status bit5 identifies AUX bytes, bit0 data, bit1 input busy.
; Packet 1 bit3=1, bits0..2 buttons; bytes2/3 signed X/Y displacement.
; All state is guest memory; g_loop invokes ms_poll, sh_draw then ms_draw.
ms_x:
.word 512
ms_y:
.word 384
ms_buttons:
.word 0
ms_prev:
.word 0
ms_state:
.word 0
ms_dx:
.word 0
ms_dy:
.word 0
ms_p1:
.word 0
ms_p2:
.word 0
ms_p3:
.word 0
ms_drag:
.word 0
ms_id:
.word 0
ms_index:
.word 0
ms_b:
.word 0
ms_tmp:
.word 0
ms_edge:
.word 0
ms_frame:
.word 0
ms_tick:
.word 0
ms_budget:
.word 0
ms_last_title_tick:
.word 0
ms_last_title_id:
.word 0xFFFF

; Input busy (8042 status bit1) must clear before EACH command/data write.
; Never wait unbounded on a broken physical controller or v86 reset.
ms_write_ready:
MOVI r8,4096
ms_write_wait:
MOVI r1,0x64
INB r2,r1
MOVI r3,2
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @ms_write_ok
SUB r8,r8,r13
CMP r8,r0
JMP[NE] @ms_write_wait
MOVI r1,0
RET
ms_write_ok:
MOVI r1,1
RET

; r1=controller command: waits then writes to port 0x64.
ms_command:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,@ms_tmp
CALL @ms_write_ready
CMP r1,r0
JMP[EQ] @ms_command_end
MOVI r1,0x64
LD r2,r0,@ms_tmp
OUTB r2,r1
ms_command_end:
SUB r14,r14,r13
LD r15,r14,0
RET

; r1=data byte for 0x60 after a prior D4 AUX forwarding command.
ms_data:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,@ms_tmp
CALL @ms_write_ready
CMP r1,r0
JMP[EQ] @ms_data_end
MOVI r1,0x60
LD r2,r0,@ms_tmp
OUTB r2,r1
ms_data_end:
SUB r14,r14,r13
LD r15,r14,0
RET

ms_init:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,@ms_state
ST r0,r0,@ms_buttons
ST r0,r0,@ms_prev
ST r0,r0,@ms_drag
ST r0,r0,@ms_cursor_saved
ST r0,r0,@ms_last_title_tick
MOVI r1,0xFFFF
ST r1,r0,@ms_last_title_id
MOVI r1,512
ST r1,r0,@ms_x
MOVI r1,384
ST r1,r0,@ms_y
; Make and ACK only affect AUX. Keyboard bytes remain in keyboard queue.
MOVI r1,0xA8
CALL @ms_command
MOVI r1,0xD4
CALL @ms_command
MOVI r1,0xF6
CALL @ms_data
MOVI r1,0xD4
CALL @ms_command
MOVI r1,0xF4
CALL @ms_data
SUB r14,r14,r13
LD r15,r14,0
RET

; Non-blocking; budget 24 bytes so a noisy mouse cannot starve guest
; keyboard/UI. Only consume AUX data, never keyboard bytes.
ms_poll:
ST r15,r14,0
ADD r14,r14,r13
MOVI r10,24
ms_poll_next:
CMP r10,r0
JMP[EQ] @ms_poll_done
SUB r10,r10,r13
ST r10,r0,@ms_budget
MOVI r1,0x64
INB r2,r1
MOVI r3,1
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @ms_poll_done
MOVI r3,0x20
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @ms_poll_done
MOVI r1,0x60
INB r2,r1
; 0xFA mouse ACK and 0xAA BAT are not packet headers.
LD r3,r0,@ms_state
CMP r3,r0
JMP[NE] @ms_packet_byte
MOVI r3,0xFA
CMP r2,r3
JMP[EQ] @ms_poll_next
MOVI r3,0xAA
CMP r2,r3
JMP[EQ] @ms_poll_next
MOVI r3,8
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @ms_poll_next
ST r2,r0,@ms_p1
MOVI r3,1
ST r3,r0,@ms_state
JMP @ms_poll_next
ms_packet_byte:
MOVI r4,1
CMP r3,r4
JMP[NE] @ms_packet_end
ST r2,r0,@ms_p2
MOVI r3,2
ST r3,r0,@ms_state
JMP @ms_poll_next
ms_packet_end:
ST r2,r0,@ms_p3
ST r0,r0,@ms_state
CALL @ms_update
LD r10,r0,@ms_budget
JMP @ms_poll_next
ms_poll_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; Decode signed 8-bit packet deltas, clamp cursor and send native events.
ms_update:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,@ms_p1
; PS/2 overflow flags indicate a non-representable movement delta.
; Ignore it rather than teleporting the guest pointer or dragging windows.
MOVI r2,0xC0
BOOL.8 r3,r1,r2
CMP r3,r0
JMP[NE] @ms_update_done
MOVI r2,7
BOOL.8 r3,r1,r2
LD r4,r0,@ms_buttons
ST r4,r0,@ms_prev
ST r3,r0,@ms_buttons
LD r2,r0,@ms_p2
MOVI r3,16
BOOL.8 r4,r1,r3
CMP r4,r0
JMP[EQ] @ms_xpos
MOVI r3,256
SUB r2,r2,r3
ms_xpos:
ST r2,r0,@ms_dx
LD r2,r0,@ms_p3
MOVI r3,32
BOOL.8 r4,r1,r3
CMP r4,r0
JMP[EQ] @ms_ypos
MOVI r3,256
SUB r2,r2,r3
ms_ypos:
ST r2,r0,@ms_dy
JMP @ms_apply
; Absolute touchscreen packet: r1=x, r2=y, r3=button mask.
; Convert to the identical native PS/2 pointer/hit-test path. The transport
; does not know about windows, z-order, close buttons or application state.
ms_touch:
ST r15,r14,0
ADD r14,r14,r13
LD r4,r0,@ms_buttons
ST r4,r0,@ms_prev
ST r3,r0,@ms_buttons
LD r4,r0,@ms_x
SUB r1,r1,r4
ST r1,r0,@ms_dx
LD r4,r0,@ms_y
SUB r2,r4,r2
ST r2,r0,@ms_dy
ms_apply:
; Nothing changed: do not touch the framebuffer or dispatch a second click.
LD r3,r0,@ms_dx
BOOL.14 r3,r3,r2
LD r4,r0,@ms_buttons
LD r5,r0,@ms_prev
BOOL.6 r4,r4,r5
BOOL.14 r3,r3,r4
CMP r3,r0
JMP[EQ] @ms_update_done
LD r3,r0,@ms_dx
LD r2,r0,@ms_dy
BOOL.14 r3,r3,r2
CMP r3,r0
JMP[EQ] @ms_position
CALL @ms_erase
ms_position:
LD r1,r0,@ms_x
LD r2,r0,@ms_dx
ADD r1,r1,r2
SHR r4,r1,31
CMP r4,r0
JMP[EQ] @ms_clamp_x
MOVI r1,0
ms_clamp_x:
LD r3,r0,@fb_w
SUB r3,r3,r13
CMP r1,r3
JMP[LE] @ms_xstore
ADD r1,r3,r0
ms_xstore:
ST r1,r0,@ms_x
LD r1,r0,@ms_y
LD r2,r0,@ms_dy
SUB r1,r1,r2
SHR r4,r1,31
CMP r4,r0
JMP[EQ] @ms_clamp_y
MOVI r1,0
ms_clamp_y:
LD r3,r0,@fb_h
SUB r3,r3,r13
CMP r1,r3
JMP[LE] @ms_ystore
ADD r1,r3,r0
ms_ystore:
ST r1,r0,@ms_y
; Right mouse press picks the next overlapping window at the same pointer
; coordinates. This works even when the underneath window is fully hidden.
; Left click retains ordinary frontmost-window hit testing.
LD r1,r0,@ms_buttons
MOVI r2,2
BOOL.8 r3,r1,r2
LD r1,r0,@ms_prev
BOOL.8 r4,r1,r2
CMP r3,r0
JMP[EQ] @ms_not_right
CMP r4,r0
JMP[NE] @ms_not_right
CALL @ms_cycle_under_pointer
ms_not_right:
; Left button make transitions start click/hit-test; release stops drag.
LD r1,r0,@ms_buttons
MOVI r2,1
BOOL.8 r3,r1,r2
LD r1,r0,@ms_prev
BOOL.8 r4,r1,r2
CMP r3,r0
JMP[EQ] @ms_release
CMP r4,r0
JMP[NE] @ms_move
CALL @ms_down
JMP @ms_changed
ms_release:
; Drop window at either desktop edge to snap it into that half. This is
; a guest-native geometric decision, not the v86 viewport or browser CSS.
LD r2,r0,@ms_drag
MOVI r3,1
CMP r2,r3
JMP[NE] @ms_release_end
LD r3,r0,@ms_x
MOVI r4,24
CMP r3,r4
JMP[GE] @ms_snap_right_check
LD r1,r0,@ms_id
MOVI r2,0
CALL @wm_snap
JMP @ms_release_end
ms_snap_right_check:
LD r4,r0,@fb_w
MOVI r5,24
SUB r4,r4,r5
CMP r3,r4
JMP[LT] @ms_release_end
LD r1,r0,@ms_id
MOVI r2,1
CALL @wm_snap
ms_release_end:
ST r0,r0,@ms_drag
JMP @ms_changed
ms_move:
LD r1,r0,@ms_drag
CMP r1,r0
JMP[EQ] @ms_changed
LD r1,r0,@ms_dx
LD r2,r0,@ms_dy
BOOL.14 r1,r1,r2
CMP r1,r0
JMP[EQ] @ms_changed
CALL @ms_drag_update
ST r13,r0,@wm_redraw
ms_changed:
; Pointer movement alone only updates its saved-under pixels. Geometry,
; focus and shell actions request full ordered composition themselves.
CALL @ms_draw
ms_update_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ms_cycle_under_pointer: right-click through the z-stack of
; overlapping windows. Topmost is already selected; choose the next
; matching window underneath and bring it forward. The taskbar remains
; available for completely disjoint windows or a touch-only device.
ms_cycle_under_pointer:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,@sh_open
LD r2,r0,@sh_modal
BOOL.14 r3,r1,r2
CMP r3,r0
JMP[NE] @mcu_done
LD r3,r0,@fb_h
MOVI r4,#TASKH
SUB r3,r3,r4
LD r2,r0,@ms_y
CMP r2,r3
JMP[GE] @mcu_done
LD r1,r0,@wm_zn
ST r1,r0,@mcu_i
ST r0,r0,@mcu_seen
mcu_scan:
LD r1,r0,@mcu_i
CMP r1,r0
JMP[EQ] @mcu_done
SUB r1,r1,r13
ST r1,r0,@mcu_i
MOVI r2,#ZOL
MOVHI r2,#ZOH
ADD r2,r2,r1
LD r1,r2,0
ST r1,r0,@mcu_id
CALL @wm_wbase
LD r2,r0,@ms_x
LD r3,r1,#W_X
CMP r2,r3
JMP[LT] @mcu_scan
LD r4,r1,#W_W
ADD r4,r4,r3
CMP r2,r4
JMP[GE] @mcu_scan
LD r2,r0,@ms_y
LD r3,r1,#W_Y
CMP r2,r3
JMP[LT] @mcu_scan
LD r4,r1,#W_H
ADD r4,r4,r3
CMP r2,r4
JMP[GE] @mcu_scan
LD r3,r0,@mcu_seen
CMP r3,r0
JMP[EQ] @mcu_first
LD r1,r0,@mcu_id
CALL @wm_raise
JMP @mcu_done
mcu_first:
MOVI r3,1
ST r3,r0,@mcu_seen
JMP @mcu_scan
mcu_done:
SUB r14,r14,r13
LD r15,r14,0
RET
mcu_i:
.word 0
mcu_id:
.word 0
mcu_seen:
.word 0

; Native mouse down: taskbar launcher, taskbar windows, modal/dialog,
; then back-to-front hit testing of overlapping window geometry.
ms_down:
ST r15,r14,0
ADD r14,r14,r13
ST r0,r0,@ms_drag
LD r1,r0,@sh_open
LD r2,r0,@sh_modal
BOOL.14 r3,r1,r2
CMP r3,r0
JMP[EQ] @ms_down_normal
LD r1,r0,@ms_x
LD r2,r0,@ms_y
CALL @sh_click
JMP @ms_down_done
ms_down_normal:
LD r1,r0,@fb_h
MOVI r2,#TASKH
SUB r1,r1,r2
LD r2,r0,@ms_y
CMP r2,r1
JMP[LT] @ms_window_hit
LD r1,r0,@ms_x
MOVI r2,140
CMP r1,r2
JMP[GE] @ms_taskslot
CALL @sh_launcher
JMP @ms_down_done
ms_taskslot:
MOVI r2,140
SUB r1,r1,r2
MOVI r2,106
DIV r1,r1,r2
CALL @wm_taskbar_select
JMP @ms_down_done
ms_window_hit:
LD r1,r0,@wm_zn
ST r1,r0,@ms_index
ms_hit_loop:
LD r1,r0,@ms_index
CMP r1,r0
JMP[EQ] @ms_down_done
SUB r1,r1,r13
ST r1,r0,@ms_index
MOVI r2,#ZOL
MOVHI r2,#ZOH
ADD r2,r2,r1
LD r1,r2,0
ST r1,r0,@ms_id
CALL @wm_wbase
ST r1,r0,@ms_b
LD r2,r0,@ms_x
LD r3,r1,#W_X
CMP r2,r3
JMP[LT] @ms_hit_loop
LD r4,r1,#W_W
ADD r4,r4,r3
CMP r2,r4
JMP[GE] @ms_hit_loop
LD r2,r0,@ms_y
LD r3,r1,#W_Y
CMP r2,r3
JMP[LT] @ms_hit_loop
LD r4,r1,#W_H
ADD r4,r4,r3
CMP r2,r4
JMP[GE] @ms_hit_loop
; Hit: focus now. Preserve the record pointer across nested calls.
CALL @wm_top
LD r2,r0,@ms_id
CMP r1,r2
JMP[EQ] @ms_hit_focused
ADD r1,r2,r0
CALL @wm_raise
ms_hit_focused:
LD r1,r0,@ms_b
LD r2,r0,@ms_y
LD r3,r1,#W_Y
SUB r2,r2,r3
MOVI r3,17
CMP r2,r3
JMP[GE] @ms_bottom_grip
; Title-bar controls: close, maximize/restore, minimize.
LD r2,r0,@ms_x
LD r3,r1,#W_X
SUB r2,r2,r3
LD r4,r1,#W_W
MOVI r5,#WM_CLOSE_X
SUB r4,r4,r5
CMP r2,r4
JMP[LT] @ms_hit_max
; The X title-bar control closes immediately. F4 remains the separate
; confirmation-dialog path. Never require a hidden second click on Android.
LD r1,r0,@ms_id
CALL @wm_close
ST r0,r0,@ms_drag
MOVI r1,0xFFFF
ST r1,r0,@ms_last_title_id
JMP @ms_down_done
ms_hit_max:
MOVI r5,#WM_CTL_W
SUB r4,r4,r5
CMP r2,r4
JMP[LT] @ms_hit_min
MOVI r1,0xFFFF
ST r1,r0,@ms_last_title_id
LD r1,r0,@ms_id
MOVI r2,0
MOVI r3,0
CALL @wm_enlarge
JMP @ms_down_done
ms_hit_min:
MOVI r5,#WM_CTL_W
SUB r4,r4,r5
CMP r2,r4
JMP[LT] @ms_hit_move
MOVI r1,0xFFFF
ST r1,r0,@ms_last_title_id
LD r1,r0,@ms_id
CALL @wm_minimize
JMP @ms_down_done
ms_hit_move:
; Two title-bar clicks within 350 ticks on the same window toggle
; maximize/restore. Normal single click begins move mode.
TICK r2
LD r3,r0,@ms_last_title_tick
SUB r4,r2,r3
MOVI r5,350
CMP r4,r5
JMP[GT] @ms_title_new
LD r3,r0,@ms_last_title_id
LD r4,r0,@ms_id
CMP r3,r4
JMP[NE] @ms_title_new
ST r0,r0,@ms_last_title_tick
MOVI r3,0xFFFF
ST r3,r0,@ms_last_title_id
LD r1,r0,@ms_id
MOVI r2,0
MOVI r3,0
CALL @wm_enlarge
JMP @ms_down_done
ms_title_new:
ST r2,r0,@ms_last_title_tick
LD r3,r0,@ms_id
ST r3,r0,@ms_last_title_id
MOVI r1,1
ST r1,r0,@ms_drag
JMP @ms_down_done
ms_bottom_grip:
LD r2,r1,#W_H
MOVI r3,14
SUB r2,r2,r3
LD r3,r0,@ms_y
LD r4,r1,#W_Y
SUB r3,r3,r4
CMP r3,r2
JMP[LT] @ms_down_done
LD r2,r1,#W_W
MOVI r3,18
SUB r2,r2,r3
LD r3,r0,@ms_x
LD r4,r1,#W_X
SUB r3,r3,r4
CMP r3,r2
JMP[LT] @ms_down_done
MOVI r1,2
ST r1,r0,@ms_drag
ms_down_done:
SUB r14,r14,r13
LD r15,r14,0
RET

ms_drag_update:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,@ms_drag
CMP r1,r0
JMP[EQ] @ms_drag_done
LD r1,r0,@ms_id
CALL @wm_wbase
ST r1,r0,@ms_b
LD r2,r1,#W_FLAGS
MOVI r3,1
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[NE] @ms_drag_done
LD r2,r0,@ms_drag
MOVI r3,2
CMP r2,r3
JMP[EQ] @ms_drag_resize
LD r2,r1,#W_X
LD r3,r0,@ms_dx
ADD r2,r2,r3
SHR r4,r2,31
CMP r4,r0
JMP[EQ] @ms_move_xok
MOVI r2,0
ms_move_xok:
LD r3,r0,@fb_w
LD r4,r1,#W_W
SUB r3,r3,r4
CMP r2,r3
JMP[LE] @ms_move_xstore
ADD r2,r3,r0
ms_move_xstore:
ST r2,r1,#W_X
LD r2,r1,#W_Y
LD r3,r0,@ms_dy
SUB r2,r2,r3
MOVI r3,#TOPH
CMP r2,r3
JMP[GE] @ms_move_yok
ADD r2,r3,r0
ms_move_yok:
LD r3,r0,@fb_h
MOVI r4,#TASKH
SUB r3,r3,r4
LD r4,r1,#W_H
SUB r3,r3,r4
CMP r2,r3
JMP[LE] @ms_move_ystore
ADD r2,r3,r0
ms_move_ystore:
ST r2,r1,#W_Y
JMP @ms_drag_done
ms_drag_resize:
LD r2,r1,#W_W
LD r3,r0,@ms_dx
ADD r2,r2,r3
MOVI r3,160
CMP r2,r3
JMP[GE] @ms_resize_wmin
ADD r2,r3,r0
ms_resize_wmin:
LD r3,r0,@fb_w
LD r4,r1,#W_X
SUB r3,r3,r4
CMP r2,r3
JMP[LE] @ms_resize_wstore
ADD r2,r3,r0
ms_resize_wstore:
ST r2,r1,#W_W
LD r2,r1,#W_H
LD r3,r0,@ms_dy
SUB r2,r2,r3
MOVI r3,100
CMP r2,r3
JMP[GE] @ms_resize_hmin
ADD r2,r3,r0
ms_resize_hmin:
LD r3,r0,@fb_h
MOVI r4,#TASKH
SUB r3,r3,r4
LD r4,r1,#W_Y
SUB r3,r3,r4
CMP r2,r3
JMP[LE] @ms_resize_hstore
ADD r2,r3,r0
ms_resize_hstore:
ST r2,r1,#W_H
ms_drag_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; Pointer: guest-native save-under cursor. Erase before any app paints;
; invalidate saved pixels before a complete frame replaces the framebuffer.
ms_cursor_saved:
.word 0
ms_cursor_pixels:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ms_erase:
LD r1,r0,@ms_cursor_saved
CMP r1,r0
RET[EQ]
ST r0,r0,@ms_cursor_saved
LD r12,r0,@fb_scene_offset
CMP r12,r0
JMP[NE] @ms_scene_erase
MOVI r11,0
JMP @ms_cursor_blit
ms_draw:
LD r1,r0,@ms_cursor_saved
CMP r1,r0
RET[NE]
LD r1,r0,@ms_x
ST r1,r0,@ms_frame
LD r1,r0,@ms_y
ST r1,r0,@ms_tick
ST r13,r0,@ms_cursor_saved
MOVI r11,1
ms_cursor_blit:
LD r1,r0,@ms_frame
LD r2,r0,@ms_tick
LD r5,r0,@fb_w
LD r6,r0,@fb_h
MOVI r7,@ms_cursor_pixels
MOVI r4,0
ms_cursor_row:
MOVI r3,0
ms_cursor_col:
ADD r8,r1,r3
CMP r8,r5
JMP[GE] @ms_cursor_next
ADD r9,r2,r4
CMP r9,r6
JMP[GE] @ms_cursor_next
MUL r9,r9,r5
ADD r9,r9,r8
CMP r11,r0
JMP[EQ] @ms_cursor_restore
VPEEK r10,r9
ST r10,r7,0
; A compact arrow, rather than the old F-shaped cursor.
MOVI r8,9
CMP r4,r8
JMP[GE] @ms_cursor_tail
CMP r3,r4
JMP[GT] @ms_cursor_next
CMP r3,r0
JMP[EQ] @ms_cursor_dark
CMP r3,r4
JMP[EQ] @ms_cursor_dark
JMP @ms_cursor_light
ms_cursor_tail:
MOVI r8,2
CMP r3,r8
JMP[LT] @ms_cursor_next
MOVI r8,4
CMP r3,r8
JMP[GT] @ms_cursor_next
CMP r3,r8
JMP[EQ] @ms_cursor_dark
MOVI r8,2
CMP r3,r8
JMP[EQ] @ms_cursor_dark
ms_cursor_light:
MOVI r10,#C_TXT
JMP @ms_cursor_poke
ms_cursor_dark:
MOVI r10,0
JMP @ms_cursor_poke
ms_cursor_restore:
LD r10,r7,0
ms_cursor_poke:
VPOKE r10,r9
ms_cursor_next:
ADD r7,r7,r13
ADD r3,r3,r13
MOVI r8,11
CMP r3,r8
JMP[LT] @ms_cursor_col
ADD r4,r4,r13
MOVI r8,13
CMP r4,r8
JMP[LT] @ms_cursor_row
RET

; Restore the old opaque cursor footprint from the retained scene. The
; scene never contains a cursor. No offscreen VPEEK or front scratch pixel.
ms_scene_erase:
LD r1,r0,@ms_frame
LD r2,r0,@ms_tick
LD r5,r0,@fb_w
LD r6,r0,@fb_h
MOVI r4,0
mse_row:
ADD r9,r2,r4
CMP r9,r6
RET[GE]
MOVI r8,9
CMP r4,r8
JMP[GE] @mse_tail
ADD r8,r1,r0
ADD r10,r4,r13
JMP @mse_clip
mse_tail:
MOVI r8,2
ADD r8,r1,r8
MOVI r10,3
mse_clip:
CMP r8,r5
JMP[GE] @mse_next
ADD r11,r8,r10
CMP r11,r5
SUB[GT] r10,r5,r8
MUL r9,r9,r5
ADD r9,r9,r8
ADD r11,r9,r12
FBCOPY r10,r9,r11
mse_next:
ADD r4,r4,r13
MOVI r8,13
CMP r4,r8
JMP[LT] @mse_row
RET
