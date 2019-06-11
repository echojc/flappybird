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

.wait_for_vblank
  ldh a, ($44)
  cp $94
  jr nz, wait_for_vblank

  ; disable display
  xor a
  ldh ($40), a

  ; set up scxy
  ldh ($42), a ; REG_SCY
  ldh ($43), a ; REG_SCX

  ; init variables
  ldh ($80), a ; keys_held
  ldh ($81), a ; keys_down
  ldh ($82), a ; game_state
  ldh ($90), a ; bird_v (positive = down)
  ldh ($c0), a ; score_bcd_lo
  ldh ($c1), a ; score_bcd_hi
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

  ; clear map0
  xor a
  ld hl, $9800
  ld bc, $0400
  call set_hl_wide

  ; clear sprites
  ld hl, $fe00
  ld b, $a0
  call set_hl

  ; init ground
  ld a, $0b ; ground sprite
  ld hl, $9a20
  ld b, $20
  call set_hl

  ; init bird sprites
  ld hl, $fe00
  ld de, data_sprite_bin
  ld b, $14
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
  call scroll_screen
  ldh a, ($81) ; keys_down
  bit 0, a
  ret z        ; return if ((keys_down & KEY_A) == 0)
  ld a, 1
  ldh ($82), a ; game_state = 1
  call handle_jump ; start the game with a hop
  ret
.update_state_1 ; play
  call scroll_screen
  call handle_scroll
  call handle_jump
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
  cp $20
  jr z, handle_scroll_draw
  cp $3a
  jr z, handle_scroll_score
  ret
.handle_scroll_draw ; draw wall is expensive, we render on a frame without collision detection
  ldh a, ($e0)   ; next_col_offset
  add a, $18     ; draw 3 walls ahead (= 1 behind)
  and $1f
  ld l, a
  ld h, $9a      ; hl = bottom left tile of 3 walls ahead
  call draw_wall
  ret
.handle_scroll_score
  ldh a, ($e0)   ; next_col_offset
  ld l, a
  ld h, $98      ; hl = top left tile of next wall
  ld a, (hl)
  and a
  ret z          ; return if there is no wall (tile is blank)
  ldh a, ($c0)   ; score_bcd
  inc a
  daa
  ldh ($c0), a
  ret nc
  ccf
  ldh a, ($c1)
  inc a
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
  jr l8        ; }
.l9
  cp 138       ; else if (y >= 138) {
  jr c, l8
  xor a
  ldh ($90), a ;   v = 0
  ld a, 138    ;   y = 138
.l8            ; }
  ld ($fe00), a
  ld ($fe04), a
  add a, 8
  ld ($fe08), a
  ld ($fe0c), a
  sub a, 3
  ld ($fe10), a
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
.l15
  call rng_next
  and $0f
  cp 10
  jr nc, l15   ; a ∈ [0..9]
  ld d, a      ; d = tiles to draw before gap
  ld a, 17
  sub a, d
  sub a, 8
  ld b, a      ; b = tiles to draw after gap
  ld c, 3      ; c = 1 xor 2 (flipper)
  push bc

  ld a, d      ;
  ld de, $ffdf ; -0x21 = 1 row + 1 tile
  and a
  jr z, l1     ; skip if tiles to draw before = 0

  ld b, a      ; b = tiles to draw before gap
  ld a, 1      ; wall tiles = {1, 2}
.l13
  ldi (hl), a
  xor c
  ld (hl), a
  xor c
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

  pop bc       ; b = tiles to draw after gap, c = 1 xor 2 (flipper)
  ld a, b
  and a
  ret z        ; return if tiles to draw after == 0
  ld a, 1
.l14
  ldi (hl), a
  xor c
  ld (hl), a
  xor c
  add hl, de
  dec b
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
