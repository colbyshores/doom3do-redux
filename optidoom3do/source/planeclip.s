;
; planeclip.s — ARM assembly floor/ceiling visplane column filling
;
; Replaces SegLoopFloor / SegLoopCeiling inner loops.
; Per-column: MUL + conditional clamp + open[] write + miny/maxy update.
; FindPlane called via BL on the rare path (open[x] != OPENMARK).
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT SegLoopFloor_ASM
	EXPORT SegLoopCeiling_ASM

	IMPORT segloops
	IMPORT FindPlane

; viswall_t field offsets
VW_LEFTX		EQU 0
VW_RIGHTX		EQU 4
VW_FLOORHEIGHT	EQU 64
VW_CEILHEIGHT	EQU 72

; segloop_t: {scale(+0), ceilingclipy(+4), floorclipy(+8)}, size=12

; visplane_t: open[281] at +0, miny at +1160, maxy at +1164
VP_MINY			EQU 1160
VP_MAXY			EQU 1164

; Constants
OPENMARK		EQU 0x9F00		; ((MAXSCREENHEIGHT-1) << 8) = (159 << 8)
HB_PLUS_SB		EQU 15			; HEIGHTBITS(6) + SCALEBITS(9)


;======================================================================
; void SegLoopFloor_ASM(viswall_t *segl, Word screenCenterY,
;                       visplane_t *plane, Word color)
;
; a1=segl, a2=screenCenterY, a3=plane, a4=color
;======================================================================

