;
; Word PointOnVectorSide(Fixed x, Fixed y, vector_t *line)
;
; Returns 1 (TRUE/back side) or 0 (FALSE/front side).
; Replaces C version with ARM assembly using conditional execution
; to minimize pipeline flushes in the cross-product path.
;
; vector_t layout: x(+0), y(+4), dx(+8), dy(+12)
;
; Input:  a1=x, a2=y, a3=line pointer
; Output: a1=0 (front) or 1 (back)
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT PointOnVectorSide

; Register aliases
px	RN	a1		; point x (then offset x)
py	RN	a2		; point y (then offset y)
line	RN	a3		; line pointer
dx	RN	a4		; line->dx
dy	RN	v1		; line->dy
tmp	RN	v2		; scratch
tmp2	RN	v3		; scratch

PointOnVectorSide
	STMDB	sp!, {v1-v3, lr}

	; Load line fields
	LDR		dx, [line, #8]		; dx = line->dx
	LDR		dy, [line, #12]		; dy = line->dy
	LDR		tmp, [line, #0]		; tmp = line->x
	SUB		px, px, tmp			; px = x - line->x

	; Special case #1: vertical line (dx == 0)
	CMP		dx, #0
	BNE		NotVertical
	; Vertical: if px <= 0 then dy = -dy; result = (dy < 0) ? 1 : 0
	CMP		px, #0
	RSBLE	dy, dy, #0			; if px <= 0: dy = -dy
	CMP		dy, #0
	MOVGE	a1, #0				; front side (dy >= 0)
	MOVLT	a1, #1				; back side (dy < 0)
	LDMIA	sp!, {v1-v3, pc}

NotVertical
	LDR		tmp, [line, #4]		; tmp = line->y
	SUB		py, py, tmp			; py = y - line->y

	; Special case #2: horizontal line (dy == 0)
	CMP		dy, #0
	BNE		NotHorizontal
	; Horizontal: if py <= 0 then dx = -dx; result = (dx <= 0) ? 0 : 1
	CMP		py, #0
	RSBLE	dx, dx, #0			; if py <= 0: dx = -dx
	CMP		dx, #0
	MOVLE	a1, #0				; front side (dx <= 0)
	MOVGT	a1, #1				; back side (dx > 0)
	LDMIA	sp!, {v1-v3, pc}

NotHorizontal
	; Special case #3: sign-based early out
	; if (dy^dx^px^py) has sign bit set, we can use a quick sign test
	EOR		tmp, dy, dx
	EOR		tmp, tmp, px
	EOR		tmp, tmp, py
	TST		tmp, #&80000000
	BEQ		CrossProduct		; compound sign is positive, need full cross product

	; Signs differ — check if dy^px has same sign (cross product sign shortcut)
	EOR		tmp, dy, px
	TST		tmp, #&80000000
	MOVEQ	a1, #0				; front side (dy and px same sign)
	MOVNE	a1, #1				; back side
	LDMIA	sp!, {v1-v3, pc}

CrossProduct
	; Case #4: full cross product
	; x = (dy>>16) * (px>>16)
	; y = (dx>>16) * (py>>16)
	; result = (y < x) ? 0 : 1
	MOV		px, px, ASR #16		; px = integer part
	MOV		py, py, ASR #16		; py = integer part
	MOV		tmp, dy, ASR #16	; tmp = dy integer
	MUL		px, tmp, px			; px = (dy>>16) * px  (cross_left)
	MOV		tmp, dx, ASR #16	; tmp = dx integer
	MUL		py, tmp, py			; py = (dx>>16) * py  (cross_right)

	; result: if cross_right < cross_left then front(0), else back(1)
	CMP		py, px
	MOVCC	a1, #0				; front side
	MOVCS	a1, #1				; back side
	LDMIA	sp!, {v1-v3, pc}

	END
