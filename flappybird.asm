.rst_00
  add a, a
  ld e, a
  ld d, $00
  pop hl
  add hl, de
  jp hl

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
  ldh ($83), a ; is_pause_scroll
  ldh ($90), a ; bird_v (positive = down)
  ldh ($92), a ; bird_menu_path_counter
  ldh ($c0), a ; score_bcd_lo
  ldh ($c1), a ; score_bcd_hi
  ldh ($c2), a ; is_score_updated
  ldh ($d1), a ; snd_bgm_offset
  ldh ($e1), a ; col_position[0]
  ldh ($e2), a ; col_position[1]
  ldh ($e3), a ; col_position[2]
  ldh ($e4), a ; col_position[3]
  ldh ($e5), a ; is_collided
  ldh ($f0), a ; rng_state
  ldh ($f1), a ; rng_state_1
  ldh ($f2), a ; rng_state_2
  ldh ($f3), a ; rng_state_3
  ldh ($f4), a ; is_vblank
  ld a, 5
  ldh ($91), a ; bird_anim_counter
  ld a, $08
  ldh ($d0), a ; snd_counter
  ldh ($e0), a ; next_col_offset (cycles $00,$08,$10,$18)

  ; setup palettes
  ld a, $e4
  ldh ($47), a ; REG_BGP  3_2_1_0
  ldh ($48), a ; REG_OBP0 3_2_1_0
  ld a, $c4
  ldh ($49), a ; REG_OBP1 3_0_1_0

  ; setup sound
  ;ld a, $80
  xor a
  ldh ($26), a ; REG_NR52
  ;ld a, $ff
  ;ldh ($25), a ; REG_NR51
  ;ld a, $77
  ;ldh ($24), a ; REG_NR50

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
  ld b, $90
  call cp_de_to_hl

  ; copy dma to hram
  ld hl, $fff5
  ld de, sprite_dma!
  ld b, $0a
  call cp_de_to_hl

  ; init ground
  ld a, $0b ; ground sprite
  ld hl, $9a20
  ld b, $20
  call set_hl

  ; init sprites
  ld hl, $c000
  ld de, data_sprite_bin
  ld b, $40
  call cp_de_to_hl

  ; init sound channel
  ;ld a, $a2
  ;ldh ($16), a ; REG_NR21
  ;ld a, $f0
  ;ldh ($17), a ; REG_NR22

  ; enable display
  ld a, $83
  ldh ($40), a
  ; enable interrupts
  ld a, $11 ; INT_KEYS, INT_VBLANK
  ldh ($ff), a
  ei
  jr halt   ; wait for next vblank before starting the game proper

.loop
  call $fff5           ; sprite_dma!
  call scroll_screen!  ; disabled by ($83)
  call draw_next_pipe! ; if needed

  call read_keys
  call run_state
  ;call snd_play
.halt
  halt
  ldh a, ($f4) ; is_vblank
  and a
  jr z, halt
  xor a
  ldh ($f4), a ; is_vblank
  jr loop

.run_state
  ldh a, ($82) ; game_state
  rst $00
  jr update_menu
  jr update_play
  jr update_debug
  jr update_gameover
.update_menu
  call animate_sine_path
  call animate_wing
  call check_start_game
  ret
.update_play
  call animate_wing
  call handle_score
  call handle_jump
  call render_score
  call check_collision
  call handle_collision
  call check_debug
  ret
.update_debug
  call handle_keys_debug
  call check_collision
  ret
.update_gameover
  call handle_gravity
  ret

.scroll_screen!
  ldh a, ($83) ; is_pause_scroll
  and a
  ret nz
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

.check_start_game
  ldh a, ($81) ; keys_down
  bit 0, a
  ret z        ; return if ((keys_down & KEY_A) == 0)
  ld a, 1
  ldh ($82), a ; game_state = 1
  ldh ($c2), a ; is_score_updated = true
  call render_score
  call force_jump ; start the game with a hop
  ret

.check_debug
  ldh a, ($81) ; keys_down
  cp $04       ; KEY_SELECT
  ret nz
  ld a, 2
  ldh ($82), a ; game_state = 2
  ldh ($83), a ; is_pause_scroll = true
  ret

