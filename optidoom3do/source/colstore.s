;
; colstore.s — Scale+lighting column-store inner loop
;
; Writes scale and light per column to columnStoreData (RENDERER_DOOM path).
; segloops eliminated — planeclip/silclip now use accumulators + direct clipbound reads.
;
; Calling convention:
;   void ColStoreFused_ASM(int x, int rightX,
;                          int scalefrac, int scalestep,
;                          ColumnStore *col,
;                          int lightcoefF, int perColStep,
;                          int lightmin, int lightmax, int lightsub)
;
;   a1=x  a2=rightX  a3=scalefrac  a4=scalestep
;   [sp+0]=col  [sp+4]=lightcoefF  [sp+8]=perColStep
;   [sp+12]=lightmin  [sp+16]=lightmax  [sp+20]=lightsub
;
; After STMDB sp!,{v1-v8,lr} (36 bytes):
;   [sp+36]=col      [sp+40]=lightcoefF  [sp+44]=perColStep
;   [sp+48]=lightmin [sp+52]=lightmax    [sp+56]=lightsub
;
; Register map (inner loop):
;   v1=scalefrac  v2=scalestep  v3=x    v4=rightX
;   v5=col ptr    v6=lightcoefF v7=perColStep  v8=lightmax (cached)
;   a1=lightmin   ip=lightsub
;   a2, a3, a4 = scratch per column
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT	ColStoreFused_ASM

; ColumnStore field offsets (scale=0, light=4, size=8)
CS_SCALE		EQU		0
CS_LIGHT		EQU		4

;======================================================================
ColStoreFused_ASM
	STMDB	sp!, {v1-v8, lr}

	MOV		v1, a3					; v1 = scalefrac
	MOV		v2, a4					; v2 = scalestep
	MOV		v3, a1					; v3 = x
	MOV		v4, a2					; v4 = rightX

	LDR		v5, [sp, #36]			; v5 = col ptr
	LDR		v6, [sp, #40]			; v6 = lightcoefF
	LDR		v7, [sp, #44]			; v7 = perColStep
	LDR		a1, [sp, #48]			; a1 = lightmin
	LDR		v8, [sp, #52]			; v8 = lightmax (cached — no stack load in loop)
	LDR		ip, [sp, #56]			; ip = lightsub

CSLoop
	; Scale: scalefrac >> 7, clamp to [0, 0x1fff]
	MOV		a3, v1, ASR #7
	CMP		a3, #0x2000
	MOVGE	a3, #0x2000
	SUBGE	a3, a3, #1				; clamp: 0x2000-1 = 0x1fff
	STR		a3, [v5, #CS_SCALE]

	; Light: lightcoefF >> 9, subtract lightsub, clamp
	MOV		a2, v6, ASR #9
	ADD		v1, v1, v2				; scalefrac += scalestep
	SUB		a2, a2, ip
	CMP		a2, a1
	MOVLT	a2, a1					; clamp low = lightmin
	CMP		a2, v8
	MOVGT	a2, v8					; clamp high = lightmax (reg — no stack load)
	ADD		v6, v6, v7				; lightcoefF += perColStep
	STR		a2, [v5, #CS_LIGHT]

	ADD		v5, v5, #8				; col++ (size=8)
	ADD		v3, v3, #1				; x++
	CMP		v3, v4
	BLE		CSLoop

	LDMIA	sp!, {v1-v8, pc}

	END
