;
; wallloop.s — ARM assembly inner loops for DrawWallSegment (textured walls)
;
; Replaces the C double-CCB and single-CCB inner loops in phase6_2.c.
; All 7 per-column CCB fields (XPos/YPos/HDY/PIXC/PRE0/PRE1/SourcePtr)
; are written in a single pass with explicit register allocation,
; eliminating armcc register spills and redundant expression recomputation.
;
; viscol_t: scale(int,4B)@0, column(Word/uint32,4B)@4, light(Word/uint32,4B)@8, size=12.
; column and light are loaded with separate LDRs at offsets 4 and 8.
;
; Calling convention (APCS 3/32/nofp):
;   void DrawWallInnerDouble_ASM(
;       viscol_t    *vc,           a1
;       BitmapCCB   *CCBPtr,       a2
;       int          xPos,         a3
;       int          xEnd,         a4
;       int          screenCenterY,[sp+0]  -> [sp+36] after STMDB {v1-v8,lr}
;       int          texTopHeight, [sp+4]  -> [sp+40]
;       Word         texWidth,     [sp+8]  -> [sp+44]
;       Word         texHeight,    [sp+12] -> [sp+48]
;       const Byte  *texBitmap,    [sp+16] -> [sp+52]
;       Word         colnumOffset, [sp+20] -> [sp+56]
;       LongWord     frac,         [sp+24] -> [sp+60]
;       int          pre0,         [sp+28] -> [sp+64]
;       int          pre1          [sp+32] -> [sp+68]
;   )
;
; Register map (inner loop):
;   a1 = vc          a2 = CCBPtr      a3/a4/ip/lr = scratch
;   v1 = xPos        v2 = xEnd        v3 = screenCenterY   v4 = texTopHeight
;   v5 = texWidth    v6 = texHeight   v7 = texBitmap       v8 = frac
;   colnumOffset, pre0, pre1 loaded from stack each iteration
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT	DrawWallInnerDouble_ASM
	EXPORT	DrawWallInner1x_ASM

; viscol_t field offsets (scale=0 [4 bytes], column=4 [4 bytes], light=8 [4 bytes], size=12)
; Word = unsigned int = 32-bit; all three fields are full words
VC_SCALE	EQU		0
VC_COL		EQU		4	; column (Word/uint32)
VC_LIGHT	EQU		8	; light  (Word/uint32)

; BitmapCCB field offsets
CCB_SRCPTR	EQU		8
CCB_XPOS	EQU		16
CCB_YPOS	EQU		20
CCB_HDY		EQU		28
CCB_PIXC	EQU		40
CCB_PRE0	EQU		44
CCB_PRE1	EQU		48
CCB_SIZE	EQU		52	; sizeof(BitmapCCB)
CCB2_OFF	EQU		52	; byte offset of the second CCB from the first

; Stack offsets for args 5-13, after STMDB sp!,{v1-v8,lr} (9 regs x 4 = 36 bytes pushed)
SP_CENTERY	EQU		36
SP_TOPHGT	EQU		40
SP_TEXWID	EQU		44
SP_TEXHGT	EQU		48
SP_BITMAP	EQU		52
SP_COLOFF	EQU		56
SP_FRAC		EQU		60
SP_PRE0		EQU		64
SP_PRE1		EQU		68

; HEIGHTBITS=6, SCALEBITS=9  ->  HEIGHTBITS+SCALEBITS=15,  20-SCALEBITS=11
SCALETOP_SHR	EQU		15	; (scale * texTopHeight) >> SCALETOP_SHR = offset from center
HDY_SHL		EQU		11	; scale << HDY_SHL = CCB HDY field value


;======================================================================
; DrawWallInnerDouble_ASM — 2x1 scaled path (screenScaleX=1)
;
; Emits two CCBs per logical column (at xPos*2 and xPos*2+1).
; Per-column instruction count: 42 instructions.
;======================================================================

