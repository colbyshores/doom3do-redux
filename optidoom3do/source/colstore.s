;
; colstore.s — Fused scale+segloops+lighting column-store inner loop
;
; Replaces the two-pass prepColumnStoreData() in phase6_1.c:
;   pass 1: scale + segloops (outer loop)
;   pass 2: per-column light interpolation (prepColumnStoreDataLight)
;
; Fused into one loop. lightcoefF (per-column accumulator) and
; perColStep live in callee-saved v7/v8 for the whole wall — never
; spilled to the stack between columns the way C does.
;
; Calling convention:
;   void ColStoreFused_ASM(int x, int rightX,
;                          int scalefrac, int scalestep,
;                          segloop_t *seg, ColumnStore *col,
;                          int lightcoefF, int perColStep,
;                          int lightmin, int lightmax, int lightsub)
;
;   a1 = x (leftX)          a2 = rightX
;   a3 = scalefrac           a4 = scalestep
;   [sp+0]  = seg            [sp+4]  = col
;   [sp+8]  = lightcoefF     [sp+12] = perColStep
;   [sp+16] = lightmin       [sp+20] = lightmax
;   [sp+24] = lightsub
;
; After STMDB sp!, {v1-v8, lr} (36 bytes pushed), stack args offset +36:
;   [sp+36] = seg    [sp+40] = col    [sp+44] = lightcoefF
;   [sp+48] = perColStep              [sp+52] = lightmin
;   [sp+56] = lightmax                [sp+60] = lightsub
;
; Register map (inner loop — no BL calls, a1/a2/a3/a4/ip all free as scratch):
;   v1 = scalefrac           v2 = scalestep
;   v3 = x                   v4 = rightX
;   v5 = segloops ptr        v6 = columnStoreData ptr
;   v7 = lightcoefF          v8 = perColStep
;   a1 = lightmin  (constant — freed once leftX is moved to v3)
;   ip = lightsub  (constant)
;   a2, a3, a4 = scratch each column
;   lightmax at [sp+56] — 1 stack LDR per column for clamp
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT	ColStoreFused_ASM

	IMPORT	clipboundtop
	IMPORT	clipboundbottom

; segloop_t field offsets (scale=0, ceilingclipy=4, floorclipy=8, size=12)
SL_SCALE		EQU		0
SL_CEILCLIPY	EQU		4
SL_FLRCLIPY		EQU		8

; ColumnStore field offsets (scale=0, light=4, size=8)
CS_SCALE		EQU		0
CS_LIGHT		EQU		4

; FIXEDTOSCALE = FRACBITS - SCALEBITS = 16 - 9 = 7
; Light shift  = 16 - FIXEDTOSCALE = 9

;======================================================================
ColStoreFused_ASM
	STMDB	sp!, {v1-v8, lr}

	; Load register-resident loop vars from args
	MOV		v1, a3					; v1 = scalefrac
	MOV		v2, a4					; v2 = scalestep
	MOV		v3, a1					; v3 = x  (a1 now free for lightmin)
	MOV		v4, a2					; v4 = rightX

	LDR		v5, [sp, #36]			; v5 = seg (segloops ptr)
	LDR		v6, [sp, #40]			; v6 = col (columnStoreData ptr)
	LDR		v7, [sp, #44]			; v7 = lightcoefF
	LDR		v8, [sp, #48]			; v8 = perColStep
	LDR		a1, [sp, #52]			; a1 = lightmin (held in reg, no stack load in loop)
	LDR		ip, [sp, #60]			; ip = lightsub (held in reg, no stack load in loop)

CSLoop
	; Begin CBTop load; fill its 2-cycle latency with scale computation
	LDR		a2, pCBTop				; a2 = &clipboundtop[0]
	MOV		a3, v1, ASR #7			; scale = scalefrac >> FIXEDTOSCALE(7)
	LDR		a2, [a2, v3, LSL #2]	; a2 = clipboundtop[x]  -- a2 ready after 1 gap
	CMP		a3, #0x2000				; scale >= max?
	MOVGE	a3, #0x2000				; clamp to 0x1fff (two instrs — 0x1fff not ARM-encodable)
	SUBGE	a3, a3, #1

	; Store scale to both arrays; begin CBBottom load
	STR		a3, [v6, #CS_SCALE]		; coldata->scale = scale
	LDR		a4, pCBBottom			; a4 = &clipboundbottom[0]
	STR		a3, [v5, #SL_SCALE]		; segloops->scale = scale
	LDR		a4, [a4, v3, LSL #2]	; a4 = clipboundbottom[x]
	STR		a2, [v5, #SL_CEILCLIPY]	; segloops->ceilingclipy  (a2 ready: 4 instrs since load)

	; Scale step + light shift — interleaved to fill CBBottom latency
	ADD		v1, v1, v2				; scalefrac += scalestep
	MOV		a3, v7, ASR #9			; light = lightcoefF >> (16-FIXEDTOSCALE=9)
	STR		a4, [v5, #SL_FLRCLIPY]	; segloops->floorclipy   (a4 ready: 3 instrs since load)

	; Light: subtract lightsub, clamp, store
	SUB		a3, a3, ip				; light -= lightsub
	CMP		a3, a1					; light < lightmin?
	MOVLT	a3, a1
	LDR		a4, [sp, #56]			; a4 = lightmax (from stack — 1 load per column)
	ADD		v7, v7, v8				; lightcoefF += perColStep  (fills lightmax load latency)
	CMP		a3, a4					; light > lightmax?
	MOVGT	a3, a4
	STR		a3, [v6, #CS_LIGHT]		; coldata->light = light

	; Advance pointers + loop
	ADD		v5, v5, #12				; segloops++  (size = 12)
	ADD		v6, v6, #8				; coldata++   (size = 8)
	ADD		v3, v3, #1				; x++
	CMP		v3, v4					; x <= rightX?
	BLE		CSLoop

	LDMIA	sp!, {v1-v8, pc}


; Literal pool
pCBTop		DCD		clipboundtop
pCBBottom	DCD		clipboundbottom

	END
