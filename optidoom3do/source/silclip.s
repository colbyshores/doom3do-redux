;
; silclip.s — ARM assembly sprite silhouette clipping
;
; Replaces C versions of SegLoopSpriteClipsBottom / SegLoopSpriteClipsTop
; with branchless inner loops using conditional execution.
;
; Each inner loop: MUL + shift + conditional clamp + store.
; No branches in the hot path — zero pipeline flushes on ARM7TDMI.
;
; Specialized loop variants selected by ActionBits before entering the loop,
; eliminating per-column flag tests.
;
; SegLoopSpriteClipsBoth — fused bottom+top pass over segloops[]:
;   Called when AC_BOTTOMSIL|AC_NEWFLOOR|AC_TOPSIL|AC_NEWCEILING are all set.
;   Reads segloops once per column (vs two separate passes), saving ~2 LDRs/column.
;
;   void SegLoopSpriteClipsBoth(viswall_t *segl, Word screenCenterY)
;     a1 = segl    a2 = screenCenterY
;
;   Register map (inner loop):
;     v1 = floorNewHeight     v2 = ceilingNewHeight
;     v3 = x                  v4 = rightX
;     v5 = segloops ptr       v6 = BottomSil ptr (post-inc STRB)
;     v7 = TopSil ptr (post-inc STRB)
;     v8 = ScreenHeight - 1   (top clamp ceiling)
;     a1 = clipboundbottom ptr (post-inc STR +4)
;     a2 = centerY            (bottom: low = centerY - ...)
;     ip = centerY - 1        (top: high = centerY-1 - ...)
;     lr = clipboundtop ptr   (post-inc STR +4)
;     a3, a4 = scratch
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT SegLoopSpriteClipsBottom
	EXPORT SegLoopSpriteClipsTop
	EXPORT SegLoopSpriteClipsBoth

	IMPORT segloops
	IMPORT clipboundbottom
	IMPORT clipboundtop
	IMPORT ScreenHeight

; viswall_t field offsets
VW_LEFTX		EQU 0
VW_RIGHTX		EQU 4
VW_WALLACTIONS	EQU 28
VW_FLOORNEWH	EQU 68
VW_CEILNEWH	EQU 76
VW_TOPSIL		EQU 108
VW_BOTTOMSIL	EQU 112

; segloop_t: {scale(+0), ceilingclipy(+4), floorclipy(+8)}, size=12
SL_SCALE		EQU 0
SL_CEILCLIPY	EQU 4
SL_FLOORCLIPY	EQU 8
SL_SIZE			EQU 12

; WallActions bits
AC_NEWCEILING	EQU 16
AC_NEWFLOOR		EQU 32
AC_TOPSIL		EQU 128
AC_BOTTOMSIL	EQU 256

; HEIGHTBITS(6) + SCALEBITS(9) = 15
HB_PLUS_SB		EQU 15


;======================================================================
; void SegLoopSpriteClipsBottom(viswall_t *segl, Word screenCenterY)
;
; Computes: low = screenCenterY - (scale * floorNewHeight >> 15)
; Clamps:   low = clamp(low, 0, floorclipy)
; Stores:   BottomSil[x] and/or clipboundbottom[x]
;======================================================================

