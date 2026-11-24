; shell.nas — NaN/0S guest-native modern launcher and modal UI.
; NO DOM, HTML, JavaScript, C, Python, or host-side window decoration.
; NaN16 F1 opens launcher, arrows select, 1..8 jump, Enter opens, Esc closes.
; F4 opens a native confirmation dialog (Enter closes focused window, Esc cancels).
; Uses framebuffer and window-manager primitives, respects 1024x768 mode.
;
; Public API: sh_init; sh_launcher; sh_dialog; sh_draw;
;             sh_handle (r1=decoded PS/2 event; only call while active).
sh_open:
.word 0
sh_modal:
.word 0
sh_sel:
.word 0
sh_i:
.word 0
sh_x:
.word 0
sh_y:
.word 0
sh_title:
.word 0
sh_temp:
.word 0
sh_ret:
.word 0

sh_init:
ST r0,r0,@sh_open
ST r0,r0,@sh_modal
ST r0,r0,@sh_sel
RET

sh_launcher:
LD r2,r0,@sh_open
MOVI r3,1
BOOL.6 r2,r2,r3
ST r2,r0,@sh_open
ST r0,r0,@sh_modal
ST r3,r0,@wm_redraw
RET

sh_dialog:
MOVI r1,1
ST r1,r0,@sh_modal
ST r0,r0,@sh_open
ST r1,r0,@wm_redraw
RET

