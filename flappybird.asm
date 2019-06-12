.rst_00           ; pipe random lookup
  nop             ; { 00 00 01 01 02 03 03 04 05 06 06 07 08 08 09 09 }
  nop
  ld bc, $0201
  inc bc
  inc bc
  inc b
  dec b
  ld b, $06
  rlca
  ld ($0908), sp
  add hl, bc

.int_vblank
  push af
  ld a, 1
  ldh ($f4), a ; is_vblank
  pop af
  reti

.int_keys ; seeds rng on the first time any key is pressed
  push af
  ld hl, $fff0 ; rng_state[0..3]
  ldh a, ($04) ; REG_DIV
  ldi (hl), a
  ldi (hl), a
  ldi (hl), a
  ld (hl), a
  ldh a, ($ff) ; REG_IE
  and $ef ; clear bit 4
  ldh ($ff), a
  pop af
  reti

.main
  ; set stack pointer
  ld sp, $dfff

  ; disable interrupts
  di
  xor a
  ldh ($0f), a

  ; enable display
  ld a, $80
  ldh ($40), a

.wait_for_vblank
  ldh a, ($44)
  cp $94
  jr nz, wait_for_vblank

  ; disable display
  xor a
  ldh ($40), a

  ; zero memory
  ld hl, $8000
  ld bc, $6000
.z0
  ldi (hl), a
  dec c
  jr nz, z0
  dec b
  jr nz, z0
  ld hl, $fe00
.z1
  ld (hl), a
  inc l
  jr nz, z1
  ld hl, $ff80
.z2
  ld (hl), a
  inc l
  jr nz, z2

  ; init registers
  ldh ($05), a ; REG_TIMA
  ldh ($06), a ; REG_TMA
  ldh ($07), a ; REG_TAC
  ldh ($26), a ; REG_SND_CTL

  ; set up scxy
  ldh ($42), a ; REG_SCY
  ldh ($43), a ; REG_SCX
  ldh ($45), a ; REG_LYC
  ldh ($4a), a ; REG_WY
  ldh ($4b), a ; REG_WX

  ; init variables
  ldh ($80), a ; keys_held
  ldh ($81), a ; keys_down
  ldh ($82), a ; game_state
  ldh ($90), a ; bird_v (positive = down)
  ldh ($92), a ; bird_menu_path_counter
  ldh ($c0), a ; score_bcd_lo
  ldh ($c1), a ; score_bcd_hi
  ldh ($c2), a ; is_score_updated
  ldh ($f0), a ; rng_state
  ldh ($f1), a ; rng_state_1
  ldh ($f2), a ; rng_state_2
  ldh ($f3), a ; rng_state_3
  ldh ($f4), a ; is_vblank
  ld a, 5
  ldh ($91), a ; bird_anim_counter
  ld a, $08
  ldh ($e0), a ; next_col_offset (cycles $00,$08,$10,$18)

  ; setup palettes
  ld a, $e4
  ldh ($47), a ; REG_BGP  3_2_1_0
  ldh ($48), a ; REG_OBP0 3_2_1_0
  ld a, $c4
  ldh ($49), a ; REG_OBP1 3_0_1_0

  ; copy sprite tile data
  ld hl, $8000
  ld de, data_tile0_bin
  ld bc, $0300
  call cp_de_to_hl_wide

  ; copy bg tile data
  ld hl, $9000
  ld de, data_tile1_bin
  ld b, $c0
  call cp_de_to_hl

  ; copy shared tile data
  ld hl, $8800
  ld de, data_tile2_bin
  ld b, $80
  call cp_de_to_hl

  ; init ground
  ld a, $0b ; ground sprite
  ld hl, $9a20
  ld b, $20
  call set_hl

  ; init sprites
  ld hl, $fe00
  ld de, data_sprite_bin
  ld b, $40
  call cp_de_to_hl

  ; enable display
  ld a, $83
  ldh ($40), a
  ; enable interrupts
  ld a, $11 ; INT_KEYS, INT_VBLANK
  ldh ($ff), a
  ei

.loop
  call read_keys
  call animate_bird
  call run_state
.halt
  halt
  ldh a, ($f4) ; is_vblank
  and a
  jr z, halt
  xor a
  ldh ($f4), a ; is_vblank
  jp loop

.run_state
  ldh a, ($82) ; game_state
  and a
  jr nz, run_state_1
  jp update_state_0
