;
; silclip.s — ARM assembly sprite silhouette clipping
;
; segloops eliminated: scale computed per-column from linear scalefrac accumulator.
;   scalefrac starts at LeftScale, increments by ScaleStep per column.
;   scale = min(scalefrac >> 7, 0x1FFF)   (matches original clamp)
;   offset = (scale * height) >> 15
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

SCREEN_H_M1		EQU 159		; MAXSCREENHEIGHT - 1 (ARM 8-bit immediate)


;======================================================================
; void SegLoopSpriteClipsBottom(viswall_t *segl, Word screenCenterY)
;
; low = clamp(centerY - ((min(scalefrac>>7,0x1FFF)*floorNewH)>>15), 0, floorclipy)
;
; Registers (loop):
;   v1=scalefrac  v2=scalestep  v3=rightX  v4=BottomSil ptr  v5=clipboundbottom_base
;   a1=x  a2=centerY  lr=floorNewH  a3/a4/ip=scratch
;======================================================================

SegLoopSpriteClipsBottom
	STMDB	sp!, {v1-v5, lr}

	LDR		a3, [a1, #VW_LEFTX]
	LDR		v3, [a1, #VW_RIGHTX]
	LDR		v4, [a1, #VW_BOTTOMSIL]
	ADD		v4, v4, a3					; v4 = &BottomSil[leftX]

	LDR		lr, [a1, #VW_FLOORNEWH]		; lr = floorNewH (persists in loop)
	LDR		v1, [a1, #VW_LEFTSCALE]		; v1 = scalefrac
	LDR		v2, [a1, #VW_SCALESTEP]		; v2 = scalestep

	LDR		v5, pClipBoundBot

	LDR		ip, [a1, #VW_WALLACTIONS]
	MOV		a1, a3						; a1 = x = leftX

	; Dispatch
	TST		ip, #AC_BOTTOMSIL
	BEQ		BotNewFloorOnly
	TST		ip, #AC_NEWFLOOR
	BEQ		BotSilOnlyLoop
	; Both: store to BottomSil AND update clipboundbottom

BotBothLoop
	LDR		ip, [v5, a1, LSL #2]		; ip = floorclipy
	MOV		a4, v1, ASR #7				; scale = scalefrac >> 7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1					; clamp to 0x1FFF
	MUL		a3, a4, lr					; a3 = scale*floorNewH (Rd=a3 != Rm=a4)
	MOV		a4, a3, ASR #15				; offset = (scale*h) >> 15
	RSB		a4, a4, a2					; low = centerY - offset
	ADD		v1, v1, v2					; scalefrac += step  (ip from LDR: many-inst gap)
	CMP		a4, ip
	MOVGT	a4, ip						; clamp high
	CMP		a4, #0
	MOVLT	a4, #0
	STRB	a4, [v4], #1				; BottomSil[x] = low;  ptr++
	STR		a4, [v5, a1, LSL #2]		; clipboundbottom[x] = low  (write after read)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotBothLoop
	LDMIA	sp!, {v1-v5, pc}

BotSilOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1
	MUL		a3, a4, lr
	MOV		a4, a3, ASR #15
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
BotNewFloorOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1
	MUL		a3, a4, lr
	MOV		a4, a3, ASR #15
	RSB		a4, a4, a2
	ADD		v1, v1, v2
	CMP		a4, ip
	MOVGT	a4, ip
	CMP		a4, #0
	MOVLT	a4, #0
	STR		a4, [v5, a1, LSL #2]		; clipboundbottom[x] = low  (read before write)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		BotNewFloorOnlyLoop
	LDMIA	sp!, {v1-v5, pc}


;======================================================================
; void SegLoopSpriteClipsTop(viswall_t *segl, Word screenCenterY)
;
; high = clamp((centerY-1) - ((min(scalefrac>>7,0x1FFF)*ceilNewH)>>15), ceilingclipy, 159)
;
; Registers (loop):
;   v1=scalefrac  v2=scalestep  v3=rightX  v4=TopSil ptr  v5=clipboundtop_base
;   a1=x  a2=centerY-1  lr=ceilNewH  a3/a4/ip=scratch
;======================================================================

SegLoopSpriteClipsTop
	STMDB	sp!, {v1-v5, lr}

	LDR		a3, [a1, #VW_LEFTX]
	LDR		v3, [a1, #VW_RIGHTX]
	LDR		v4, [a1, #VW_TOPSIL]
	ADD		v4, v4, a3

	LDR		lr, [a1, #VW_CEILNEWH]		; lr = ceilNewH
	LDR		v1, [a1, #VW_LEFTSCALE]
	LDR		v2, [a1, #VW_SCALESTEP]

	LDR		v5, pClipBoundTop

	LDR		ip, [a1, #VW_WALLACTIONS]
	MOV		a1, a3

	SUB		a2, a2, #1					; a2 = centerY - 1

	TST		ip, #AC_TOPSIL
	BEQ		TopNewCeilOnly
	TST		ip, #AC_NEWCEILING
	BEQ		TopSilOnlyLoop

	; Both: store to TopSil AND update clipboundtop
TopBothLoop
	LDR		ip, [v5, a1, LSL #2]		; ip = ceilingclipy
	MOV		a4, v1, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1
	MUL		a3, a4, lr					; a3 = scale*ceilNewH (Rd=a3 != Rm=a4)
	MOV		a4, a3, ASR #15
	RSB		a4, a4, a2					; high = (centerY-1) - offset
	ADD		v1, v1, v2					; scalefrac += step
	CMP		a4, ip
	MOVLT	a4, ip						; clamp low to ceilingclipy
	CMP		a4, #SCREEN_H_M1
	MOVGT	a4, #SCREEN_H_M1
	ADD		a3, a4, #1
	STRB	a3, [v4], #1				; TopSil[x] = high+1
	STR		a4, [v5, a1, LSL #2]		; clipboundtop[x] = high  (write after read)
	ADD		a1, a1, #1
	CMP		a1, v3
	BLE		TopBothLoop
	LDMIA	sp!, {v1-v5, pc}

TopSilOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1
	MUL		a3, a4, lr
	MOV		a4, a3, ASR #15
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
TopNewCeilOnlyLoop
	LDR		ip, [v5, a1, LSL #2]
	MOV		a4, v1, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1
	MUL		a3, a4, lr
	MOV		a4, a3, ASR #15
	RSB		a4, a4, a2
	ADD		v1, v1, v2
	CMP		a4, ip
	MOVLT	a4, ip
	CMP		a4, #SCREEN_H_M1
	MOVGT	a4, #SCREEN_H_M1
	STR		a4, [v5, a1, LSL #2]		; clipboundtop[x] = high  (read before write)
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
;   v1=scalefrac  v2=scalestep  v3=x  v4=rightX
;   v5=floorNewH  v6=BottomSil ptr  v7=TopSil ptr  v8=ceilNewH
;   a1=clipboundbottom base  a2=centerY  lr=clipboundtop base
;   a3/a4/ip=scratch per column
;======================================================================

SegLoopSpriteClipsBoth
	STMDB	sp!, {v1-v8, lr}

	LDR		v5, [a1, #VW_FLOORNEWH]		; v5 = floorNewH
	LDR		v8, [a1, #VW_CEILNEWH]		; v8 = ceilNewH
	LDR		v4, [a1, #VW_RIGHTX]
	LDR		v6, [a1, #VW_BOTTOMSIL]
	LDR		v7, [a1, #VW_TOPSIL]
	LDR		v3, [a1, #VW_LEFTX]

	ADD		v6, v6, v3
	ADD		v7, v7, v3

	LDR		v1, [a1, #VW_LEFTSCALE]		; v1 = scalefrac
	LDR		v2, [a1, #VW_SCALESTEP]		; v2 = scalestep

	; Set up clip base pointers (done with segl)
	LDR		a1, pClipBoundBot
	LDR		lr, pClipBoundTop
	; a2 = centerY (arg, never overwritten), v3 = x = leftX

SilBothLoop
	; Compute clamped scale (common for floor + ceil)
	MOV		ip, v1, ASR #7				; scale = scalefrac >> 7
	CMP		ip, #0x2000
	MOVGE	ip, #0x2000
	SUBGE	ip, ip, #1					; clamp to 0x1FFF

	; --- Bottom: low = clamp(centerY - (scale*floorNewH>>15), 0, floorclipy) ---
	LDR		a3, [a1, v3, LSL #2]		; a3 = floorclipy
	MUL		a4, ip, v5					; a4 = scale*floorNewH (Rd=a4 != Rm=ip)
	MOV		a4, a4, ASR #15
	RSB		a4, a4, a2					; low = centerY - offset
	CMP		a4, a3						; (a3 from LDR: 3-inst gap)
	MOVGT	a4, a3
	CMP		a4, #0
	MOVLT	a4, #0
	STRB	a4, [v6], #1
	STR		a4, [a1, v3, LSL #2]		; clipboundbottom[x] = low  (write after read)

	; --- Top: high = clamp((centerY-1) - (scale*ceilNewH>>15), ceilingclipy, 159) ---
	LDR		a4, [lr, v3, LSL #2]		; a4 = ceilingclipy
	MUL		a3, ip, v8					; a3 = scale*ceilNewH (Rd=a3 != Rm=ip)
	MOV		a3, a3, ASR #15
	RSB		a3, a3, a2
	SUB		a3, a3, #1					; high = (centerY-1) - offset
	CMP		a3, a4						; (a4 from LDR: 4-inst gap)
	MOVLT	a3, a4
	CMP		a3, #SCREEN_H_M1
	MOVGT	a3, #SCREEN_H_M1
	ADD		a4, a3, #1
	STRB	a4, [v7], #1
	STR		a3, [lr, v3, LSL #2]		; clipboundtop[x] = high  (write after read)

	ADD		v1, v1, v2					; scalefrac += scalestep
	ADD		v3, v3, #1
	CMP		v3, v4
	BLE		SilBothLoop

	LDMIA	sp!, {v1-v8, pc}


; === Literal pool ===
pClipBoundBot	DCD	clipboundbottom
pClipBoundTop	DCD	clipboundtop

	END
