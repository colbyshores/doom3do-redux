;
; Fixed GetApproxDistance(Fixed dx, Fixed dy)
;
; Octagonal distance approximation: max(|dx|,|dy|) + min(|dx|,|dy|)/2
; Replaces C version with branchless ARM assembly using conditional execution.
; Eliminates 4 branch penalties (3 cycles each = 12 wasted cycles per call).
;
; Input:  a1 = dx, a2 = dy
; Output: a1 = approximate distance
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT GetApproxDistance

GetApproxDistance
	; Absolute value of dx (a1) — branchless via conditional negate
	CMP		a1, #0
	RSBMI	a1, a1, #0		; if dx < 0, dx = -dx (1-cycle NOP if positive)

	; Absolute value of dy (a2) — branchless
	CMP		a2, #0
	RSBMI	a2, a2, #0		; if dy < 0, dy = -dy

	; Now compute max + min/2 without branching:
	; if dx < dy: result = dy + dx/2
	; else:       result = dx + dy/2
	CMP		a1, a2
	MOVCC	a3, a1			; if dx < dy: a3 = dx (the smaller)
	MOVCC	a1, a2			; if dx < dy: a1 = dy (the larger)
	MOVCS	a3, a2			; if dx >= dy: a3 = dy (the smaller)
	; a1 is already the larger if dx >= dy

	ADD		a1, a1, a3, LSR #1	; result = larger + smaller/2

	MOV		pc, lr			; return

	END
