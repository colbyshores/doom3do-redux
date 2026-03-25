;
; angle_t PointToAngle(Fixed x1, Fixed y1, Fixed x2, Fixed y2)
;
; Converts two points into an angle. Replaces C version + SlopeAngle call.
; Uses conditional execution to reduce pipeline flushes in octant selection.
; Inlines SlopeAngle to avoid function call overhead on every invocation.
;
; Input:  a1=x1, a2=y1, a3=x2, a4=y2
; Output: a1=angle (angle_t)
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT PointToAngle
	EXPORT SlopeAngle
	IMPORT IDivTable
	IMPORT tantoangle

ANG90val	DCD	0x40000000
ANG180val	DCD	0x80000000
ANG270val	DCD	0xC0000000
pIDivTable	DCD	IDivTable
pTanToAngle	DCD	tantoangle

;---------------------------------------------------------------------
; angle_t SlopeAngle(LongWord num, LongWord den)
; Public entry point for external callers (e.g. PointToDist).
; Input:  a1 = num, a2 = den
; Output: a1 = angle
;---------------------------------------------------------------------
SlopeAngle
	; Fall through to DoSlopeAngle (same calling convention, leaf function)

;---------------------------------------------------------------------
; Inline SlopeAngle: compute angle from num(smaller) / den(larger)
; On entry: a1 = num (unsigned), a2 = den (unsigned)
; On exit:  a1 = tantoangle[index]
; Clobbers: a2, a3, a4
;---------------------------------------------------------------------
DoSlopeAngle
	MOV		a1, a1, LSR #13			; num >>= (FRACBITS-3) = 13
	MOV		a2, a2, LSR #16			; den >>= FRACBITS = 16

	LDR		a3, pIDivTable
	LDR		a3, [a3, a2, LSL #2]	; a3 = IDivTable[den]
	MUL		a1, a3, a1				; a1 = num * IDivTable[den]
	MOV		a1, a1, LSR #17			; >>9 then >>8 = >>17

	CMP		a1, #2048				; SLOPERANGE
	MOVHI	a1, #2048				; clamp

	LDR		a3, pTanToAngle
	LDR		a1, [a3, a1, LSL #2]	; return tantoangle[num]
	MOV		pc, lr

PointToAngle
	STMDB	sp!, {v1-v3, lr}

	; dx = x2 - x1, dy = y2 - y1
	SUB		a3, a3, a1				; a3 = dx
	SUB		a4, a4, a2				; a4 = dy

	; Test for (0,0)
	ORRS	v1, a3, a4
	MOVEQ	a1, #0
	LDMEQIA	sp!, {v1-v3, pc}		; return 0 if dx==0 && dy==0

	; Save sign flags in v2: bit1 = dx negative, bit0 = dy negative
	MOV		v2, #0
	CMP		a3, #0
	ORRMI	v2, v2, #2				; dx < 0
	RSBMI	a3, a3, #0				; |dx|
	CMP		a4, #0
	ORRMI	v2, v2, #1				; dy < 0
	RSBMI	a4, a4, #0				; |dy|

	; v2 now has quadrant: 0=+x+y, 1=+x-y, 2=-x+y, 3=-x-y
	; v3 = (|dx| > |dy|) ? 1 : 0 — sub-octant selector
	CMP		a3, a4
	MOVHI	v3, #1
	MOVLS	v3, #0

	; SlopeAngle always takes (smaller, larger) as (num, den)
	; If |dx| > |dy|: SlopeAngle(|dy|, |dx|)
	; If |dx| <= |dy|: SlopeAngle(|dx|, |dy|)
	MOVHI	a1, a4					; num = |dy| (smaller)
	MOVHI	a2, a3					; den = |dx| (larger)
	MOVLS	a1, a3					; num = |dx| (smaller)
	MOVLS	a2, a4					; den = |dy| (larger)

	; Call inline SlopeAngle — result in a1
	BL		DoSlopeAngle

	; v1 = raw angle from SlopeAngle
	MOV		v1, a1

	; Now apply octant correction based on v2 (quadrant) and v3 (sub-octant)
	; Octant table:
	; v2=0 (+x,+y): v3=1(dx>dy) → oct0: angle          v3=0(dy>=dx) → oct1: ANG90-1-angle
	; v2=1 (+x,-y): v3=1(dx>dy) → oct7: -angle          v3=0(dy>=dx) → oct6: ANG270+angle (was oct7 in C? let me re-check)
	; Wait, let me re-examine the C code carefully.
	;
	; C code octant mapping:
	;   +x,+y: dx>dy → SlopeAngle(dy,dx) = oct0        → return angle
	;          dy>=dx → SlopeAngle(dx,dy) = oct1        → return ANG90-1-angle
	;   +x,-y: (y2 negated) dx>dy → SlopeAngle(dy,dx)  → return -angle (== 0 - angle)
	;          dy>=dx → SlopeAngle(dx,dy)               → return angle + ANG270
	;   -x,+y: (x2 negated) dx>dy → SlopeAngle(dy,dx)  → return ANG180-1-angle
	;          dy>=dx → SlopeAngle(dx,dy)               → return angle + ANG90
	;   -x,-y: (both negated) dx>dy → SlopeAngle(dy,dx) → return angle + ANG180
	;          dy>=dx → SlopeAngle(dx,dy)               → return ANG270-1-angle

	; Build octant index = v2*2 + v3 (0-7)
	ADD		v2, v3, v2, LSL #1		; v2 = octant index (0-7)

	; Branch table via ADD pc
	ADD		pc, pc, v2, LSL #3		; each entry is 2 instructions = 8 bytes
	NOP								; pipeline

	; Octant 0: v2=0,v3=0 — +x,+y, dy>=dx → ANG90-1-angle
	LDR		a2, ANG90val
	B		SubAngle

	; Octant 1: v2=0,v3=1 — +x,+y, dx>dy → angle (raw)
	MOV		a1, v1
	B		Done

	; Octant 2: v2=1,v3=0 — +x,-y, dy>=dx → angle+ANG270
	LDR		a2, ANG270val
	B		AddAngle

	; Octant 3: v2=1,v3=1 — +x,-y, dx>dy → -angle (0-angle)
	RSB		a1, v1, #0
	B		Done

	; Octant 4: v2=2,v3=0 — -x,+y, dy>=dx → angle+ANG90
	LDR		a2, ANG90val
	B		AddAngle

	; Octant 5: v2=2,v3=1 — -x,+y, dx>dy → ANG180-1-angle
	LDR		a2, ANG180val
	B		SubAngle

	; Octant 6: v2=3,v3=0 — -x,-y, dy>=dx → ANG270-1-angle
	LDR		a2, ANG270val
	B		SubAngle

	; Octant 7: v2=3,v3=1 — -x,-y, dx>dy → angle+ANG180
	LDR		a2, ANG180val
	B		AddAngle

SubAngle
	; result = a2 - 1 - v1
	SUB		a1, a2, #1
	SUB		a1, a1, v1
	B		Done

AddAngle
	; result = v1 + a2
	ADD		a1, v1, a2

Done
	LDMIA	sp!, {v1-v3, pc}

	END
