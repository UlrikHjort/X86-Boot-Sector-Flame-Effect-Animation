; *************************************************************************** 
;     Boot sector flame effect — x86 real mode, VGA mode 13h (320x200x256)   
;
;            Copyright (C) 2026 By Ulrik Hørlyk Hjort
;
; Permission is hereby granted, free of charge, to any person obtaining
; a copy of this software and associated documentation files (the
; "Software"), to deal in the Software without restriction, including
; without limitation the rights to use, copy, modify, merge, publish,
; distribute, sublicense, and/or sell copies of the Software, and to
; permit persons to whom the Software is furnished to do so, subject to
; the following conditions:
;
; The above copyright notice and this permission notice shall be
; included in all copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
; LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
; OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
; WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
; ***************************************************************************   
	
; Compile:  nasm -f bin -o flame.bin flame.asm
; Run:      qemu-system-i386 -L /usr/local/share/qemu flame.bin
								; 
;   Algorithm: 
;   each pixel = avg(4 neighbours in row below) − cooling
;   bottom row is continuously reseeded with pseudo-random heat
								;
	
BITS 16
ORG 0x7C00

    xor  ax, ax
    mov  ds, ax
    mov  ss, ax
    mov  sp, 0x7C00

    ; VGA mode 13h: 320×200, 256 colors
    mov  ax, 0x0013
    int  0x10

    ; ── Color palette: black → red → orange → yellow → white ─────────────────
    ;  R = saturate(cl,       0, 63)
    ;  G = saturate(cl − 64,  0, 63)
    ;  B = saturate(cl − 192, 0, 63)
    xor  al, al
    mov  dx, 0x3C8
    out  dx, al             ; begin DAC writes at color 0
    inc  dx                 ; dx = 0x3C9 (data port)
    xor  cl, cl             ; color index 0..255
.pal:
    ; R
    mov  al, cl
    cmp  al, 63
    jbe  .r_ok
    mov  al, 63
.r_ok:
    out  dx, al

    ; G = saturate(cl − 64, 0, 63)
    mov  al, cl
    sub  al, 64             ; carry set if cl < 64
    jnc  .g_pos
    xor  al, al
    jmp  .g_out
.g_pos:
    cmp  al, 63
    jbe  .g_out
    mov  al, 63
.g_out:
    out  dx, al

    ; B = saturate(cl − 192, 0, 63)
    mov  al, cl
    sub  al, 192
    jnc  .b_pos
    xor  al, al
    jmp  .b_out
.b_pos:
    cmp  al, 63
    jbe  .b_out
    mov  al, 63
.b_out:
    out  dx, al

    inc  cl
    jnz  .pal               ; loop 256 times (wraps 255→0)

    ; ES = VGA framebuffer (A000:0000)
    mov  ax, 0xA000
    mov  es, ax

    ; Clear screen to black (main loop will seed the bottom row each frame)
    xor  di, di
    mov  cx, 64000
    xor  al, al
    rep  stosb

    mov  bp, 0xACE1         ; seed 16-bit Galois LFSR (any non-zero value)

; ── Main loop ─────────────────────────────────────────────────────────────────
.frame:

    ; ── Step 1: spread fire upward through rows 0..198 ───────────────────────
    ;  pixel[y][x] = ( pixel[y+1][x−1] + pixel[y+1][x]
    ;                + pixel[y+1][x+1] + pixel[y+2][x] ) / 4  − 2
    xor  di, di             ; DI = offset 0 (row 0, x=0)
    mov  si, 199            ; SI = row counter (rows 0..198)

.yfire:
    xor  cx, cx             ; CX = x = 0

.xfire:
    mov  al, [es:di + 319]  ; (y+1, x−1)
    xor  ah, ah
    mov  bl, [es:di + 320]  ; (y+1, x)
    xor  bh, bh
    add  ax, bx
    mov  bl, [es:di + 321]  ; (y+1, x+1)
    add  ax, bx
    mov  bl, [es:di + 640]  ; (y+2, x)
    add  ax, bx
    shr  ax, 2              ; ÷ 4

    ; cool by 2, clamp to 0
    sub  al, 2
    jnc  .no_cool
    xor  al, al
.no_cool:
    mov  [es:di], al
    inc  di

    inc  cx
    cmp  cx, 320
    jb   .xfire

    dec  si
    jnz  .yfire

    ; ── Step 2: reseed bottom row — two-zone seeding for tapered flame ────────
    ;  Total hot zone: CL 128..191  (64 px centred on x=160)
    ;    Inner ring  144..175  (32 px): 87.5 % hot  → tall, hot core
    ;    Outer ring  128..143 + 176..191: 50 % hot  → sparse edges, fade lower
    ;  Outside zone: always cold  →  flame naturally narrows as it rises
    mov  di, 63680
    xor  cx, cx

.seed:
    shr  bp, 1
    jnc  .lf
    xor  bp, 0xB400
.lf:
    xor  al, al             ; default: cold
    cmp  cl, 128
    jb   .plant             ; x < 128 → cold
    cmp  cl, 192
    jae  .plant             ; x ≥ 192 (CL wrap catches x=256..319 too) → cold

    ; decide inner vs outer ring
    cmp  cl, 144
    jb   .outer             ; left outer ring (128..143)
    cmp  cl, 176
    jae  .outer             ; right outer ring (176..191)

    ; inner ring: 1-in-8 cold  (87.5 % hot)
    test bp, 7
    jz   .plant
    jmp  .hot

.outer:
    ; outer ring: 1-in-2 cold  (50 % hot)
    test bp, 1
    jz   .plant
.hot:
    mov  al, 255
.plant:
    mov  [es:di], al
    inc  di

    inc  cx
    cmp  cx, 320
    jb   .seed

    ; ── Frame delay (tune BX: higher = slower) ───────────────────────────────
    mov  bx, 140            ; 140 × 65536 ≈ 9 M iterations
.dly:
    xor  cx, cx
.dly2:
    loop .dly2
    dec  bx
    jnz  .dly

    jmp  .frame

    times 510-($-$$) db 0
    dw 0xAA55
