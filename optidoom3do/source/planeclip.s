;
; planeclip.s — ARM assembly floor/ceiling visplane column filling
;
; segloops eliminated: scale computed per-column from scalefrac accumulator.
;   scalefrac starts at LeftScale, increments by ScaleStep per column.
;   scale = min(scalefrac >> 7, 0x1FFF)   (matches original clamp)
;   offset = (scale * height) >> 15        (per-column MUL)
;
; Clipbounds read directly from clipboundtop[]/clipboundbottom[].
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT SegLoopFloor_ASM
	EXPORT SegLoopCeiling_ASM
	EXPORT SegLoopFloorCeiling_ASM

	IMPORT FindPlane
	IMPORT isFloor
	IMPORT clipboundtop
	IMPORT clipboundbottom

; viswall_t field offsets
VW_LEFTX		EQU 0
VW_RIGHTX		EQU 4
VW_FLOORPIC		EQU 8
VW_CEILPIC		EQU 12
VW_FLATFLOORIDX	EQU 16
VW_FLATCEILIDX	EQU 20
VW_FLOORHEIGHT	EQU 64
VW_CEILHEIGHT	EQU 72
VW_LEFTSCALE	EQU 92
VW_SCALESTEP	EQU 116

VP_MINY			EQU 1160
VP_MAXY			EQU 1164

OPENMARK		EQU 0x9F00		; ARM-encodable immediate: 0x9F rotated left 8


;======================================================================
; void SegLoopFloor_ASM(viswall_t *segl, Word screenCenterY,
;                       visplane_t *plane, Word color)
;
; a1=segl  a2=centerY  a3=plane  a4=color
; Frame: [sp+0]=segl  [sp+4]=color
;
; Loop registers:
;   v1=floorNewH  v2=centerY  v3=scalefrac  v4=FloorPlane
;   v5=scalestep  v6=clipboundtop_base  v7=clipboundbottom_base
;   a1=x  a2=rightX  a3/a4/ip=scratch  lr=scratch
;
; OPENMARK inlined as #0x9F00 — frees v1 for floorNewH.
;======================================================================

