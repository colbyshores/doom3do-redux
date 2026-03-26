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
	EXPORT SegLoopFloorCeiling_ASM

	IMPORT segloops
	IMPORT FindPlane
	IMPORT isFloor

; viswall_t field offsets
VW_LEFTX		EQU 0
VW_RIGHTX		EQU 4
VW_FLOORPIC		EQU 8
VW_CEILPIC		EQU 12
VW_FLATFLOORIDX	EQU 16
VW_FLATCEILIDX	EQU 20
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


;======================================================================
; void SegLoopFloorCeiling_ASM(viswall_t *segl, Word screenCenterY,
;                               visplane_t *floorPlane, Word floorColor,
;                               visplane_t *ceilPlane,  Word ceilColor)
;
; a1=segl  a2=screenCenterY  a3=floorPlane  a4=floorColor
; arg5=ceilPlane [sp+0] arg6=ceilColor [sp+4]  (pushed by caller)
;
; After prologue (STMDB 36 + SUB 32 = 68 bytes below caller sp):
;   [sp+0..31]: local frame
;   [sp+32..67]: v1-v8,lr
;   [sp+68]: ceilPlane    [sp+72]: ceilColor
;
; Local frame layout (32 bytes):
;   [sp+0]  = segl          [sp+4]  = floorColor
;   [sp+8]  = ceil_save_floorheight    (scratch for ceil FindPlane rare path)
;   [sp+12] = ceil_save_FloorPic
;   [sp+16] = ceil_save_flatFloorIdx
;   [sp+20..31] = padding
;
; Register map (loop body):
;   v1 = OPENMARK        v2 = screenCenterY
;   v3 = floorHeight     v4 = FloorPlane ptr
;   v5 = CeilPlane ptr   v6 = ceilHeight
;   v7 = segloops ptr    v8 = x
;   a2 = rightX (constant)
;   lr = ceilingclipy save (per-column; free between columns)
;   a1, a3, a4, ip = scratch per column
;
; Hot path saves 3 LDRs per column vs two separate passes (6 segloops LDRs → 3).
;======================================================================