.run_state_1
  jp update_state_1
.update_state_0 ; menu
  call animate_sine_path
  call scroll_screen
  ldh a, ($81) ; keys_down
  bit 0, a
  ret z        ; return if ((keys_down & KEY_A) == 0)
  ld a, 1
  ldh ($82), a ; game_state = 1
  ldh ($c2), a ; is_score_updated = true
  call render_score
  call handle_jump ; start the game with a hop
  ret
.update_state_1 ; play
  call scroll_screen
  call handle_scroll
  call handle_jump
  call render_score
  ret

.scroll_screen
  ldh a, ($43) ; REG_SCX
  inc a
  ldh ($43), a
  and $3f
  cp $21       ; if (REG_SCX % 0x40 == 0x21) {
  ret nz
  ldh a, ($e0)
  add a, 8
  and $1f
  ldh ($e0), a ;   next_col_offset = (next_col_offset + 8) % 0x20
  ret          ; }

.handle_scroll
  ldh a, ($43) ; REG_SCX
  and $3f      ; switch (REG_SCX % 0x40)
  cp $28
  jr z, handle_scroll_draw
  cp $09
  jr z, handle_scroll_score
  ret
.handle_scroll_draw ; draw wall is expensive, we render on a frame without collision detection
  ldh a, ($e0)   ; next_col_offset
  add a, $10     ; draw 2 walls ahead
  and $1f
  ld l, a
  ld h, $9a      ; hl = bottom left tile of 2 walls ahead
  call draw_wall
  ret
.handle_scroll_score
  ldh a, ($e0)   ; next_col_offset
  ld l, a
  ld h, $98      ; hl = top left tile of next wall
  ld a, (hl)
  and a
  ret z          ; return if there is no wall (tile is blank)
  ldh a, ($c1)
  ld b, a
  ldh a, ($c0)
  cp b
  jr nz, l6      ; ok to inc if c0 != c1
  cp $99
  ret z          ; return if c0 == c1 == $99 (max score)
.l6
  ld a, 1
  ldh ($c2), a   ; is_score_updated = true
  ld b, a
  ldh a, ($c0)   ; score_bcd
  add a, b       ; using add resets the carry flag for daa
  daa
  ldh ($c0), a
  ret nc
  ldh a, ($c1)
  add a, b
  daa
  ldh ($c1), a
  ret

.handle_jump
  ldh a, ($81) ; keys_down
  bit 0, a
  jr z, l10    ; if (keys_down & KEY_A) {
  ld a, $f3    ;   v = -13
  jr l11       ; } else {
.l10
  ldh a, ($90)
  inc a        ;   v += 1
.l11           ; }
  ldh ($90), a
  ld b, a
  sra b
  sra b
  sra b ; use v/8
  ld a, ($fe00); sprite[0].y
  add a, b     ; sprite[0].y + v/8
  cp 14
  jr nc, l9    ; if (y < 14) {
  xor a
  ldh ($90), a ;   v = 0
  ld a, 14     ;   y = 14
  jr update_bird_y
.l9
  cp 138       ; } else if (y >= 138) {
  jr c, update_bird_y
  xor a
  ldh ($90), a ;   v = 0
  ld a, 138    ;   y = 138
.update_bird_y ; }
  ld ($fe00), a
  ld ($fe04), a
  add a, 8
  ld ($fe08), a
  ld ($fe0c), a
  sub a, 3
  ld ($fe10), a
  ret

.render_score
  ldh a, ($c2)
  and a
  ret z        ; return if (!is_score_updated)
  xor a
  ldh ($c2), a
  ld c, a
  ld hl, $fe22 ; &sprite[8].tile
  ld de, $0004
  ldh a, ($c1)
  ld b, a
  and $f0
  swap a
  call render_score_set
  ld a, b
  and $0f
  call render_score_set
  ldh a, ($c0)
  ld b, a
  and $f0
  swap a
  call render_score_set
  ld a, b
  and $0f
  call l5    ; always render final digit
  ret
.render_score_set
  or c       ; have we rendered a leading non-zero?
  jr nz, l4
  ld a, $0a  ; if not, blank all leading zeros
  jr l5
.l4
  ld c, $10  ; set c once we render a non-zero
.l5
  or $10
  ld (hl), a
  add hl, de
  xor $30
  ld (hl), a
  add hl, de
  ret

