;
; silclip.s — ARM assembly sprite silhouette clipping
;
; segloops eliminated: scale computed via linear accumulator.
;   acc = height * LeftScale (initial);  step = height * ScaleStep
;   per column: offset = acc >> ACC_SHIFT(22);  acc += step
;
; Clipbounds read directly from clipboundtop[]/clipboundbottom[].
; Read-before-write per column (within same iteration) is correct.
;
; ScreenHeight-1 = 159 inlined as ARM immediate (0x9F, encodable).
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT SegLoopSpriteClipsBottom
	EXPORT SegLoopSpriteClipsTop
	EXPORT SegLoopSpriteClipsBoth

	IMPORT clipboundbottom
	IMPORT clipboundtop

; viswall_t field offsets
VW_LEFTX		EQU 0
VW_RIGHTX		EQU 4
VW_WALLACTIONS	EQU 28
VW_FLOORNEWH	EQU 68
VW_CEILNEWH		EQU 76
VW_LEFTSCALE	EQU 92
VW_SCALESTEP	EQU 116
VW_TOPSIL		EQU 108
VW_BOTTOMSIL	EQU 112

; WallActions bits
AC_NEWCEILING	EQU 16
AC_NEWFLOOR		EQU 32
AC_TOPSIL		EQU 128
AC_BOTTOMSIL	EQU 256

ACC_SHIFT		EQU 22		; FIXEDTOSCALE(7) + HB_PLUS_SB(15)
SCREEN_H_M1		EQU 159		; MAXSCREENHEIGHT - 1 (ARM 8-bit immediate ✓)


;======================================================================
; void SegLoopSpriteClipsBottom(viswall_t *segl, Word screenCenterY)
;
; low = clamp(centerY - (floorNewAcc >> 22), 0, floorclipy)
; floorclipy read from clipboundbottom[x] (write there too if AC_NEWFLOOR)
;
; Registers (loop):
;   v1=floorAcc  v2=floorStep  v3=rightX  v4=BottomSil ptr  v5=clipboundbottom_base
;   a1=x  a2=centerY  a3/a4/ip=scratch
;======================================================================