SegLoopFloor_ASM
	STMDB	sp!, {v1-v7, lr}
	SUB		sp, sp, #8

	STR		a1, [sp, #0]
	STR		a4, [sp, #4]

	MOV		v4, a3					; v4 = FloorPlane

	LDR		v1, [a1, #VW_FLOORHEIGHT]	; v1 = floorNewH
	LDR		v3, [a1, #VW_LEFTSCALE]		; v3 = scalefrac
	LDR		v5, [a1, #VW_SCALESTEP]		; v5 = scalestep

	LDR		v6, pClipBoundTop
	LDR		v7, pClipBoundBottom

	LDR		a4, [a1, #VW_RIGHTX]
	LDR		a1, [a1, #VW_LEFTX]

	MOV		v2, a2
	MOV		a2, a4

FloorLoop
	; scale = min(scalefrac >> 7, 0x1FFF)
	MOV		a4, v3, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1

	; offset = (scale * floorNewH) >> 15
	MUL		ip, a4, v1				; ip = scale*floorNewH (Rd=ip != Rm=a4)
	LDR		a3, [v6, a1, LSL #2]	; ceilingclipy (executes after MUL completes)
	MOV		a4, ip, ASR #15
	RSB		a4, a4, v2				; floor_top = centerY - offset
	ADD		v3, v3, v5				; scalefrac += step

	CMP		a4, a3					; (a3 from LDR: 3-inst gap)
	ADDLE	a4, a3, #1

	LDR		ip, [v7, a1, LSL #2]	; floorclipy
	LDR		lr, [v4, a1, LSL #2]	; open[x]  (1-inst gap for ip)
	SUB		ip, ip, #1

	CMP		a4, ip
	BGT		FloorSkip

	CMP		lr, #OPENMARK			; open[x] == OPENMARK? (inline imm)
	BNE		FloorNeedFind

FloorStore
	CMP		a4, #0
	SUBNE	a4, a4, #1
	ORR		a3, ip, a4, LSL #8
	STR		a3, [v4, a1, LSL #2]
	LDR		a3, [v4, #VP_MINY]
	CMP		a3, a4
	STRGT	a4, [v4, #VP_MINY]
	LDR		a3, [v4, #VP_MAXY]
	CMP		a3, ip
	STRLT	ip, [v4, #VP_MAXY]

FloorSkip
	ADD		a1, a1, #1
	CMP		a1, a2
	BLE		FloorLoop

FloorDone
	ADD		sp, sp, #8
	LDMIA	sp!, {v1-v7, pc}

FloorNeedFind
	STMDB	sp!, {a1, a2, a4, ip}
	MOV		a1, v4
	LDR		a2, [sp, #16]			; segl
	LDR		a3, [sp, #0]			; x
	LDR		a4, [sp, #20]			; color
	BL		FindPlane
	MOV		v4, a1
	LDMIA	sp!, {a1, a2, a4, ip}
	CMP		v4, #0
	BEQ		FloorDone
	B		FloorStore


;======================================================================
; void SegLoopCeiling_ASM(viswall_t *segl, Word screenCenterY,
;                         visplane_t *plane, Word color)
;
; Loop registers:
;   v1=ceilNewH  v2=centerY-1  v3=scalefrac  v4=CeilPlane
;   v5=scalestep  v6=clipboundtop_base  v7=clipboundbottom_base
;   a1=x  a2=rightX  a3/a4/ip/lr=scratch
;======================================================================

SegLoopCeiling_ASM
	STMDB	sp!, {v1-v7, lr}
	SUB		sp, sp, #8

	STR		a1, [sp, #0]
	STR		a4, [sp, #4]

	MOV		v4, a3

	LDR		v1, [a1, #VW_CEILHEIGHT]	; v1 = ceilNewH
	LDR		v3, [a1, #VW_LEFTSCALE]
	LDR		v5, [a1, #VW_SCALESTEP]

	LDR		v6, pClipBoundTop
	LDR		v7, pClipBoundBottom

	LDR		a4, [a1, #VW_RIGHTX]
	LDR		a1, [a1, #VW_LEFTX]

	SUB		v2, a2, #1
	MOV		a2, a4

CeilLoop
	MOV		a4, v3, ASR #7
	CMP		a4, #0x2000
	MOVGE	a4, #0x2000
	SUBGE	a4, a4, #1

	MUL		ip, a4, v1				; ip = scale*ceilNewH
	LDR		a3, [v6, a1, LSL #2]	; ceilingclipy
	MOV		a4, ip, ASR #15
	RSB		a4, a4, v2				; ceil_bottom = (centerY-1) - offset
	ADD		v3, v3, v5

	ADD		ip, a3, #1				; ip = ceil_top = ceilingclipy+1

	LDR		a3, [v7, a1, LSL #2]	; floorclipy
	LDR		lr, [v4, a1, LSL #2]	; open[x]  (1-inst gap for a3)
	CMP		a4, a3
	SUBGE	a4, a3, #1

	CMP		ip, a4
	BGT		CeilSkip

	CMP		lr, #OPENMARK
	BNE		CeilNeedFind

CeilStore
	CMP		ip, #0
	SUBNE	ip, ip, #1
	ORR		a3, a4, ip, LSL #8
	STR		a3, [v4, a1, LSL #2]
	LDR		a3, [v4, #VP_MINY]
	CMP		a3, ip
	STRGT	ip, [v4, #VP_MINY]
	LDR		a3, [v4, #VP_MAXY]
	CMP		a3, a4
	STRLT	a4, [v4, #VP_MAXY]

CeilSkip
	ADD		a1, a1, #1
	CMP		a1, a2
	BLE		CeilLoop

CeilDone
	ADD		sp, sp, #8
	LDMIA	sp!, {v1-v7, pc}

CeilNeedFind
	STMDB	sp!, {a1, a2, a4, ip}
	MOV		a1, v4
	LDR		a2, [sp, #16]
	LDR		a3, [sp, #0]
	LDR		a4, [sp, #20]
	BL		FindPlane
	MOV		v4, a1
	LDMIA	sp!, {a1, a2, a4, ip}
	CMP		v4, #0
	BEQ		CeilDone
	B		CeilStore


;======================================================================
; void SegLoopFloorCeiling_ASM(viswall_t *segl, Word screenCenterY,
;                               visplane_t *floorPlane, Word floorColor,
;                               visplane_t *ceilPlane,  Word ceilColor)
;
; a1=segl  a2=centerY  a3=floorPlane  a4=floorColor
; Caller stack before BL: [sp+0]=ceilPlane  [sp+4]=ceilColor
;
; Prologue: STMDB v1-v8,lr (36 bytes) + SUB sp,sp,#40 = 76 bytes total
;   After prologue: [sp+76]=ceilPlane  [sp+80]=ceilColor
;
; Local frame (40 bytes):
;   [sp+0]=segl  [sp+4]=floorColor  [sp+8]=floorNewH  [sp+12]=ceilNewH
;
; Loop registers:
;   v1=clipboundtop_base  v2=centerY  v3=scalefrac  v4=FloorPlane
;   v5=CeilPlane          v6=scalestep v7=clipboundbottom_base  v8=x
;   a2=rightX  lr=ceilingclipy_save  a1/a3/a4/ip=scratch
;
; OPENMARK inlined as #0x9F00.
;======================================================================

SegLoopFloorCeiling_ASM
	STMDB	sp!, {v1-v8, lr}
	SUB		sp, sp, #40

	STR		a1, [sp, #0]			; segl
	STR		a4, [sp, #4]			; floorColor

	MOV		v4, a3					; v4 = FloorPlane
	LDR		v5, [sp, #76]			; v5 = CeilPlane

	; Store heights on frame
	LDR		a3, [a1, #VW_FLOORHEIGHT]
	STR		a3, [sp, #8]			; floorNewH
	LDR		a4, [a1, #VW_CEILHEIGHT]
	STR		a4, [sp, #12]			; ceilNewH

	LDR		v3, [a1, #VW_LEFTSCALE]		; v3 = scalefrac
	LDR		v6, [a1, #VW_SCALESTEP]		; v6 = scalestep

	LDR		v8, [a1, #VW_LEFTX]
	LDR		a4, [a1, #VW_RIGHTX]
	MOV		v2, a2
	MOV		a2, a4

	LDR		v1, pClipBoundTop
	LDR		v7, pClipBoundBottom

FCBoth_Loop
	; Load clip bounds
	LDR		a3, [v1, v8, LSL #2]	; a3 = ceilingclipy
	LDR		a4, [v7, v8, LSL #2]	; a4 = floorclipy
	MOV		lr, a3					; lr = save ceilingclipy

	; Compute clamped scale
	MOV		ip, v3, ASR #7
	CMP		ip, #0x2000
	MOVGE	ip, #0x2000
	SUBGE	ip, ip, #1				; ip = min(scalefrac>>7, 0x1FFF)

	; ===== FLOOR SECTION =====
	LDR		a3, [sp, #8]			; a3 = floorNewH
	MUL		a3, ip, a3				; a3 = scale*floorNewH (Rd=a3 != Rm=ip)
	MOV		a3, a3, ASR #15			; floor_offset
	RSB		a3, a3, v2				; floor_top = centerY - offset

	CMP		a3, lr
	ADDLE	a3, lr, #1

	SUB		a4, a4, #1				; floor_bottom = floorclipy-1

	CMP		a3, a4
	BGT		FCBoth_CeilSection

	LDR		ip, [v4, v8, LSL #2]	; FloorPlane->open[x]
	CMP		ip, #OPENMARK
	BNE		FCBoth_FloorNeedFind

FCBoth_FloorStore
	CMP		a3, #0
	SUBNE	a3, a3, #1
	ORR		ip, a4, a3, LSL #8
	STR		ip, [v4, v8, LSL #2]
	LDR		ip, [v4, #VP_MINY]
	CMP		ip, a3
	STRGT	a3, [v4, #VP_MINY]
	LDR		ip, [v4, #VP_MAXY]
	CMP		ip, a4
	STRLT	a4, [v4, #VP_MAXY]

FCBoth_CeilSection
	; ===== CEILING SECTION =====
	; Recompute clamped scale (ip may have been clobbered)
	MOV		ip, v3, ASR #7
	CMP		ip, #0x2000
	MOVGE	ip, #0x2000
	SUBGE	ip, ip, #1

	LDR		a3, [sp, #12]			; a3 = ceilNewH
	MUL		a3, ip, a3				; a3 = scale*ceilNewH (Rd=a3 != Rm=ip)
	MOV		a3, a3, ASR #15
	RSB		a3, a3, v2
	SUB		a3, a3, #1				; ceil_bottom = (centerY-1) - offset

	ADD		ip, lr, #1				; ceil_top = ceilingclipy+1

	ADD		a4, a4, #1				; floorclipy recovered
	CMP		a3, a4
	SUBGE	a3, a4, #1

	CMP		ip, a3
	BGT		FCBoth_LoopNext

	LDR		a4, [v5, v8, LSL #2]	; CeilPlane->open[x]
	CMP		a4, #OPENMARK
	BNE		FCBoth_CeilNeedFind

FCBoth_CeilStore
	CMP		ip, #0
	SUBNE	ip, ip, #1
	ORR		a4, a3, ip, LSL #8
	STR		a4, [v5, v8, LSL #2]
	LDR		a4, [v5, #VP_MINY]
	CMP		a4, ip
	STRGT	ip, [v5, #VP_MINY]
	LDR		a4, [v5, #VP_MAXY]
	CMP		a4, a3
	STRLT	a3, [v5, #VP_MAXY]

FCBoth_LoopNext
	ADD		v3, v3, v6				; scalefrac += scalestep
	ADD		v8, v8, #1
	CMP		v8, a2
	BLE		FCBoth_Loop

FCBoth_Done
	ADD		sp, sp, #40
	LDMIA	sp!, {v1-v8, pc}


; --- Floor FindPlane rare path ---
FCBoth_FloorNeedFind
	STMDB	sp!, {a1, a2, a3, a4, lr}
	MOV		a1, v4
	LDR		a2, [sp, #20]			; segl
	MOV		a3, v8					; x
	LDR		a4, [sp, #24]			; floorColor [local frame+4]
	BL		FindPlane
	MOV		v4, a1
	LDMIA	sp!, {a1, a2, a3, a4, lr}
	CMP		v4, #0
	BEQ		FCBoth_CeilSection
	B		FCBoth_FloorStore


; --- Ceiling FindPlane rare path ---
FCBoth_CeilNeedFind
	STMDB	sp!, {a2, a3, ip, lr}

	LDR		a1, [sp, #16]			; segl

	; Save segl floor fields into frame scratch
	LDR		a2, [a1, #VW_FLOORHEIGHT]
	STR		a2, [sp, #32]
	LDR		a3, [a1, #VW_FLOORPIC]
	STR		a3, [sp, #36]
	LDR		ip, [a1, #VW_FLATFLOORIDX]
	STR		ip, [sp, #40]

	; Alias ceiling fields into floor fields for FindPlane
	LDR		a2, [a1, #VW_CEILHEIGHT]
	STR		a2, [a1, #VW_FLOORHEIGHT]
	LDR		a3, [a1, #VW_CEILPIC]
	STR		a3, [a1, #VW_FLOORPIC]
	LDR		ip, [a1, #VW_FLATCEILIDX]
	STR		ip, [a1, #VW_FLATFLOORIDX]

	LDR		a2, pIsFloor
	MOV		ip, #0
	STR		ip, [a2]				; isFloor = false

	MOV		a1, v5
	LDR		a2, [sp, #16]			; segl
	MOV		a3, v8					; x
	LDR		a4, [sp, #96]			; ceilColor  [sp+80 before inner push +16 = sp+96]
	BL		FindPlane
	MOV		v5, a1

	LDR		a1, [sp, #16]
	LDR		a2, [sp, #32]
	STR		a2, [a1, #VW_FLOORHEIGHT]
	LDR		a3, [sp, #36]
	STR		a3, [a1, #VW_FLOORPIC]
	LDR		ip, [sp, #40]
	STR		ip, [a1, #VW_FLATFLOORIDX]

	LDR		a2, pIsFloor
	MOV		ip, #1
	STR		ip, [a2]				; isFloor = true

	LDMIA	sp!, {a2, a3, ip, lr}
	CMP		v5, #0
	BEQ		FCBoth_LoopNext
	B		FCBoth_CeilStore


; === Literal pool ===
pClipBoundTop		DCD	clipboundtop
pClipBoundBottom	DCD	clipboundbottom
pIsFloor			DCD	isFloor

	END