; Keyboard modal handling consumes every key while an overlay is active.
sh_handle:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,@sh_temp
LD r2,r0,@sh_modal
CMP r2,r0
JMP[NE] @sh_dialog_key
LD r2,r0,@sh_open
CMP r2,r0
JMP[EQ] @sh_key_done
LD r1,r0,@sh_temp
MOVI r2,27
CMP r1,r2
JMP[EQ] @sh_close
MOVI r2,0x101
CMP r1,r2
JMP[EQ] @sh_close
MOVI r2,13
CMP r1,r2
JMP[EQ] @sh_launch_selected
; Number shortcuts 1..8 are a direct mapping to the existing app kinds.
MOVI r2,49
CMP r1,r2
JMP[LT] @sh_arrows
MOVI r3,56
CMP r1,r3
JMP[GT] @sh_arrows
SUB r1,r1,r2
ST r1,r0,@sh_sel
JMP @sh_launch_selected
sh_arrows:
MOVI r2,0x112
CMP r1,r2
JMP[EQ] @sh_left
MOVI r2,0x113
CMP r1,r2
JMP[EQ] @sh_right
MOVI r2,0x110
CMP r1,r2
JMP[EQ] @sh_up
MOVI r2,0x111
CMP r1,r2
JMP[EQ] @sh_down
MOVI r2,9
CMP r1,r2
JMP[EQ] @sh_right
JMP @sh_key_done
sh_left:
LD r1,r0,@sh_sel
MOVI r2,7
ADD r1,r1,r2
JMP @sh_wrap
sh_right:
LD r1,r0,@sh_sel
ADD r1,r1,r13
sh_wrap:
MOVI r2,7
BOOL.8 r1,r1,r2
ST r1,r0,@sh_sel
JMP @sh_repaint
sh_up:
LD r1,r0,@sh_sel
MOVI r2,4
ADD r1,r1,r2
JMP @sh_wrap
sh_down:
LD r1,r0,@sh_sel
MOVI r2,4
ADD r1,r1,r2
JMP @sh_wrap
sh_repaint:
MOVI r1,1
ST r1,r0,@wm_redraw
JMP @sh_key_done
sh_launch_selected:
ST r0,r0,@sh_open
MOVI r1,1
ST r1,r0,@wm_redraw
LD r1,r0,@sh_sel
; The app grid is a launcher, not a "create another identical window"
; control. Its Terminal tile focuses an existing live Terminal (or opens
; one if all are closed). Explicit 't' in the terminal still creates new
; instances when the user actually wants parallel terminals.
CMP r1,r0
JMP[EQ] @sh_launch_existing
; Settings, network and utilities also remain single-instance.
MOVI r2,4
CMP r1,r2
JMP[LT] @sh_launch_new
MOVI r2,6
CMP r1,r2
JMP[GT] @sh_launch_new
sh_launch_existing:
CALL @gui_single
JMP @sh_key_done
sh_launch_new:
CALL @gui_open_new
JMP @sh_key_done
sh_dialog_key:
LD r1,r0,@sh_temp
MOVI r2,27
CMP r1,r2
JMP[EQ] @sh_close
MOVI r2,13
CMP r1,r2
JMP[NE] @sh_key_done
ST r0,r0,@sh_modal
; The final window is closable: the desktop, taskbar and launcher remain.
; Capture the requested focused window and use the ordinary native close
; primitive. The shell does not silently keep a last window alive.
CALL @wm_top
MOVI r2,0xFFFF
CMP r1,r2
JMP[EQ] @sh_notice
CALL @wm_close
sh_notice:
MOVI r1,20
CALL @wm_notice
JMP @sh_repaint
sh_close:
ST r0,r0,@sh_open
ST r0,r0,@sh_modal
JMP @sh_repaint
sh_key_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; sh_click r1=x r2=y: mouse-only interaction for native overlays.
; A modal consumes pointer input; clicks outside never affect windows below it.
; Launcher card geometry exactly matches sh_draw's 4-column x 2-row grid.
sh_click:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,@sh_pointer_x
ST r2,r0,@sh_pointer_y
LD r3,r0,@sh_modal
CMP r3,r0
JMP[NE] @sh_click_dialog
LD r3,r0,@sh_open
CMP r3,r0
JMP[EQ] @sh_click_done
MOVI r3,195
CMP r1,r3
JMP[LT] @sh_click_done
MOVI r3,819
CMP r1,r3
JMP[GT] @sh_click_done
MOVI r3,197
CMP r2,r3
JMP[LT] @sh_click_done
MOVI r3,485
CMP r2,r3
JMP[GT] @sh_click_done
MOVI r3,195
SUB r1,r1,r3
MOVI r3,156
DIV r1,r1,r3
MOVI r3,3
CMP r1,r3
JMP[LE] @sh_click_colok
JMP @sh_click_done
sh_click_colok:
ST r1,r0,@sh_pointer_col
LD r2,r0,@sh_pointer_y
MOVI r3,197
SUB r2,r2,r3
MOVI r3,152
DIV r2,r2,r3
SHL r2,r2,2
LD r1,r0,@sh_pointer_col
ADD r1,r1,r2
MOVI r3,7
CMP r1,r3
JMP[GT] @sh_click_done
ST r1,r0,@sh_sel
CALL @sh_launch_selected
JMP @sh_click_done
sh_click_dialog:
; Left half of the centered dialog is Cancel, right half confirms Close.
MOVI r3,330
CMP r2,r3
JMP[LT] @sh_click_done
MOVI r3,454
CMP r2,r3
JMP[GT] @sh_click_done
MOVI r3,500
CMP r1,r3
JMP[LT] @sh_click_cancel
MOVI r1,13
ST r1,r0,@sh_temp
CALL @sh_dialog_key
JMP @sh_click_done
sh_click_cancel:
MOVI r1,27
ST r1,r0,@sh_temp
CALL @sh_dialog_key
sh_click_done:
SUB r14,r14,r13
LD r15,r14,0
RET
sh_pointer_x:
.word 0
sh_pointer_y:
.word 0
sh_pointer_col:
.word 0