SegLoopSpriteClipsBottom
	STMDB	sp!, {v1-v5, lr}

	LDR		a3, [a1, #VW_LEFTX]			; a3 = leftX
	LDR		v3, [a1, #VW_RIGHTX]
	LDR		v4, [a1, #VW_BOTTOMSIL]
	ADD		v4, v4, a3					; v4 = &BottomSil[leftX]

	LDR		a4, [a1, #VW_FLOORNEWH]		; a4 = floorNewH
	LDR		ip, [a1, #VW_LEFTSCALE]
	MUL		v1, a4, ip					; v1 = floorAcc  (Rd≠Rm ✓)
	LDR		ip, [a1, #VW_SCALESTEP]
	MUL		v2, a4, ip					; v2 = floorStep (Rd≠Rm ✓)

	LDR		v5, pClipBoundBot			; v5 = clipboundbottom base

	LDR		ip, [a1, #VW_WALLACTIONS]	; ip = ActionBits (dispatch)
	MOV		a1, a3						; a1 = x = leftX

	; Dispatch
	TST		ip, #AC_BOTTOMSIL
	BEQ		BotNewFloorOnly
	TST		ip, #AC_NEWFLOOR
	BEQ		BotSilOnlyLoop
	; Both: store to BottomSil AND update clipboundbottom

BotBothLoop
	LDR		ip, [v5, a1, LSL #2]		; ip = floorclipy = clipboundbottom[x]
	MOV		a4, v1, ASR #ACC_SHIFT		; a4 = low_offset (fills LDR latency)
	RSB		a4, a4, a2					; a4 = low = centerY - offset
	ADD		v1, v1, v2					; floorAcc += step  (ip ready: 3-inst gap ✓)
	CMP		a4, ip
	MOVGT	a4, ip						; clamp high
	CMP		a4, #0
	MOVLT	a4, #0
	STRB	a4, [v4], #1				; BottomSil[x] = low;  ptr++
	STR		a4, [v5, a1, LSL #2]		; clipboundbottom[x] = low  (write after read ✓)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotBothLoop
	LDMIA	sp!, {v1-v5, pc}

BotSilOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #ACC_SHIFT
	RSB		a4, a4, a2
	ADD		v1, v1, v2
	CMP		a4, ip
	MOVGT	a4, ip
	CMP		a4, #0
	MOVLT	a4, #0
	STRB	a4, [v4], #1
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotSilOnlyLoop
	LDMIA	sp!, {v1-v5, pc}

BotNewFloorOnly
	; v5 already = clipboundbottom base
BotNewFloorOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #ACC_SHIFT
	RSB		a4, a4, a2
	ADD		v1, v1, v2
	CMP		a4, ip
	MOVGT	a4, ip
	CMP		a4, #0
	MOVLT	a4, #0
	STR		a4, [v5, a1, LSL #2]		; clipboundbottom[x] = low  (read before write ✓)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotNewFloorOnlyLoop
	LDMIA	sp!, {v1-v5, pc}


;======================================================================
; void SegLoopSpriteClipsTop(viswall_t *segl, Word screenCenterY)
;
; high = clamp((centerY-1) - (ceilNewAcc >> 22), ceilingclipy, 159)
; ceilingclipy read from clipboundtop[x] (write there too if AC_NEWCEILING)
;
; Registers (loop):
;   v1=ceilAcc  v2=ceilStep  v3=rightX  v4=TopSil ptr  v5=clipboundtop_base
;   a1=x  a2=centerY-1  a3/a4/ip=scratch
;======================================================================

SegLoopSpriteClipsTop
	STMDB	sp!, {v1-v5, lr}

	LDR		a3, [a1, #VW_LEFTX]
	LDR		v3, [a1, #VW_RIGHTX]
	LDR		v4, [a1, #VW_TOPSIL]
	ADD		v4, v4, a3					; v4 = &TopSil[leftX]

	LDR		a4, [a1, #VW_CEILNEWH]		; a4 = ceilNewH
	LDR		ip, [a1, #VW_LEFTSCALE]
	MUL		v1, a4, ip					; v1 = ceilAcc  (Rd≠Rm ✓)
	LDR		ip, [a1, #VW_SCALESTEP]
	MUL		v2, a4, ip					; v2 = ceilStep (Rd≠Rm ✓)

	LDR		v5, pClipBoundTop			; v5 = clipboundtop base

	LDR		ip, [a1, #VW_WALLACTIONS]
	MOV		a1, a3

	SUB		a2, a2, #1					; a2 = centerY - 1

	TST		ip, #AC_TOPSIL
	BEQ		TopNewCeilOnly
	TST		ip, #AC_NEWCEILING
	BEQ		TopSilOnlyLoop

	; Both: store to TopSil AND update clipboundtop
TopBothLoop
	LDR		ip, [v5, a1, LSL #2]		; ip = ceilingclipy = clipboundtop[x]
	MOV		a4, v1, ASR #ACC_SHIFT		; a4 = high_offset
	RSB		a4, a4, a2					; a4 = (centerY-1) - offset  (ip ready: 3-inst gap ✓)
	ADD		v1, v1, v2					; ceilAcc += step
	CMP		a4, ip
	MOVLT	a4, ip						; clamp low to ceilingclipy
	CMP		a4, #SCREEN_H_M1			; clamp high to 159
	MOVGT	a4, #SCREEN_H_M1
	ADD		a3, a4, #1
	STRB	a3, [v4], #1				; TopSil[x] = high+1
	STR		a4, [v5, a1, LSL #2]		; clipboundtop[x] = high  (write after read ✓)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopBothLoop
	LDMIA	sp!, {v1-v5, pc}

TopSilOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #ACC_SHIFT
	RSB		a4, a4, a2
	ADD		v1, v1, v2
	CMP		a4, ip
	MOVLT	a4, ip
	CMP		a4, #SCREEN_H_M1
	MOVGT	a4, #SCREEN_H_M1
	ADD		a3, a4, #1
	STRB	a3, [v4], #1
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopSilOnlyLoop
	LDMIA	sp!, {v1-v5, pc}

TopNewCeilOnly
	; v5 already = clipboundtop base
TopNewCeilOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #ACC_SHIFT
	RSB		a4, a4, a2
	ADD		v1, v1, v2
	CMP		a4, ip
	MOVLT	a4, ip
	CMP		a4, #SCREEN_H_M1
	MOVGT	a4, #SCREEN_H_M1
	STR		a4, [v5, a1, LSL #2]		; clipboundtop[x] = high  (read before write ✓)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopNewCeilOnlyLoop
	LDMIA	sp!, {v1-v5, pc}


;======================================================================
; void SegLoopSpriteClipsBoth(viswall_t *segl, Word screenCenterY)
;
; Fused bottom+top pass when all four bits set:
;   AC_BOTTOMSIL | AC_NEWFLOOR | AC_TOPSIL | AC_NEWCEILING
;
; Registers (loop):
;   v1=floorAcc  v2=ceilAcc  v3=x  v4=rightX
;   v5=floorStep  v6=BottomSil ptr  v7=TopSil ptr  v8=ceilStep
;   a1=clipboundbottom base  a2=centerY  lr=clipboundtop base
;   a3/a4/ip=scratch per column
;
; ScreenHeight-1 = 159 (#SCREEN_H_M1) inlined — frees v8 for ceilStep.
; Eliminates redundant scale double-load from old segloops version.
;======================================================================

SegLoopSpriteClipsBoth
	STMDB	sp!, {v1-v8, lr}

	LDR		a3, [a1, #VW_FLOORNEWH]		; a3 = floorNewH
	LDR		a4, [a1, #VW_CEILNEWH]		; a4 = ceilNewH
	LDR		v4, [a1, #VW_RIGHTX]
	LDR		v6, [a1, #VW_BOTTOMSIL]
	LDR		v7, [a1, #VW_TOPSIL]
	LDR		v3, [a1, #VW_LEFTX]			; v3 = leftX (will become x)

	ADD		v6, v6, v3					; v6 = &BottomSil[leftX]
	ADD		v7, v7, v3					; v7 = &TopSil[leftX]

	; Compute accumulators
	LDR		ip, [a1, #VW_LEFTSCALE]
	MUL		v1, a3, ip					; v1 = floorAcc (Rd=v1 ≠ Rm=a3 ✓)
	MUL		v2, a4, ip					; v2 = ceilAcc  (Rd=v2 ≠ Rm=a4 ✓)
	LDR		ip, [a1, #VW_SCALESTEP]
	MUL		v5, a3, ip					; v5 = floorStep (Rd=v5 ≠ Rm=a3 ✓)
	MUL		v8, a4, ip					; v8 = ceilStep  (Rd=v8 ≠ Rm=a4 ✓)

	; Set up clip base pointers (done with segl)
	LDR		a1, pClipBoundBot			; a1 = clipboundbottom base
	LDR		lr, pClipBoundTop			; lr = clipboundtop base
	; a2 = centerY (arg, never overwritten), v3 = x = leftX

SilBothLoop
	; Load original clip bounds for this column
	LDR		a3, [a1, v3, LSL #2]		; a3 = floorclipy
	LDR		a4, [lr, v3, LSL #2]		; a4 = ceilingclipy  (1-inst gap for a3 ✓)

	; Bottom: low = clamp(centerY - (floorAcc >> 22), 0, floorclipy)
	MOV		ip, v1, ASR #ACC_SHIFT		; ip = low_offset
	RSB		ip, ip, a2					; ip = low = centerY - offset
	ADD		v1, v1, v5					; floorAcc += floorStep  (a3 ready: 4-inst gap ✓)
	CMP		ip, a3
	MOVGT	ip, a3						; clamp high to floorclipy
	CMP		ip, #0
	MOVLT	ip, #0
	STRB	ip, [v6], #1				; BottomSil[x] = low;  v6++
	STR		ip, [a1, v3, LSL #2]		; clipboundbottom[x] = low  (write after read ✓)

	; Top: high = clamp((centerY-1) - (ceilAcc >> 22), ceilingclipy, 159)
	MOV		a3, v2, ASR #ACC_SHIFT		; a3 = high_offset
	RSB		a3, a3, a2					; a3 = centerY - offset
	SUB		a3, a3, #1					; a3 = (centerY-1) - offset = high
	ADD		v2, v2, v8					; ceilAcc += ceilStep  (a4 ready: many insts ✓)
	CMP		a3, a4
	MOVLT	a3, a4						; clamp low to ceilingclipy
	CMP		a3, #SCREEN_H_M1
	MOVGT	a3, #SCREEN_H_M1
	ADD		a4, a3, #1
	STRB	a4, [v7], #1				; TopSil[x] = high+1;  v7++
	STR		a3, [lr, v3, LSL #2]		; clipboundtop[x] = high  (write after read ✓)

	ADD		v3, v3, #1					; x++
	CMP		v3, v4
	BLE		SilBothLoop

	LDMIA	sp!, {v1-v8, pc}


; === Literal pool ===
pClipBoundBot	DCD	clipboundbottom
pClipBoundTop	DCD	clipboundtop

	END
