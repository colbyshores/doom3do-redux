;
;void DrawASpanLo32(Word Count,LongWord xfrac,LongWord yfrac,Fixed ds_xstep,
;	Fixed ds_ystep,Byte *Dest)
;
; Half-resolution span renderer for 32x32 textures.
; Same structure as DrawASpanLo but with adjusted bit masks:
;   64x64: Y mask = 0xfc0 (bits 6-11), X = LSR #26 (bits 26-31)
;   32x32: Y mask = 0x3e0 (bits 5-9),  X = LSR #27 (bits 27-31)
; Texture data is 32*32 = 1024 bytes (fits in one DRAM page).
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT DrawASpanLo32
	IMPORT PlaneSource

	MACRO
	Filler
	LCLA	Foo
Foo	SETA	280/4
	WHILE	Foo/=0
	AND      v4,v1,a3,LSR #21		;v4 = p1 y-index (5 bits from pos 21-25)
	ORR      v4,v4,a2,LSR #27		;v4 = p1 xy-index (5 bits from pos 27-31)
	ADD      a2,a2,a4				;step xfrac to p2
	ADD      a3,a3,v2				;step yfrac to p2

	AND      ip,v1,a3,LSR #21		;ip = p2 y-index
	ORR      ip,ip,a2,LSR #27		;ip = p2 xy-index

	LDRB	v4,[v3,v4]				;load p1 (addr 5 instrs old — no stall)
	ADD      a2,a2,a4				;step to next p1 (fills v4 load-use slot)
	ADD      a3,a3,v2				;step to next p1 (fills v4 load-use slot)

	LDRB	ip,[v3,ip]				;load p2 (addr 4 instrs old; v4 3 instrs old)

	MOV		v5,v4,LSL #16			;pre-shift p1 (fills ip load-use slot; v4 3 instrs old)
	ORR		v5,v5,ip				;p1<<16 | p2  (ip 1 instr old — 1-wait-state safe)
	ORR		v5,v5,v5,LSL #8			;duplicate bytes

	STR		v5,[lr],#4				;14 instructions (56 bytes)

Foo	SETA	Foo-1
	WEND
	MEND

;
; Main entry point
;

SrcP DCD	PlaneSource	;Pointer to the source image

DrawASpanLo32
	STMDB    sp!,{v1-v5,lr}
	MOV      a2,a2,LSL #10		;XFrac
    MOV		a3,a3,LSL #10		;YFrac
    MOV		a4,a4,LSL #11		;XStep (half-res)
    ADD		lr,sp,#&18
    LDR		v3,SrcP
    LDR		v3,[v3]		;v3 = Src
    ADD		v3,v3,#64			;Adjust past the PLUT (still 64 bytes)
    LDMIA	lr,{v2,lr}		;v2 = YStep, lr = Dest
    MOV		v2,v2,LSL #11	;YStep (half-res)
    MOV		v1,#&3e0		;YMask for 32x32 (bits 5-9)
	RSB		ip,a1,#280		;Negate the index

	MOV		ip,ip,LSR #2	;Long word index (skip unit = 4 pixels = 2 iterations)
	MOV		a1,#56			;bytes per iteration (14 instrs x 4 bytes)
	MUL		ip,a1,ip
	ADD		pc,pc,ip

	NOP

	Filler				;Perform the runfill

	LDMIA    sp!,{v1-v5,pc}

	END