.read_keys
  ld a, $20
  ldh ($00), a
  ldh a, ($00)
  ldh a, ($00)
  cpl
  and $0f
  swap a
  ld b, a
  ld a, $10
  ldh ($00), a
  ldh a, ($00)
  ldh a, ($00)
  ldh a, ($00)
  ldh a, ($00)
  ldh a, ($00)
  ldh a, ($00)
  cpl
  and $0f
  or b
  ld b, a
  ldh a, ($80)
  xor b
  and b
  ldh ($81), a
  ld a, b
  ldh ($80), a
  ld a, $30
  ldh ($00), a
  ret

.rng_next ; https://github.com/edrosten/8bit_rng/blob/master/rng-4261412736.c
  ldh a, ($f1) ; x
  ld b, a
  swap a
  and $f0
  xor b
  ld b, a      ; t
  ldh a, ($f2)
  ldh ($f1), a ; x=y
  ldh a, ($f3)
  ldh ($f2), a ; y=z
  ldh a, ($f0)
  ldh ($f3), a ; z=a
  ld c, a
  srl c        ; z >> 1
  xor c
  xor b
  sla b        ; t << 1
  xor b
  ldh ($f0), a
  ret

.draw_wall ; hl: target_col (9a20..9a3f)
  call rng_next
  and $0f
  ld e, a
  ld d, $00    ; de = (0x0000..0x0015) = pipe random lookup
  ld a, (de)   ; a ∈ [0..9]
  ld de, $ffdf ; -0x21 = 1 row + 1 tile
  ld b, a      ; b = tiles to draw before gap
  cpl          ; a = -b - 1
  add a, 10    ; a = 10 - b - 1 = 9 - b = (17 - 8) - b
  ld c, a      ; c = tiles to draw after gap
  cp 9         ; b + c == 9, so this is equivalent to checking b == 0
  jr z, l1     ; skip if tiles to draw before = 0

  ld a, 1      ; wall tiles = {1, 2}
.l13
  ldi (hl), a
  inc a
  ld (hl), a
  dec a
  add hl, de
  dec b
  jr nz l13

.l1            ; draw top of pipe
  ld a, 3
  ldi (hl), a
  inc a
  ld (hl), a
  add hl, de
  inc a
  ldi (hl), a
  inc a
  ld (hl), a
  add hl, de

  ld b, 4      ; clear the next 4 rows
  xor a
.l0
  ldi (hl), a
  ld (hl), a
  add hl, de
  dec b
  jr nz l0

  ld a, 7      ; draw bottom of pipe
  ldi (hl), a
  inc a
  ld (hl), a
  add hl, de
  inc a
  ldi (hl), a
  inc a
  ld (hl), a
  add hl, de

  ld a, c
  and a
  ret z        ; return if tiles to draw after == 0
  ld a, 1
.l14
  ldi (hl), a
  inc a
  ld (hl), a
  dec a
  add hl, de
  dec c
  jr nz, l14
  ret

.animate_bird
  ldh a, ($91) ; bird_anim_counter
  dec a
  jr nz, l3
  ld a, ($fe12) ; sprite[4].tile
  inc a         ; a ∈ [80..83]
  and $83       ; mask
  ld ($fe12), a
  ld a, 5
.l3
  ldh ($91), a
  ret

.animate_sine_path
  ldh a, ($92)
  ld e, a
  inc a
  and $3f
  ldh ($92), a  ; bird_anim_counter++
  ld d, 0
  ld hl, data_sine_path_bin
  add hl, de    ; sine_path[a]
  ld a, ($fe00) ; sprite[0].y
  add a, (hl)
  call update_bird_y
  ret

.cp_de_to_hl
  ld a, (de)
  ldi (hl), a
  inc de
  dec b
  jr nz, cp_de_to_hl
  ret

.cp_de_to_hl_wide
  ld a, (de)
  ldi (hl), a
  inc de
  dec c
  jr nz, cp_de_to_hl_wide
  dec b
  jr nz, cp_de_to_hl_wide
  ret

.set_hl
  ldi (hl), a
  dec b
  jr nz, set_hl
  ret

.set_hl_wide
  ldi (hl), a
  dec c
  jr nz, set_hl_wide
  dec b
  jr nz, set_hl_wide
  ret

<tile0.bin
<tile1.bin
<tile2.bin
<sprite.bin
<sine_path.bin
