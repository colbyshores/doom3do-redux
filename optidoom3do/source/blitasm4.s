;
;void DrawASpanLo16(Word Count,LongWord xfrac,LongWord yfrac,Fixed ds_xstep,
;	Fixed ds_ystep,Byte *Dest)
;
; Half-resolution span renderer for 16x16 textures.
; Same structure as DrawASpanLo32 but with adjusted bit masks:
;   64x64: Y mask = 0xfc0 (bits 6-11), X = LSR #26 (bits 26-31)
;   32x32: Y mask = 0x3e0 (bits 5-9),  X = LSR #27 (bits 27-31)
;   16x16: Y mask = 0x0f0 (bits 4-7),  X = LSR #28 (bits 28-31)
; Texture data is 16*16 = 256 bytes (fits comfortably in DRAM page).
;

	AREA	|C$$code|,CODE,READONLY
|x$codeseg|

	EXPORT DrawASpanLo16
	IMPORT PlaneSource

	MACRO
	Filler
	LCLA	Foo
Foo	SETA	280/4
	WHILE	Foo/=0
	AND      v4,v1,a3,LSR #22		;v4 = y index (4 bits from pos 22-25)
	ORR      v4,v4,a2,LSR #28		;v4 += x index (4 bits from pos 28-31)
	ADD      a2,a2,a4
	ADD      a3,a3,v2

	AND      ip,v1,a3,LSR #22
	ORR      ip,ip,a2,LSR #28
	ADD      a2,a2,a4
	ADD      a3,a3,v2

	LDRB	v4,[v3,v4]
	LDRB	ip,[v3,ip]

	ORR		ip,ip,v4,LSL #16
	ORR		ip,ip,ip,LSL #8

	STR		ip,[lr],#4		;13 longs (52)

Foo	SETA	Foo-1
	WEND
	MEND

;
; Main entry point
;

SrcP DCD	PlaneSource	;Pointer to the source image

DrawASpanLo16
	STMDB    sp!,{v1-v5,lr}
	MOV      a2,a2,LSL #10		;XFrac
    MOV		a3,a3,LSL #10		;YFrac
    MOV		a4,a4,LSL #11		;XStep (half-res, same as 32x32)
    ADD		lr,sp,#&18
    LDR		v3,SrcP
    LDR		v3,[v3]		;v3 = Src
    ADD		v3,v3,#64			;Adjust past the PLUT (still 64 bytes)
    LDMIA	lr,{v2,lr}		;v2 = YStep, lr = Dest
    MOV		v2,v2,LSL #11	;YStep (half-res)
    MOV		v1,#&0f0		;YMask for 16x16 (bits 4-7)
	RSB		ip,a1,#280		;Negate the index

	MOV		ip,ip,LSR #2	;Long word index
	MOV		a1,#52
	MUL		ip,a1,ip
	ADD		pc,pc,ip

	NOP

	Filler				;Perform the runfill

	LDMIA    sp!,{v1-v5,pc}

	END
