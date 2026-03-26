;
; bspclip.s — ARM assembly AddLine for BSP traversal
;
; Keeps cviewx, cviewy, cviewangle, cclipangle, cdoubleclipangle in
; callee-saved registers (v1-v5) across both PointToAngle BL calls,
; avoiding DRAM reloads of these hot view globals.
;
; Register map:
;   v1 (r4)  = cviewx
;   v2 (r5)  = cviewy
;   v3 (r6)  = cviewangle
;   v4 (r7)  = cclipangle
;   v5 (r8)  = cdoubleclipangle
;   v6 (r9)  = line  (seg_t*)
;   v7 (r10) = FrontSector (sector_t*)
;   v8 (r11) = angle1  (preserved across 2nd PointToAngle BL)
;
; Scratch (a1-a4, ip) used freely between BL calls:
;   a2 = angle2
;   a3 = span
;   a4 = tspan
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT	AddLine_ASM

	IMPORT	PointToAngle
	IMPORT	ClipSolidWallSegment
	IMPORT	ClipPassWallSegment
	IMPORT	cviewx
	IMPORT	cviewy
	IMPORT	cviewangle
	IMPORT	cclipangle
	IMPORT	cdoubleclipangle
	IMPORT	curline
	IMPORT	lineangle1
	IMPORT	viewangletox

; seg_t field offsets
SEG_V1X		EQU	0
SEG_V1Y		EQU	4
SEG_V2X		EQU	8
SEG_V2Y		EQU 12
SEG_SIDEDEF	EQU 24
SEG_BACKSEC	EQU 36

; side_t field offsets
SIDE_MIDTEX	EQU 16

; sector_t field offsets
SEC_FLOOR	EQU 0
SEC_CEIL	EQU 4
SEC_FLOORPIC	EQU 8
SEC_CEILPIC	EQU 12
SEC_LIGHT	EQU 16

; ANG90 = 0x40000000, ANG180 = 0x80000000
; (angle+ANG90) >> (ANGLETOFINESHIFT+1) = >> 20

;======================================================================
; void AddLine_ASM(seg_t *line, sector_t *FrontSector)
;======================================================================