DrawWallInnerDouble_ASM
	STMDB	sp!, {v1-v8, lr}

	; Move args from a3/a4 into saved regs before we clobber them
	MOV		v1, a3					; v1 = xPos
	MOV		v2, a4					; v2 = xEnd

	; Load all loop invariants into saved registers
	LDR		v3, [sp, #SP_CENTERY]	; v3 = screenCenterY
	LDR		v4, [sp, #SP_TOPHGT]	; v4 = texTopHeight
	LDR		v5, [sp, #SP_TEXWID]	; v5 = texWidth  (power-of-2 mask, e.g. 0x3F)
	LDR		v6, [sp, #SP_TEXHGT]	; v6 = texHeight (e.g. 64, 128)
	LDR		v7, [sp, #SP_BITMAP]	; v7 = texBitmap
	LDR		v8, [sp, #SP_FRAC]		; v8 = frac (0..127)

DblLoop
	; --- XPos: write both CCBs before loading from vc (frees a3 as scratch) ---
	; CCB1->XPos = (xPos*2)   << 16 = xPos << 17
	; CCB2->XPos = (xPos*2+1) << 16 = (xPos << 17) + (1<<16)
	MOV		a3, v1, LSL #17			; a3 = xPos << 17
	STR		a3, [a2, #CCB_XPOS]
	ADD		a3, a3, #0x10000		; a3 += 1<<16
	STR		a3, [a2, #CCB_XPOS + CCB2_OFF]

	; --- Load scale, column, light from vc ---
		; viscol_t: scale(int) @ 0, column(Word/uint32) @ 4, light(Word/uint32) @ 8
	LDR		a4, [a1, #VC_SCALE]		; a4 = scale
	LDR		a3, [a1, #VC_COL]		; a3 = column
	LDR		ip, [a1, #VC_LIGHT]		; ip = light

	; --- top = screenCenterY - ((scale * texTopHeight) >> 15) ---
	MUL		lr, a4, v4				; lr = scale * texTopHeight  [Rd=lr != Rm=a4 OK]
	MOV		lr, lr, ASR #SCALETOP_SHR
	RSB		lr, lr, v3				; lr = top = screenCenterY - (product>>15)

	; --- YPos = (top<<16) | 0xFF00  (write both CCBs) ---
	MOV		lr, lr, LSL #16
	ORR		lr, lr, #0xFF00			; lr = yval
	STR		lr, [a2, #CCB_YPOS]
	STR		lr, [a2, #CCB_YPOS + CCB2_OFF]

	; --- HDY = scale << 11  (write both CCBs) ---
	MOV		lr, a4, LSL #HDY_SHL	; lr = hdy (a4=scale still valid here)
	STR		lr, [a2, #CCB_HDY]
	STR		lr, [a2, #CCB_HDY + CCB2_OFF]

	; --- PIXC = light  (write both CCBs) ---
	STR		ip, [a2, #CCB_PIXC]
	STR		ip, [a2, #CCB_PIXC + CCB2_OFF]

	; --- PRE0 (load from stack, write both CCBs) ---
	LDR		lr, [sp, #SP_PRE0]
	STR		lr, [a2, #CCB_PRE0]
	STR		lr, [a2, #CCB_PRE0 + CCB2_OFF]

	; --- PRE1 (load from stack, write both CCBs) ---
	LDR		lr, [sp, #SP_PRE1]
	STR		lr, [a2, #CCB_PRE1]
	STR		lr, [a2, #CCB_PRE1 + CCB2_OFF]

	; --- colnum = (((column+colnumOffset) & texWidth) * texHeight + frac) >> 1 & ~3 ---
	; SourcePtr = texBitmap + colnum  (write both CCBs)
	LDR		ip, [sp, #SP_COLOFF]	; ip = colnumOffset
	ADD		a3, a3, ip				; a3 = column + colnumOffset
	AND		a3, a3, v5				; a3 &= texWidth
	MUL		ip, a3, v6				; ip = adj_col * texHeight  [Rd=ip != Rm=a3 OK]
	ADD		ip, ip, v8				; ip += frac
	MOV		ip, ip, LSR #1
	BIC		ip, ip, #3				; ip = colnum
	ADD		ip, v7, ip				; ip = texBitmap + colnum
	STR		ip, [a2, #CCB_SRCPTR]
	STR		ip, [a2, #CCB_SRCPTR + CCB2_OFF]

	; --- Advance ---
	ADD		a1, a1, #12				; vc++ (sizeof viscol_t = 12)
	ADD		a2, a2, #104			; CCBPtr += 2 * sizeof(BitmapCCB) = 2*52
	ADD		v1, v1, #1				; xPos++
	CMP		v1, v2
	BLE		DblLoop

	LDMIA	sp!, {v1-v8, pc}


;======================================================================
; DrawWallInner1x_ASM — 1x1 path (screenScaleX=0)
;
; Emits one CCB per logical column at xPos.
; Per-column instruction count: 32 instructions.
;======================================================================

DrawWallInner1x_ASM
	STMDB	sp!, {v1-v8, lr}

	MOV		v1, a3					; v1 = xPos
	MOV		v2, a4					; v2 = xEnd

	LDR		v3, [sp, #SP_CENTERY]
	LDR		v4, [sp, #SP_TOPHGT]
	LDR		v5, [sp, #SP_TEXWID]
	LDR		v6, [sp, #SP_TEXHGT]
	LDR		v7, [sp, #SP_BITMAP]
	LDR		v8, [sp, #SP_FRAC]

Sgl1xLoop
	; XPos = xPos << 16
	MOV		a3, v1, LSL #16
	STR		a3, [a2, #CCB_XPOS]

	; Load scale, column, light
	LDR		a4, [a1, #VC_SCALE]
	LDR		a3, [a1, #VC_COL]		; a3 = column
	LDR		ip, [a1, #VC_LIGHT]		; ip = light

	; top
	MUL		lr, a4, v4				; [Rd=lr != Rm=a4 OK]
	MOV		lr, lr, ASR #SCALETOP_SHR
	RSB		lr, lr, v3				; lr = top

	; YPos
	MOV		lr, lr, LSL #16
	ORR		lr, lr, #0xFF00
	STR		lr, [a2, #CCB_YPOS]

	; HDY
	MOV		lr, a4, LSL #HDY_SHL
	STR		lr, [a2, #CCB_HDY]

	; PIXC
	STR		ip, [a2, #CCB_PIXC]

	; PRE0, PRE1
	LDR		lr, [sp, #SP_PRE0]
	STR		lr, [a2, #CCB_PRE0]
	LDR		lr, [sp, #SP_PRE1]
	STR		lr, [a2, #CCB_PRE1]

	; colnum, SourcePtr
	LDR		ip, [sp, #SP_COLOFF]
	ADD		a3, a3, ip
	AND		a3, a3, v5
	MUL		ip, a3, v6				; [Rd=ip != Rm=a3 OK]
	ADD		ip, ip, v8
	MOV		ip, ip, LSR #1
	BIC		ip, ip, #3
	ADD		ip, v7, ip
	STR		ip, [a2, #CCB_SRCPTR]

	; Advance
	ADD		a1, a1, #12				; vc++ (sizeof viscol_t = 12)
	ADD		a2, a2, #52				; CCBPtr++
	ADD		v1, v1, #1				; xPos++
	CMP		v1, v2
	BLE		Sgl1xLoop

	LDMIA	sp!, {v1-v8, pc}

	END