; These overlays render AFTER taskbar + windows, so their composition
; order and focus highlights are intrinsic to the native frame buffer.
sh_draw:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,@sh_modal
CMP r1,r0
JMP[NE] @sh_draw_dialog
LD r1,r0,@sh_open
CMP r1,r0
JMP[EQ] @sh_draw_done
; Dim the center region with shadow + panel; 4x2 colored app grid.
MOVI r1,183
MOVI r2,126
MOVI r3,660
MOVI r4,432
MOVI r5,#C_SHADOW
CALL @wm_rect
MOVI r1,174
MOVI r2,117
MOVI r3,660
MOVI r4,432
MOVI r5,#C_FOC
CALL @wm_rect
MOVI r1,178
MOVI r2,121
MOVI r3,652
MOVI r4,424
MOVI r5,#C_DESK
CALL @wm_rect
MOVI r1,178
MOVI r2,121
MOVI r3,652
MOVI r4,38
MOVI r5,#C_TITLE_F
CALL @wm_rect
MOVI r1,196
MOVI r2,132
MOVI r3,@sh_title_text
MOVI r4,#C_TXT
CALL @fb_text7
MOVI r1,196
MOVI r2,164
MOVI r3,@sh_subtitle
MOVI r4,#C_YEL
CALL @fb_text7
ST r0,r0,@sh_i
sh_card_loop:
LD r1,r0,@sh_i
MOVI r2,8
CMP r1,r2
JMP[GE] @sh_draw_done
MOVI r2,3
BOOL.8 r3,r1,r2
MOVI r4,156
MUL r3,r3,r4
MOVI r4,195
ADD r3,r3,r4
ST r3,r0,@sh_x
SHR r1,r1,2
MOVI r4,152
MUL r1,r1,r4
MOVI r4,197
ADD r1,r1,r4
ST r1,r0,@sh_y
LD r1,r0,@sh_i
LD r2,r0,@sh_sel
MOVI r5,#C_BLUR
CMP r1,r2
JMP[NE] @sh_card_back
MOVI r5,#C_ACCENT
sh_card_back:
LD r1,r0,@sh_x
LD r2,r0,@sh_y
MOVI r3,148
MOVI r4,136
CALL @wm_rect
LD r1,r0,@sh_x
ADD r1,r1,r13
LD r2,r0,@sh_y
ADD r2,r2,r13
MOVI r3,146
MOVI r4,134
MOVI r5,#C_SURFACE
CALL @wm_rect
LD r1,r0,@sh_i
MOVI r2,@sh_appnames
ADD r2,r2,r1
LD r3,r2,0
LD r1,r0,@sh_x
MOVI r2,12
ADD r1,r1,r2
LD r2,r0,@sh_y
MOVI r4,65
ADD r2,r2,r4
MOVI r4,#C_TXT
CALL @fb_text7
LD r1,r0,@sh_x
MOVI r2,13
ADD r1,r1,r2
LD r2,r0,@sh_y
MOVI r4,20
ADD r2,r2,r4
LD r3,r0,@sh_i
MOVI r4,49
ADD r3,r3,r4
MOVI r4,#C_YEL
CALL @fb_char7
LD r1,r0,@sh_i
ADD r1,r1,r13
ST r1,r0,@sh_i
JMP @sh_card_loop
sh_draw_dialog:
MOVI r1,291
MOVI r2,274
MOVI r3,448
MOVI r4,188
MOVI r5,#C_SHADOW
CALL @wm_rect
MOVI r1,283
MOVI r2,266
MOVI r3,448
MOVI r4,188
MOVI r5,#C_FOC
CALL @wm_rect
MOVI r1,288
MOVI r2,271
MOVI r3,438
MOVI r4,178
MOVI r5,#C_SURFACE
CALL @wm_rect
MOVI r1,306
MOVI r2,291
MOVI r3,@sh_dialog_title
MOVI r4,#C_TXT
CALL @fb_text7
MOVI r1,306
MOVI r2,330
MOVI r3,@sh_dialog_body
MOVI r4,#C_TXT
CALL @fb_text7
MOVI r1,306
MOVI r2,390
MOVI r3,@sh_dialog_action
MOVI r4,#C_YEL
CALL @fb_text7
sh_draw_done:
SUB r14,r14,r13
LD r15,r14,0
RET

sh_title_text:
.str "NaN/0S  /  APPLICATIONS"
sh_subtitle:
.str "1-8 OPEN   ARROWS SELECT   ENTER LAUNCH   ESC CLOSE"
sh_dialog_title:
.str "NAN/0S  /  CLOSE WINDOW?"
sh_dialog_body:
.str "Close the focused application window?"
sh_dialog_action:
.str "ENTER = CLOSE          ESC = CANCEL"
sh_appnames:
.word @sh_n0,@sh_n1,@sh_n2,@sh_n3,@sh_n4,@sh_n5,@sh_n6,@sh_n7
sh_n0:
.str "Terminal"
sh_n1:
.str "Lattice"
sh_n2:
.str "Monitor"
sh_n3:
.str "Hex"
sh_n4:
.str "Settings"
sh_n5:
.str "NaNNet"
sh_n6:
.str "Utilities"
sh_n7:
.str "Browser"