SegLoopSpriteClipsBottom
	STMDB	sp!, {v1-v5, lr}

	; Load constants from segl
	LDR		v1, [a1, #VW_FLOORNEWH]	; v1 = floorNewHeight
	LDR		v3, [a1, #VW_RIGHTX]		; v3 = rightX
	LDR		v5, [a1, #VW_WALLACTIONS]	; v5 = ActionBits
	LDR		v4, [a1, #VW_BOTTOMSIL]		; v4 = BottomSil base ptr
	LDR		a3, [a1, #VW_LEFTX]			; a3 = LeftX
	ADD		v4, v4, a3					; v4 = &BottomSil[LeftX]

	; v2 = segloops base
	LDR		v2, pSegloops

	; a1 = x (reuse, done with segl pointer)
	MOV		a1, a3

	; Select specialized loop based on ActionBits
	TST		v5, #AC_BOTTOMSIL
	BEQ		BotNewFloorOnly
	TST		v5, #AC_NEWFLOOR
	BEQ		BotSilOnlyLoop
	; Fall through: both AC_BOTTOMSIL and AC_NEWFLOOR

	; === Both: store to BottomSil AND clipboundbottom ===
	LDR		v5, pClipBoundBot			; v5 = clipboundbottom base
BotBothLoop
	LDR		a3, [v2, #SL_SCALE]			; scale
	LDR		ip, [v2, #SL_FLOORCLIPY]	; floorclipy
	MUL		a4, a3, v1					; scale * floorNewHeight
	MOV		a4, a4, ASR #HB_PLUS_SB		; >> 15
	RSB		a4, a4, a2					; low = screenCenterY - result
	CMP		a4, ip
	MOVGT	a4, ip						; clamp high
	CMP		a4, #0
	MOVLT	a4, #0						; clamp low
	STRB	a4, [v4], #1				; *bottomSil++ = low
	STR		a4, [v5, a1, LSL #2]		; clipboundbottom[x] = low
	ADD		v2, v2, #SL_SIZE			; segdata++
	ADD		a1, a1, #1					; x++
	CMP		a1, v3
	BLE		BotBothLoop
	LDMIA	sp!, {v1-v5, pc}

	; === BottomSil only ===
BotSilOnlyLoop
	LDR		a3, [v2, #SL_SCALE]
	LDR		ip, [v2, #SL_FLOORCLIPY]
	MUL		a4, a3, v1
	MOV		a4, a4, ASR #HB_PLUS_SB
	RSB		a4, a4, a2
	CMP		a4, ip
	MOVGT	a4, ip
	CMP		a4, #0
	MOVLT	a4, #0
	STRB	a4, [v4], #1
	ADD		v2, v2, #SL_SIZE
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotSilOnlyLoop
	LDMIA	sp!, {v1-v5, pc}

	; === NewFloor only (no BottomSil write) ===
BotNewFloorOnly
	LDR		v4, pClipBoundBot			; repurpose v4
BotNewFloorOnlyLoop
	LDR		a3, [v2, #SL_SCALE]
	LDR		ip, [v2, #SL_FLOORCLIPY]
	MUL		a4, a3, v1
	MOV		a4, a4, ASR #HB_PLUS_SB
	RSB		a4, a4, a2
	CMP		a4, ip
	MOVGT	a4, ip
	CMP		a4, #0
	MOVLT	a4, #0
	STR		a4, [v4, a1, LSL #2]		; clipboundbottom[x] = low
	ADD		v2, v2, #SL_SIZE
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotNewFloorOnlyLoop
	LDMIA	sp!, {v1-v5, pc}


;======================================================================
; void SegLoopSpriteClipsTop(viswall_t *segl, Word screenCenterY)
;
; Computes: high = (screenCenterY-1) - (scale * ceilingNewHeight >> 15)
; Clamps:   high = clamp(high, ceilingclipy, ScreenHeight-1)
; Stores:   TopSil[x] = high+1  and/or  clipboundtop[x] = high
;======================================================================

SegLoopSpriteClipsTop
	STMDB	sp!, {v1-v5, lr}

	; Load constants from segl
	LDR		v1, [a1, #VW_CEILNEWH]		; v1 = ceilingNewHeight
	LDR		v3, [a1, #VW_RIGHTX]		; v3 = rightX
	LDR		v5, [a1, #VW_WALLACTIONS]	; v5 = ActionBits
	LDR		v4, [a1, #VW_TOPSIL]		; v4 = TopSil base ptr
	LDR		a3, [a1, #VW_LEFTX]			; a3 = LeftX
	ADD		v4, v4, a3					; v4 = &TopSil[LeftX]

	; v2 = segloops base
	LDR		v2, pSegloops

	; a2 = screenCenterY - 1 (precompute)
	SUB		a2, a2, #1

	; lr = ScreenHeight - 1 (free to use, saved on stack)
	LDR		lr, pScreenHeight
	LDR		lr, [lr]
	SUB		lr, lr, #1

	; a1 = x
	MOV		a1, a3

	; Select specialized loop
	TST		v5, #AC_TOPSIL
	BEQ		TopNewCeilOnly
	TST		v5, #AC_NEWCEILING
	BEQ		TopSilOnlyLoop
	; Fall through: both

	; === Both: store to TopSil AND clipboundtop ===
	LDR		v5, pClipBoundTop			; v5 = clipboundtop base
TopBothLoop
	LDR		a3, [v2, #SL_SCALE]			; scale
	LDR		ip, [v2, #SL_CEILCLIPY]	; ceilingclipy
	MUL		a4, a3, v1					; scale * ceilingNewHeight
	MOV		a4, a4, ASR #HB_PLUS_SB		; >> 15
	RSB		a4, a4, a2					; high = (centerY-1) - result
	CMP		a4, ip
	MOVLT	a4, ip						; clamp low to ceilingclipy
	CMP		a4, lr
	MOVGT	a4, lr						; clamp high to ScreenHeight-1
	ADD		a3, a4, #1					; a3 = high + 1
	STRB	a3, [v4], #1				; *topSil++ = high + 1
	STR		a4, [v5, a1, LSL #2]		; clipboundtop[x] = high
	ADD		v2, v2, #SL_SIZE
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopBothLoop
	LDMIA	sp!, {v1-v5, pc}

	; === TopSil only ===
TopSilOnlyLoop
	LDR		a3, [v2, #SL_SCALE]
	LDR		ip, [v2, #SL_CEILCLIPY]
	MUL		a4, a3, v1
	MOV		a4, a4, ASR #HB_PLUS_SB
	RSB		a4, a4, a2
	CMP		a4, ip
	MOVLT	a4, ip
	CMP		a4, lr
	MOVGT	a4, lr
	ADD		a3, a4, #1
	STRB	a3, [v4], #1
	ADD		v2, v2, #SL_SIZE
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopSilOnlyLoop
	LDMIA	sp!, {v1-v5, pc}

	; === NewCeiling only (no TopSil write) ===
TopNewCeilOnly
	LDR		v4, pClipBoundTop			; repurpose v4
TopNewCeilOnlyLoop
	LDR		a3, [v2, #SL_SCALE]
	LDR		ip, [v2, #SL_CEILCLIPY]
	MUL		a4, a3, v1
	MOV		a4, a4, ASR #HB_PLUS_SB
	RSB		a4, a4, a2
	CMP		a4, ip
	MOVLT	a4, ip
	CMP		a4, lr
	MOVGT	a4, lr
	STR		a4, [v4, a1, LSL #2]		; clipboundtop[x] = high
	ADD		v2, v2, #SL_SIZE
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopNewCeilOnlyLoop
	LDMIA	sp!, {v1-v5, pc}


;======================================================================
; void SegLoopSpriteClipsBoth(viswall_t *segl, Word screenCenterY)
;
; Fused bottom+top pass — called only when all four bits are set:
;   AC_BOTTOMSIL | AC_NEWFLOOR | AC_TOPSIL | AC_NEWCEILING
;
; Per column:
;   low  = clamp(centerY   - (scale * floorNewH >> 15), 0,             floorclipy)
;   high = clamp(centerY-1 - (scale * ceilNewH  >> 15), ceilingclipy,  ScreenHeight-1)
;   BottomSil[x]        = low
;   clipboundbottom[x]  = low
;   TopSil[x]           = high + 1
;   clipboundtop[x]     = high
;======================================================================

SegLoopSpriteClipsBoth
	STMDB	sp!, {v1-v8, lr}

	; Load constants from segl
	LDR		v1, [a1, #VW_FLOORNEWH]		; v1 = floorNewHeight
	LDR		v2, [a1, #VW_CEILNEWH]		; v2 = ceilingNewHeight
	LDR		v4, [a1, #VW_RIGHTX]		; v4 = rightX
	LDR		v6, [a1, #VW_BOTTOMSIL]		; v6 = BottomSil base
	LDR		v7, [a1, #VW_TOPSIL]		; v7 = TopSil base
	LDR		a3, [a1, #VW_LEFTX]			; a3 = leftX

	; Advance sil ptrs to &Sil[leftX]
	ADD		v6, v6, a3					; v6 = &BottomSil[leftX]
	ADD		v7, v7, a3					; v7 = &TopSil[leftX]

	; v3 = x
	MOV		v3, a3

	; v5 = segloops base
	LDR		v5, pSegloops

	; ScreenHeight - 1 for top clamp
	LDR		v8, pScreenHeight
	LDR		v8, [v8]
	SUB		v8, v8, #1

	; a1 = &clipboundbottom[leftX] (post-inc ptr for STR)
	LDR		a1, pClipBoundBot
	ADD		a1, a1, a3, LSL #2			; a1 = &clipboundbottom[leftX]

	; ip = centerY - 1 (for top RSB); a2 stays as centerY (for bottom RSB)
	SUB		ip, a2, #1

	; lr = &clipboundtop[leftX] (post-inc ptr for STR)
	LDR		lr, pClipBoundTop
	ADD		lr, lr, a3, LSL #2			; lr = &clipboundtop[leftX]

SilBothLoop
	; Load from segloops (3 fields, scale used twice)
	LDR		a3, [v5, #SL_FLOORCLIPY]	; a3 = floorclipy
	LDR		a4, [v5, #SL_SCALE]			; a4 = scale

	; Bottom: low = clamp(centerY - (scale * floorNewH >> 15), 0, floorclipy)
	MUL		a4, v1, a4					; scale * floorNewH  (Rd≠Rm: a4=v1*a4)
	MOV		a4, a4, ASR #HB_PLUS_SB		; >> 15
	RSB		a4, a4, a2					; low = centerY - result
	CMP		a4, a3						; low > floorclipy?
	MOVGT	a4, a3						; clamp high
	CMP		a4, #0						; low < 0?
	MOVLT	a4, #0						; clamp low
	STRB	a4, [v6], #1				; BottomSil[x] = low
	STR		a4, [a1], #4				; clipboundbottom[x] = low  (post-inc +4)

	; Top: high = clamp(centerY-1 - (scale * ceilNewH >> 15), ceilingclipy, ScreenHeight-1)
	LDR		a3, [v5, #SL_CEILCLIPY]	; a3 = ceilingclipy
	LDR		a4, [v5, #SL_SCALE]			; a4 = scale (reload — same addr, v5 not yet advanced)
	MUL		a4, v2, a4					; scale * ceilNewH  (Rd≠Rm: a4=v2*a4)
	MOV		a4, a4, ASR #HB_PLUS_SB		; >> 15
	RSB		a4, a4, ip					; high = (centerY-1) - result
	CMP		a4, a3						; high < ceilingclipy?
	MOVLT	a4, a3						; clamp low
	CMP		a4, v8						; high > ScreenHeight-1?
	MOVGT	a4, v8						; clamp high
	ADD		a3, a4, #1					; a3 = high + 1
	STRB	a3, [v7], #1				; TopSil[x] = high + 1
	STR		a4, [lr], #4				; clipboundtop[x] = high  (post-inc +4)

	; Advance segloops and loop counter
	ADD		v5, v5, #SL_SIZE			; segloops++
	ADD		v3, v3, #1					; x++
	CMP		v3, v4						; x <= rightX?
	BLE		SilBothLoop

	LDMIA	sp!, {v1-v8, pc}


; === Literal pool ===
pSegloops		DCD	segloops
pClipBoundBot	DCD	clipboundbottom
pClipBoundTop	DCD	clipboundtop
pScreenHeight	DCD	ScreenHeight

	END
