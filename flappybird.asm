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
  ld a, $00
  ldh ($40), a

  ; setup palettes
  ld a, $e4
  ldh ($47), a
  ldh ($48), a
  ldh ($49), a

  ; set up scxy
  xor a
  ldh ($42), a ; REG_SCY
  ldh ($43), a ; REG_SCX

  ; init variables
  ldh ($80), a ; keys_held
  ldh ($81), a ; keys_down
  ldh ($82), a ; game_state
  ldh ($90), a ; bird_v (positive = down)
  ldh ($f0), a ; rng_state
  ldh ($f1), a ; rng_state_1
  ldh ($f2), a ; rng_state_2
  ldh ($f3), a ; rng_state_3
  ldh ($f4), a ; is_vblank
  ld a, $20
  ldh ($e0), a ; next_col_offset (cycles $20,$28,$30,$38)

  ; copy tile data
  ld hl, $8000
  ld de, data_tile0_bin
  ld b, $40
  call cp_de_to_hl

  ; copy more tile data
  ld hl, $9000
  ld de, data_tile1_bin
  ld b, $20
  call cp_de_to_hl

  ; clear map0
  ld hl, $9800
  ld bc, $0400
  xor a
.l2
  ldi (hl), a
  dec c
  jr nz, l2
  dec b
  jr nz, l2

  ; clear sprites
  ld hl, $fe00
  ld b, $a0
.l4
  ldi (hl), a
  dec b
  jr nz, l4

  ; init bird sprite
  ld hl, $fe00
  ld a, 88
  ldi (hl), a
  ld a, 84
  ldi (hl), a
  xor a
  ldi (hl), a
  ld (hl), a

  ; enable display
  ld a, $83
  ldh ($40), a
  ; enable interrupts
  ld a, $11 ; INT_KEYS, INT_VBLANK
  ldh ($ff), a
  ei

.loop
  call read_keys
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
  ldh a, ($81) ; keys_down
  bit 0, a
  ret z        ; return if ((keys_down & KEY_A) == 0)
  ld a, 1
  ldh ($82), a ; game_state = 1
  ret
.update_state_1 ; play
  call handle_jump
  call scroll_screen
  ret

.scroll_screen
  ldh a, ($43) ; REG_SCX
  inc a
  ldh ($43), a
  and $3f
  ret nz       ; return if REG_SCX % 40 != 0
  ldh a, ($e0) ; next_col_offset
  ld l, a
  add a, $08
  cp $40
  jr nz, l16
  ld a, $20
.l16
  ldh ($e0), a
  ld h, $9a
  call populate_map
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
  ld hl, $fe00 ; sprite[0].y
  ld a, (hl)
  add a, b     ; sprite[0].y + v/8
  cp 16
  jr nc, l9    ; if (y < 16) {
  xor a
  ldh ($90), a ;   v = 0
  ld a, 16     ;   y = 16
  jr l8        ; }
.l9
  cp 152       ; else if (y >= 152) {
  jr c, l8
  xor a
  ldh ($90), a ;   v = 0
  ld a, 152    ;   y = 152
.l8            ; }
  ld (hl), a
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

.populate_map ; hl = source, (9a20..9a3f)
.l15
  call rng_next
  and $0f
  cp 11
  jr nc, l15
  add a, 7
  ld c, a      ; start of gap
  ld de, $ffe0 ; -20
  ld b, 18
.l13
  ld a, 1
  ld (hl), a
  add hl, de
  ld a, b
  cp c
  jr nz, l14
  sub a, 3     ; extra dec b at the end
  ld b, a
  xor a
  ld (hl), a
  add hl, de
  ld (hl), a
  add hl, de
  ld (hl), a
  add hl, de
  ld (hl), a
  add hl, de
.l14
  dec b
  jr nz, l13
  ret

.cp_de_to_hl
  ld a, (de)
  ldi (hl), a
  inc de
  dec b
  jr nz, cp_de_to_hl
  ret

<tile0.bin
<tile1.bin