.handle_score
  ldh a, ($43)   ; REG_SCX
  and $3f
  cp $09
  ret nz
  ldh a, ($e0)   ; next_col_offset
  ld l, a
  ld h, $98      ; hl = top left tile of next pipe
  ld a, (hl)
  and a
  ret z          ; return if there is no pipe (tile is blank)
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
  bit 0, a     ; if (keys_down & KEY_A) {
  jr z, handle_gravity
.force_jump
  ld a, $f3    ;   v = -13
  jr l11       ; } else {
.handle_gravity
  ldh a, ($90)
  inc a        ;   v += 1
.l11           ; }
  ldh ($90), a
  ld b, a
  sra b
  sra b
  sra b ; use v/8
  ld a, ($c000); sprite[0].y
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
  ld ($c000), a
  ld ($c004), a
  add a, 8
  ld ($c008), a
  ld ($c00c), a
  sub a, 3
  ld ($c010), a
  ret

.render_score
  ldh a, ($c2)
  and a
  ret z        ; return if (!is_score_updated)
  xor a
  ldh ($c2), a
  ld c, a
  ld hl, $c022 ; &sprite[8].tile
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

.check_collision
  ldh a, ($43)  ; REG_SCX
  add a, 6      ; map $3a -> $00 (mod $40)
  and $3f
  cp $1d
  jp nc, check_collision_reset ; if REG_SCX ∉ [$3a..$16]

  ld b, a
  ldh a, ($e0)  ; next_col_offset
  ld l, a
  ld h, $98     ; hl = top left tile of next pipe
  ld a, (hl)
  and a
  jp z, check_collision_reset  ; if there is no pipe (tile is blank)

  ldh a, ($e0)  ; next_col_offset
  srl a
  srl a
  srl a
  add a, $e1
  ld c, a
  ldh a, (c)    ; col_position[next_col_offset >> 3]
  rlca
  rlca
  rlca          ; base_y = col_position[next_col_offset >> 3] << 3
  ld c, a       ; base_y

  ld a, b       ; collision check column
  and a
  jr z, check_collision_edge_1
  cp $01
  jr z, check_collision_edge_2
  sub a, 2      ; [$3c..$16] mapped to [$00..$1c]
  add a, a
  ld e, a
  ld d, $00
  ld hl, data_collision_bin
  add hl, de    ; hl = &{ u8 lower_inc, u8 upper_exc }

  ld a, ($c000) ; bird_y
  sub a, c      ; bird_y - base_y
  cp (hl)
  jr c, check_collision_set
  inc hl
  cp (hl)
  jr nc, check_collision_set
  jr check_collision_reset
.check_collision_edge_1 ; [2..3,2a..2b]
  ld a, ($c000) ; bird_y
  sub a, c      ; bird_y - base_y
  sub a, $02    ; check case [2..3]
  cp 2
  jr c, check_collision_set
  sub a, $28    ; check case [2a..2b]
  cp 2
  jr c, check_collision_set
  jr check_collision_reset
.check_collision_edge_2 ; [0..4,28-2d]
  ld a, ($c000) ; bird_y
  sub a, c      ; bird_y - base_y
  cp 5          ; check case [0..4]
  jr c, check_collision_set
  sub a, $28    ; check case [28..2d]
  cp 6
  jr c, check_collision_set
  jr check_collision_reset
.check_collision_set
  ld a, 1
  ldh ($e5), a  ; is_collided = true
  ret
.check_collision_reset
  xor a
  ldh ($e5), a  ; is_collided = false
  ret

.handle_collision
  ldh a, ($e5)  ; is_collided
  and a
  ret z
  ld a, 3
  ldh ($82), a ; game_state = 3
  ldh ($83), a ; is_pause_scroll = true
  call force_jump

  ld hl, $c002 ; flip bird sprite
  ld a, $86
  ldi (hl), a
  ld a, $40
  ldi (hl), a
  inc l
  inc l
  ld a, $87
  ldi (hl), a
  ld a, $40
  ldi (hl), a
  inc l
  inc l
  ld a, $84
  ldi (hl), a
  ld a, $50
  ldi (hl), a
  inc l
  inc l
  ld a, $88    ; and set to dead face
  ldi (hl), a
  ld a, $50
  ldi (hl), a
  inc l
  inc l
  inc l
  ld (hl), a
  ret

.handle_keys_debug
  ldh a, ($81) ; keys_down
  ld c, a
  bit 6, c     ; KEY_UP
  jr z, l20
  ld a, ($c000)
  dec a
  call update_bird_y
.l20
  bit 7, c     ; KEY_DOWN
  jr z, l21
  ld a, ($c000)
  inc a
  call update_bird_y
.l21
  bit 4, c     ; KEY_RIGHT
  jr z, l22
  ldh a, ($43)
  inc a
  ldh ($43), a