AddLine_ASM
	STMDB	sp!, {v1-v8, lr}

	; Load view globals into callee-saved registers
	LDR		v1, pCviewx
	LDR		v2, pCviewy
	LDR		v3, pCviewangle
	LDR		v4, pCclipangle
	LDR		v5, pCdoubleclipangle
	LDR		v1, [v1]
	LDR		v2, [v2]
	LDR		v3, [v3]
	LDR		v4, [v4]
	LDR		v5, [v5]
	MOV		v6, a1				; v6 = line
	MOV		v7, a2				; v7 = FrontSector

	; angle1 = PointToAngle(cviewx, cviewy, line->v1.x, line->v1.y)
	LDR		a3, [v6, #SEG_V1X]
	LDR		a4, [v6, #SEG_V1Y]
	MOV		a1, v1
	MOV		a2, v2
	BL		PointToAngle
	MOV		v8, a1				; v8 = angle1

	; angle2 = PointToAngle(cviewx, cviewy, line->v2.x, line->v2.y)
	LDR		a3, [v6, #SEG_V2X]
	LDR		a4, [v6, #SEG_V2Y]
	MOV		a1, v1
	MOV		a2, v2
	BL		PointToAngle
						; a1 = angle2

	; span = angle1 - angle2; if (span >= ANG180) return
	SUB		a3, v8, a1			; a3 = span (unsigned)
	CMP		a3, #0x80000000		; span >= ANG180?
	BHS		AL_exit

	; lineangle1 = angle1
	LDR		ip, pLineangle1
	STR		v8, [ip]

	; angle1 -= cviewangle; angle2 -= cviewangle
	SUB		v8, v8, v3			; v8 = angle1 (adjusted)
	SUB		a2, a1, v3			; a2 = angle2 (adjusted)

	; tspan = angle1 + cclipangle; if (tspan > cdoubleclipangle) clip left
	ADD		a4, v8, v4			; tspan
	CMP		a4, v5
	BLS		AL_right_check
	SUB		a4, a4, v5
	CMP		a4, a3				; tspan >= span?
	BHS		AL_exit
	MOV		v8, v4				; angle1 = cclipangle

AL_right_check
	; tspan = cclipangle - angle2; if (tspan > cdoubleclipangle) clip right
	SUB		a4, v4, a2			; tspan
	CMP		a4, v5
	BLS		AL_project
	SUB		a4, a4, v5
	CMP		a4, a3				; tspan >= span?
	BHS		AL_exit
	RSB		a2, v4, #0			; angle2 = -(int)cclipangle

AL_project
	; Convert angles to viewangletox indices: (angle + ANG90) >> 20
	ADD		v8, v8, #0x40000000
	MOV		v8, v8, LSR #20		; angle1 index
	ADD		a2, a2, #0x40000000
	MOV		a2, a2, LSR #20		; angle2 index

	; Look up screen X coords
	LDR		ip, pViewangletox
	LDR		v8, [ip, v8, LSL #2]	; v8 = screen_x1 = viewangletox[angle1]
	LDR		a2, [ip, a2, LSL #2]	; a2 = screen_x2 = viewangletox[angle2]

	; if (angle1 >= angle2) return
	CMP		v8, a2
	BGE		AL_exit
	SUB		a2, a2, #1			; --angle2 (make right side inclusive)

	; curline = line
	LDR		ip, pCurline
	STR		v6, [ip]

	; backsector = line->backsector
	LDR		a3, [v6, #SEG_BACKSEC]

	; if (!backsector) → solid wall
	CMP		a3, #0
	BEQ		AL_solid

	; if (backsector->ceilingheight <= FrontSector->floorheight) → solid (closed door)
	LDR		a4, [a3, #SEC_CEIL]
	LDR		ip, [v7, #SEC_FLOOR]
	CMP		a4, ip
	BLE		AL_solid

	; if (backsector->floorheight >= FrontSector->ceilingheight) → solid
	LDR		a4, [a3, #SEC_FLOOR]
	LDR		ip, [v7, #SEC_CEIL]
	CMP		a4, ip
	BGE		AL_solid

	; Check whether the window is visually different (needs ClipPassWallSegment)
	LDR		a4, [a3, #SEC_CEIL]
	LDR		ip, [v7, #SEC_CEIL]
	CMP		a4, ip
	BNE		AL_pass

	LDR		a4, [a3, #SEC_FLOOR]
	LDR		ip, [v7, #SEC_FLOOR]
	CMP		a4, ip
	BNE		AL_pass

	LDR		a4, [a3, #SEC_CEILPIC]
	LDR		ip, [v7, #SEC_CEILPIC]
	CMP		a4, ip
	BNE		AL_pass

	LDR		a4, [a3, #SEC_FLOORPIC]
	LDR		ip, [v7, #SEC_FLOORPIC]
	CMP		a4, ip
	BNE		AL_pass

	LDR		a4, [a3, #SEC_LIGHT]
	LDR		ip, [v7, #SEC_LIGHT]
	CMP		a4, ip
	BNE		AL_pass

	LDR		a3, [v6, #SEG_SIDEDEF]	; line->sidedef
	LDR		a3, [a3, #SIDE_MIDTEX]	; sidedef->midtexture
	CMP		a3, #0
	BEQ		AL_exit				; no visual difference, skip

AL_pass
	MOV		a1, v8
	BL		ClipPassWallSegment
	B		AL_exit

AL_solid
	MOV		a1, v8
	BL		ClipSolidWallSegment

AL_exit
	LDMIA	sp!, {v1-v8, pc}


; === Literal pool ===
pCviewx			DCD		cviewx
pCviewy			DCD		cviewy
pCviewangle		DCD		cviewangle
pCclipangle		DCD		cclipangle
pCdoubleclipangle	DCD	cdoubleclipangle
pLineangle1		DCD		lineangle1
pCurline		DCD		curline
pViewangletox	DCD		viewangletox

	END