SegLoopFloor_ASM
	STMDB	sp!, {v1-v5, lr}
	SUB		sp, sp, #8				; frame: [sp+0]=segl, [sp+4]=color

	STR		a1, [sp, #0]			; save segl
	STR		a4, [sp, #4]			; save color

	; Load loop constants
	LDR		v3, [a1, #VW_FLOORHEIGHT]	; v3 = floorHeight
	LDR		a4, [a1, #VW_RIGHTX]		; a4 = rightX (temporary)
	LDR		a1, [a1, #VW_LEFTX]		; a1 = x = LeftX (reuse reg)

	MOV		v2, a2					; v2 = screenCenterY
	MOV		a2, a4					; a2 = rightX
	MOV		v4, a3					; v4 = FloorPlane
	MOV		v1, #OPENMARK			; v1 = 0x9F00
	LDR		v5, pSegloops			; v5 = segloops base

FloorLoop
	LDR		a3, [v5, #0]			; scale = segdata->scale
	LDR		ip, [v5, #4]			; ceilingclipy

	; top = screenCenterY - (scale * floorHeight >> 15)
	MUL		a4, a3, v3				; scale * floorHeight
	MOV		a4, a4, ASR #HB_PLUS_SB
	RSB		a4, a4, v2				; top = screenCenterY - result

	; Clamp: if top <= ceilingclipy, top = ceilingclipy + 1
	CMP		a4, ip
	ADDLE	a4, ip, #1

	; bottom = floorclipy - 1
	LDR		ip, [v5, #8]			; floorclipy
	SUB		ip, ip, #1				; bottom = floorclipy - 1

	; if top > bottom, skip this column
	CMP		a4, ip
	BGT		FloorSkip

	; Check open[x] — if != OPENMARK, need FindPlane
	LDR		a3, [v4, a1, LSL #2]	; FloorPlane->open[x]
	CMP		a3, v1					; == OPENMARK?
	BNE		FloorNeedFind

FloorStore
	; if (top) --top
	CMP		a4, #0
	SUBNE	a4, a4, #1

	; open[x] = (top << 8) + bottom
	ORR		a3, ip, a4, LSL #8
	STR		a3, [v4, a1, LSL #2]

	; Update miny: if (miny > top) miny = top
	LDR		a3, [v4, #VP_MINY]
	CMP		a3, a4
	STRGT	a4, [v4, #VP_MINY]

	; Update maxy: if (maxy < bottom) maxy = bottom
	LDR		a3, [v4, #VP_MAXY]
	CMP		a3, ip
	STRLT	ip, [v4, #VP_MAXY]

FloorSkip
	ADD		v5, v5, #12				; segdata++
	ADD		a1, a1, #1				; x++
	CMP		a1, a2					; x <= rightX?
	BLE		FloorLoop

FloorDone
	ADD		sp, sp, #8				; pop frame
	LDMIA	sp!, {v1-v5, pc}

FloorNeedFind
	; Rare path: call FindPlane(FloorPlane, segl, x, color)
	; Save caller-saved loop regs we need after the call
	STMDB	sp!, {a1, a2, a4, ip}	; x, rightX, top, bottom
	MOV		a1, v4					; check = FloorPlane
	LDR		a2, [sp, #16]			; segl (past 4 pushed = +16)
	LDR		a3, [sp, #0]			; x (first pushed)
	LDR		a4, [sp, #20]			; color (past 4 pushed = +20)
	BL		FindPlane
	MOV		v4, a1					; FloorPlane = result
	LDMIA	sp!, {a1, a2, a4, ip}	; restore x, rightX, top, bottom
	CMP		v4, #0
	BEQ		FloorDone				; FindPlane failed
	B		FloorStore


;======================================================================
; void SegLoopCeiling_ASM(viswall_t *segl, Word screenCenterY,
;                         visplane_t *plane, Word color)
;
; a1=segl, a2=screenCenterY, a3=plane, a4=color
;======================================================================

SegLoopCeiling_ASM
	STMDB	sp!, {v1-v5, lr}
	SUB		sp, sp, #8				; frame: [sp+0]=segl, [sp+4]=color

	STR		a1, [sp, #0]			; save segl
	STR		a4, [sp, #4]			; save color

	; Load loop constants
	LDR		v3, [a1, #VW_CEILHEIGHT]	; v3 = ceilingHeight
	LDR		a4, [a1, #VW_RIGHTX]
	LDR		a1, [a1, #VW_LEFTX]		; a1 = x

	SUB		v2, a2, #1				; v2 = screenCenterY - 1
	MOV		a2, a4					; a2 = rightX
	MOV		v4, a3					; v4 = CeilingPlane
	MOV		v1, #OPENMARK			; v1 = 0x9F00
	LDR		v5, pSegloops			; v5 = segloops base

CeilLoop
	LDR		a3, [v5, #0]			; scale

	; bottom = (screenCenterY-1) - (scale * ceilingHeight >> 15)
	MUL		a4, a3, v3
	MOV		a4, a4, ASR #HB_PLUS_SB
	RSB		a4, a4, v2				; a4 = bottom

	; top = ceilingclipy + 1
	LDR		ip, [v5, #4]			; ceilingclipy
	ADD		ip, ip, #1				; ip = top = ceilingclipy + 1

	; Clamp bottom: if bottom >= floorclipy, bottom = floorclipy - 1
	LDR		a3, [v5, #8]			; floorclipy
	CMP		a4, a3
	SUBGE	a4, a3, #1

	; if top > bottom, skip
	CMP		ip, a4
	BGT		CeilSkip

	; Check open[x]
	LDR		a3, [v4, a1, LSL #2]	; CeilingPlane->open[x]
	CMP		a3, v1
	BNE		CeilNeedFind

CeilStore
	; if (top) --top     (top is in ip)
	CMP		ip, #0
	SUBNE	ip, ip, #1

	; open[x] = (top << 8) + bottom     (top=ip, bottom=a4)
	ORR		a3, a4, ip, LSL #8
	STR		a3, [v4, a1, LSL #2]

	; Update miny: if (miny > top) miny = top
	LDR		a3, [v4, #VP_MINY]
	CMP		a3, ip
	STRGT	ip, [v4, #VP_MINY]

	; Update maxy: if (maxy < bottom) maxy = bottom
	LDR		a3, [v4, #VP_MAXY]
	CMP		a3, a4
	STRLT	a4, [v4, #VP_MAXY]

CeilSkip
	ADD		v5, v5, #12				; segdata++
	ADD		a1, a1, #1				; x++
	CMP		a1, a2					; x <= rightX?
	BLE		CeilLoop

CeilDone
	ADD		sp, sp, #8				; pop frame
	LDMIA	sp!, {v1-v5, pc}

CeilNeedFind
	; Save loop regs, call FindPlane
	STMDB	sp!, {a1, a2, a4, ip}	; x, rightX, bottom, top
	MOV		a1, v4					; check = CeilingPlane
	LDR		a2, [sp, #16]			; segl
	LDR		a3, [sp, #0]			; x
	LDR		a4, [sp, #20]			; color
	BL		FindPlane
	MOV		v4, a1					; CeilingPlane = result
	LDMIA	sp!, {a1, a2, a4, ip}	; restore x, rightX, bottom, top
	CMP		v4, #0
	BEQ		CeilDone
	B		CeilStore


; === Literal pool ===
pSegloops		DCD	segloops

	END