.l22
  bit 5, c     ; KEY_LEFT
  jr z, l23
  ldh a, ($43)
  dec a
  ldh ($43), a
.l23
  bit 0, c     ; KEY_A
  jr z, l24
  ld a, ($c012); sprite[4].tile
  inc a        ; a ∈ [80..83]
  and $83      ; mask
  ld ($c012), a
.l24
  bit 2, c
  ret z
  ld a, 1
  ldh ($82), a ; game_state = 1
  xor a
  ldh ($83), a ; is_pause_scroll = false
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

.draw_next_pipe!
  ldh a, ($82) ; game_state
  cp 1
  ret c

  ldh a, ($43) ; REG_SCX
  and $3f      ; switch (REG_SCX % 0x40)
  cp $28
  ret nz

  call rng_next
  and $0f
  ld e, a
  ld d, $00
  ld hl, data_pipe_rng_mapping_bin
  add hl, de
  ld a, (hl)   ; a ∈ [0..9]
  ld d, a      ; d = tiles before gap
  cpl          ; a = -d - 1
  add a, 10    ; a = 10 - d - 1 = 9 - d = (17 - 8) - d
  ld e, a      ; e = tiles after gap

  ldh a, ($e0) ; next_col_offset
  add a, $10   ; draw 2 pipes ahead
  and $1f
  ld l, a
  ld h, $9a    ; hl = bottom left tile of pipe

  srl a        ; save position of gap
  srl a
  srl a
  add a, $e1
  ld c, a      ; c = &col_position[next_col_offset >> 3]
  ld a, e
  add a, 2
  ldh (c), a   ; col_position[next_col_offset >> 3] = tiles on top of gap

  ld bc, $ffdf ; -0x21 = 1 row + 1 tile
  ld a, d
  and a
  jr z, l1     ; skip if d (tiles before gap) == 0

  ; bottom pipe
  ld a, 1
.l13
  ldi (hl), a
  inc a
  ld (hl), a
  dec a
  add hl, bc
  dec d
  jr nz, l13

  ; top of bottom pipe
.l1
  ld a, 3
  ldi (hl), a
  inc a
  ld (hl), a
  inc a
  add hl, bc
  ldi (hl), a
  inc a
  ld (hl), a
  add hl, bc

  ; 4-row gap
  xor a
  ldi (hl), a
  ld (hl), a
  add hl, bc
  ldi (hl), a
  ld (hl), a
  add hl, bc
  ldi (hl), a
  ld (hl), a
  add hl, bc
  ldi (hl), a
  ld (hl), a
  add hl, bc

  ; bottom of top pipe
  ld a, 7
  ldi (hl), a
  inc a
  ld (hl), a
  inc a
  add hl, bc
  ldi (hl), a
  inc a
  ld (hl), a
  add hl, bc

  ; top pipe
  ld a, e
  and a
  ret z        ; skip if e (tiles after gap) == 0
  ld a, 1
.l14
  ldi (hl), a
  inc a
  ld (hl), a
  dec a
  add hl, bc
  dec e
  jr nz, l14
  ret

.animate_wing
  ldh a, ($91) ; bird_anim_counter
  dec a
  jr nz, l3
  ld a, ($c012) ; sprite[4].tile
  inc a         ; a ∈ [80..83]
  and $83       ; mask
  ld ($c012), a
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
  ld a, ($c000) ; sprite[0].y
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

.sprite_dma!
  ld a, $c0 ; $c000[00..9f] is sprite data
  ldh ($46), a
  ld a, 40
.l2
  dec a
  jr nz l2
  ret

.snd_play
  ldh a, ($d0) ; snd_counter
  dec a
  jr nz, l0

  ldh a, ($d1) ; snd_bgm_offset
  ld e, a
  ld d, $00
  ld hl, data_bgm_bin
  add hl, de
  inc a
  ldh ($d1), a ; snd_bgm_offset++

  ld a, (hl)   ; next note
  and a
  jr z, l7     ; rest if note is 0

  add a, a
  ld e, a
  ld d, $00
  ld hl, data_notes_bin
  add hl, de
  ldi a, (hl)  ; note_lo
  ldh ($18), a
  ld a, (hl)   ; note_hi
  or $c0       ; SND_TRIGGER | SND_LENGTH
  ldh ($19), a

.l7
  ld a, 8
.l0
  ldh ($d0), a
  ret

<tile0.bin
<tile1.bin
<tile2.bin
<sprite.bin
<sine_path.bin
<pipe_rng_mapping.bin
<collision.bin
<notes.bin
<bgm.bin