SegLoopFloorCeiling_ASM
	STMDB	sp!, {v1-v8, lr}		; 36 bytes
	SUB		sp, sp, #32				; 32-byte local frame

	STR		a1, [sp, #0]			; [sp+0]  = segl
	STR		a4, [sp, #4]			; [sp+4]  = floorColor

	LDR		v3, [a1, #VW_FLOORHEIGHT]	; v3 = floorHeight
	LDR		v6, [a1, #VW_CEILHEIGHT]	; v6 = ceilHeight
	LDR		a4, [a1, #VW_RIGHTX]		; a4 = rightX (temp)
	LDR		v8, [a1, #VW_LEFTX]		; v8 = x = leftX

	MOV		v2, a2					; v2 = screenCenterY
	MOV		a2, a4					; a2 = rightX
	MOV		v4, a3					; v4 = FloorPlane
	LDR		v5, [sp, #68]			; v5 = CeilPlane (arg5 after prologue)
	MOV		v1, #OPENMARK			; v1 = 0x9F00
	LDR		v7, pSegloops			; v7 = segloops base

FCBoth_Loop
	; Load segloops (3 LDRs — once for both floor and ceiling)
	LDR		a1, [v7, #0]			; a1 = scale
	LDR		a3, [v7, #4]			; a3 = ceilingclipy
	LDR		a4, [v7, #8]			; a4 = floorclipy
	MOV		lr, a3					; lr = ceilingclipy saved for ceiling section

	; ===== FLOOR SECTION =====
	; top_f = screenCenterY - (scale * floorH >> 15)
	MUL		a3, v3, a1				; a3 = floorH * scale  (Rd≠Rm: a3 ≠ v3)
	MOV		a3, a3, ASR #HB_PLUS_SB
	RSB		a3, a3, v2				; a3 = floor_top

	; Clamp: if top_f <= ceilingclipy: top_f = ceilingclipy + 1
	CMP		a3, lr
	ADDLE	a3, lr, #1

	; floor_bottom = floorclipy - 1
	SUB		a4, a4, #1				; a4 = floor_bottom  (floorclipy consumed)

	; Skip floor if top > bottom
	CMP		a3, a4
	BGT		FCBoth_CeilSection

	; Check open[x]
	LDR		ip, [v4, v8, LSL #2]	; ip = FloorPlane->open[x]
	CMP		ip, v1
	BNE		FCBoth_FloorNeedFind

FCBoth_FloorStore
	CMP		a3, #0
	SUBNE	a3, a3, #1				; if top_f != 0: top_f--
	ORR		ip, a4, a3, LSL #8		; pack open[x]
	STR		ip, [v4, v8, LSL #2]
	LDR		ip, [v4, #VP_MINY]
	CMP		ip, a3
	STRGT	a3, [v4, #VP_MINY]
	LDR		ip, [v4, #VP_MAXY]
	CMP		ip, a4
	STRLT	a4, [v4, #VP_MAXY]

	; FALL THROUGH to ceiling section

FCBoth_CeilSection
	; ===== CEILING SECTION =====
	; bottom_c = (centerY - 1) - (scale * ceilH >> 15)
	;          = centerY - (scale*ceilH>>15) - 1
	MUL		a3, v6, a1				; a3 = ceilH * scale  (a1=scale preserved; Rd≠Rm: a3 ≠ v6)
	MOV		a3, a3, ASR #HB_PLUS_SB
	RSB		a3, a3, v2				; a3 = centerY - result
	SUB		a3, a3, #1				; a3 = ceil_bottom = (centerY-1) - result

	; ceil_top = ceilingclipy + 1  (lr = ceilingclipy)
	ADD		ip, lr, #1				; ip = ceil_top

	; Clamp ceil_bottom: if >= floorclipy: ceil_bottom = floorclipy - 1
	ADD		a4, a4, #1				; a4 = floorclipy  (recovered: was floorclipy-1)
	CMP		a3, a4
	SUBGE	a3, a4, #1

	; Skip ceiling if top > bottom
	CMP		ip, a3
	BGT		FCBoth_LoopNext

	; Check open[x]
	LDR		a4, [v5, v8, LSL #2]	; a4 = CeilPlane->open[x]
	CMP		a4, v1
	BNE		FCBoth_CeilNeedFind

FCBoth_CeilStore
	CMP		ip, #0
	SUBNE	ip, ip, #1				; if top_c != 0: top_c--
	ORR		a4, a3, ip, LSL #8		; pack open[x]
	STR		a4, [v5, v8, LSL #2]
	LDR		a4, [v5, #VP_MINY]
	CMP		a4, ip
	STRGT	ip, [v5, #VP_MINY]
	LDR		a4, [v5, #VP_MAXY]
	CMP		a4, a3
	STRLT	a3, [v5, #VP_MAXY]

FCBoth_LoopNext
	ADD		v7, v7, #12				; segloops++
	ADD		v8, v8, #1				; x++
	CMP		v8, a2					; x <= rightX?
	BLE		FCBoth_Loop

FCBoth_Done
	ADD		sp, sp, #32
	LDMIA	sp!, {v1-v8, pc}


; --- Floor FindPlane rare path ---
; Registers at entry: a1=scale a2=rightX a3=floor_top a4=floor_bottom lr=ceilingclipy
FCBoth_FloorNeedFind
	; Save: scale(a1), rightX(a2), floor_top(a3), floor_bottom(a4), ceilingclipy(lr)
	; (5 regs = 20 bytes; sp+20 = local frame after push)
	STMDB	sp!, {a1, a2, a3, a4, lr}
	MOV		a1, v4					; a1 = FloorPlane (check)
	LDR		a2, [sp, #20]			; a2 = segl  [local frame base = sp+20]
	MOV		a3, v8					; a3 = x
	LDR		a4, [sp, #24]			; a4 = floorColor  [sp+20+4]
	BL		FindPlane
	MOV		v4, a1					; FloorPlane = result
	LDMIA	sp!, {a1, a2, a3, a4, lr}	; restore scale, rightX, floor_top, floor_bottom, ceilingclipy
	CMP		v4, #0
	BEQ		FCBoth_CeilSection		; NULL → skip FloorStore, still do ceiling
	B		FCBoth_FloorStore


; --- Ceiling FindPlane rare path ---
; Registers at entry: a3=ceil_bottom ip=ceil_top a2=rightX lr=ceilingclipy (free)
; Must temporarily alias segl floor fields → ceiling before calling FindPlane
FCBoth_CeilNeedFind
	; Save: rightX(a2), ceil_bottom(a3), ceil_top(ip), lr
	; (4 regs = 16 bytes; sp+16 = local frame after push)
	STMDB	sp!, {a2, a3, ip, lr}

	LDR		a1, [sp, #16]			; a1 = segl  [local frame base = sp+16]

	; Save original segl floor fields into local frame scratch slots
	LDR		a2, [a1, #VW_FLOORHEIGHT]
	STR		a2, [sp, #24]			; [sp+16+8] = save_floorheight
	LDR		a3, [a1, #VW_FLOORPIC]
	STR		a3, [sp, #28]			; [sp+16+12] = save_FloorPic
	LDR		ip, [a1, #VW_FLATFLOORIDX]
	STR		ip, [sp, #32]			; [sp+16+16] = save_flatFloorIdx

	; Write ceiling aliases into segl floor fields (so FindPlane sees ceiling data)
	LDR		a2, [a1, #VW_CEILHEIGHT]
	STR		a2, [a1, #VW_FLOORHEIGHT]
	LDR		a3, [a1, #VW_CEILPIC]
	STR		a3, [a1, #VW_FLOORPIC]
	LDR		ip, [a1, #VW_FLATCEILIDX]
	STR		ip, [a1, #VW_FLATFLOORIDX]

	; Set isFloor = false
	LDR		a2, pIsFloor
	MOV		ip, #0
	STR		ip, [a2]

	; Call FindPlane(CeilPlane, segl, x, ceilColor)
	MOV		a1, v5					; a1 = CeilPlane
	LDR		a2, [sp, #16]			; a2 = segl
	MOV		a3, v8					; a3 = x
	LDR		a4, [sp, #88]			; a4 = ceilColor  [sp+72+16 = sp+88]
	BL		FindPlane
	MOV		v5, a1					; CeilPlane = result

	; Restore segl floor fields
	LDR		a1, [sp, #16]			; a1 = segl
	LDR		a2, [sp, #24]
	STR		a2, [a1, #VW_FLOORHEIGHT]
	LDR		a3, [sp, #28]
	STR		a3, [a1, #VW_FLOORPIC]
	LDR		ip, [sp, #32]
	STR		ip, [a1, #VW_FLATFLOORIDX]

	; Restore isFloor = true
	LDR		a2, pIsFloor
	MOV		ip, #1
	STR		ip, [a2]

	LDMIA	sp!, {a2, a3, ip, lr}	; restore rightX, ceil_bottom, ceil_top, lr

	CMP		v5, #0
	BEQ		FCBoth_LoopNext			; NULL → skip CeilStore
	B		FCBoth_CeilStore


; === Literal pool ===
pSegloops		DCD	segloops
pIsFloor		DCD	isFloor

	END
