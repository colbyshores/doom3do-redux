#include "Doom.h"
#include <IntMath.h>

#include "string.h"

#define CCB_ARRAY_WALL_MAX MAXSCREENWIDTH

static BitmapCCB CCBArrayWall[CCB_ARRAY_WALL_MAX];		// Array of CCB structs for rendering a batch of wall columns
static int CCBArrayWallCurrent = 0;
static int CCBflagsCurrentAlteredIndex = 0;

uint32* CCBflagsAlteredIndexPtr[MAXWALLCMDS];	// Array of pointers to CEL flags to set/remove LD_PLUT

static const int flatColTexWidth = 1;   //  static const int flatColTexWidthShr = 0;
static const int flatColTexHeight = 4;  static const int flatColTexHeightShr = 2;
static const int flatColTexStride = 8;
static unsigned char *texColBufferFlat = NULL;

static drawtex_t drawtex;

viscol_t viscols[MAXSCREENWIDTH];

static uint16 *coloredWallPals = NULL;
static int currentWallCount = 0;

static Word *LightTablePtr = LightTable;


/**********************************

	Calculate texturecolumn and iscale for the rendertexture routine

**********************************/

static void initCCBarrayWall(void)
{
	BitmapCCB *CCBPtr = CCBArrayWall;

	int i;
	for (i=0; i<CCB_ARRAY_WALL_MAX; ++i) {
		CCBPtr->ccb_NextPtr = (BitmapCCB *)(sizeof(BitmapCCB)-8);	// Create the next offset

		// Set all the defaults
        CCBPtr->ccb_Flags = CCB_SPABS|CCB_LDSIZE|CCB_LDPPMP|CCB_CCBPRE|CCB_YOXY|CCB_ACW|CCB_ACCW|
                            CCB_ACE|CCB_BGND|/*CCB_NOBLK|*/CCB_PPABS|CCB_ACSC|CCB_ALSC|CCB_PLUTPOS;	// ccb_flags

        CCBPtr->ccb_HDX = 0<<20;
        CCBPtr->ccb_VDX = 1<<16;
        CCBPtr->ccb_VDY = 0<<16;

		++CCBPtr;
	}
}

static void initCCBarrayWallFlat(void)
{
	BitmapCCB *CCBPtr;
	int i;
	//int x,y;
	Word pre0, pre1;

	if (!texColBufferFlat) {
		const int flatColTextSize = flatColTexStride * flatColTexHeight;
		texColBufferFlat = (unsigned char*)AllocAPointer(flatColTextSize * sizeof(unsigned char));
		memset(texColBufferFlat, 0, flatColTextSize);
	}

    pre0 = 0x00000001 | ((flatColTexHeight - 1) << 6);
    pre1 = (((flatColTexStride >> 2) - 2) << 24) | (flatColTexWidth - 1);

	CCBPtr = CCBArrayWall;
	for (i=0; i<CCB_ARRAY_WALL_MAX; ++i) {
		CCBPtr->ccb_NextPtr = (BitmapCCB *)(sizeof(BitmapCCB)-8);	// Create the next offset

		// Set all the defaults
        CCBPtr->ccb_Flags = CCB_LDSIZE|CCB_LDPPMP|CCB_CCBPRE|CCB_YOXY|CCB_ACW|CCB_ACCW|CCB_ACE|CCB_BGND|/*CCB_NOBLK|*/CCB_ACSC|CCB_ALSC|CCB_SPABS|CCB_PPABS|CCB_PLUTPOS;

        CCBPtr->ccb_PRE0 = pre0;
        CCBPtr->ccb_PRE1 = pre1;
        CCBPtr->ccb_SourcePtr = (CelData*)texColBufferFlat;
        CCBPtr->ccb_VDX = 0<<16;
        CCBPtr->ccb_HDX = 1<<20;
        CCBPtr->ccb_HDY = 0<<20;

		++CCBPtr;
	}
}

void initWallCELs()
{
	if (!coloredWallPals) {
		coloredWallPals = (uint16*)AllocAPointer(16 * MAXWALLCMDS * sizeof(uint16));
	}

	initCCBarrayWall();
}

void drawCCBarrayWall(Word xEnd)
{
    BitmapCCB *columnCCBstart, *columnCCBend;

	columnCCBstart = &CCBArrayWall[0];				// First column CEL of the wall segment
	columnCCBend = &CCBArrayWall[xEnd];				// Last column CEL of the wall segment
	dummyCCB->ccb_NextPtr = (CCB*)columnCCBstart;	// Start with dummy to reset HDDX and HDDY

	columnCCBend->ccb_Flags |= CCB_LAST;	// Mark last colume CEL as the last one in the linked list
    DrawCels(VideoItem,dummyCCB);			// Draw all the cels of a single wall in one shot
    columnCCBend->ccb_Flags ^= CCB_LAST;	// remember to flip off that CCB_LAST flag, since we don't reinit the flags for all columns every time
}

void flushCCBarrayWall()
{
	if (CCBArrayWallCurrent != 0) {
		int i;
		drawCCBarrayWall(CCBArrayWallCurrent - 1);
		CCBArrayWallCurrent = 0;

		for (i=0; i<CCBflagsCurrentAlteredIndex; ++i) {
			*CCBflagsAlteredIndexPtr[i] &= ~CCB_LDPLUT;
		}
		CCBflagsCurrentAlteredIndex = 0;
	}
}

/* ARM ASM inner loops — one for 2x1 double-CCB path, one for 1x1.
   viscol_t: scale(int,4B)@0, column(Word/uint32,4B)@4, light(Word/uint32,4B)@8, size=12. */
extern void DrawWallInnerDouble_ASM(viscol_t *vc, BitmapCCB *CCBPtr, int xPos, int xEnd,
    int screenCenterY, int texTopHeight, Word texWidth, Word texHeight,
    const Byte *texBitmap, Word colnumOffset, LongWord frac, int pre0, int pre1);
extern void DrawWallInner1x_ASM(viscol_t *vc, BitmapCCB *CCBPtr, int xPos, int xEnd,
    int screenCenterY, int texTopHeight, Word texWidth, Word texHeight,
    const Byte *texBitmap, Word colnumOffset, LongWord frac, int pre0, int pre1);

static void DrawWallSegment(drawtex_t *tex, void *texPal, Word screenCenterY)
{
    int xPos = tex->xStart;
	const int xEnd = tex->xEnd;
	const int texTopHeight = tex->topheight;
	const Word texWidth = tex->width - 1;
	const Word texHeight = tex->height;
	const Byte *texBitmap = &tex->data[32];

	/* Texture column setup (formerly PrepWallSegmentTexCol) */
	Word run;
	LongWord frac;
	Word colnumOffset;
	Word colnum7;
	int pre0, pre1;

	BitmapCCB *CCBPtr;
	int numCels;

	run = (tex->topheight - tex->bottomheight) >> HEIGHTBITS;
	if ((int)run <= 0) return;

	colnumOffset = 0;
	frac = tex->texturemid - (tex->topheight << FIXEDTOHEIGHT);
	frac >>= FRACBITS;
	while (frac & 0x8000) {
		--colnumOffset;
		frac += texHeight;
	}
	frac &= 0x7f;
	colnum7 = frac & 7;
	pre0 = (colnum7 << 24) | 0x03;
	pre1 = 0x3E005000 | (colnum7 + run - 1);

	if (xPos > xEnd) return;
    numCels = xEnd - xPos + 1;
	if (CCBArrayWallCurrent + (numCels << screenScaleX) > CCB_ARRAY_WALL_MAX) {
		flushCCBarrayWall();
	}

    CCBPtr = &CCBArrayWall[CCBArrayWallCurrent];
	CCBPtr->ccb_Flags |= CCB_LDPLUT;
	CCBPtr->ccb_PLUTPtr = texPal;
	CCBflagsAlteredIndexPtr[CCBflagsCurrentAlteredIndex++] = &CCBPtr->ccb_Flags;

    if (screenScaleX) {
        DrawWallInnerDouble_ASM(viscols, CCBPtr, xPos, xEnd,
            screenCenterY, texTopHeight, texWidth, texHeight,
            texBitmap, colnumOffset, frac, pre0, pre1);
    } else {
        DrawWallInner1x_ASM(viscols, CCBPtr, xPos, xEnd,
            screenCenterY, texTopHeight, texWidth, texHeight,
            texBitmap, colnumOffset, frac, pre0, pre1);
    }

    CCBArrayWallCurrent += numCels << screenScaleX;
}

static void DrawWallSegmentFlat(drawtex_t *tex, const void *color, Word screenCenterY)
{
    int xPos = tex->xStart;
	const int xEnd = tex->xEnd;
	const int texTopHeight = tex->topheight;
	int top, sx;
	Word yval, vdy, pixc;
	Word run;
	viscol_t *vc;

	BitmapCCB *CCBPtr;
	int numCels;

	if (xPos > xEnd) return;
	numCels = xEnd - xPos + 1;
	if (CCBArrayWallCurrent + (numCels << screenScaleX) > CCB_ARRAY_WALL_MAX) {
		flushCCBarrayWall();
	}

	run = (texTopHeight-tex->bottomheight) >> HEIGHTBITS;
	if ((int)run<=0) {
		return;
	}

    CCBPtr = &CCBArrayWall[CCBArrayWallCurrent];
	CCBPtr->ccb_Flags |= CCB_LDPLUT;
	CCBPtr->ccb_PLUTPtr = (void*)color;
	CCBflagsAlteredIndexPtr[CCBflagsCurrentAlteredIndex++] = &CCBPtr->ccb_Flags;
    vc = viscols;
    if (screenScaleX) {
        do {
            top = screenCenterY - ((vc->scale*texTopHeight) >> (HEIGHTBITS+SCALEBITS));
            sx = xPos * 2;
            yval = (top << 16) | 0xFF00;
            vdy = (run * vc->scale) << (16-flatColTexHeightShr-SCALEBITS);
            pixc = vc->light;

            CCBPtr->ccb_XPos = sx << 16;
            CCBPtr->ccb_YPos = yval;
            CCBPtr->ccb_VDY = vdy;
            CCBPtr->ccb_PIXC = pixc;
            CCBPtr++;

            CCBPtr->ccb_XPos = (sx+1) << 16;
            CCBPtr->ccb_YPos = yval;
            CCBPtr->ccb_VDY = vdy;
            CCBPtr->ccb_PIXC = pixc;
            CCBPtr++;

            vc++;
        } while (++xPos <= xEnd);
    } else {
        do {
            top = screenCenterY - ((vc->scale*texTopHeight) >> (HEIGHTBITS+SCALEBITS));

            CCBPtr->ccb_XPos = xPos << 16;
            CCBPtr->ccb_YPos = (top << 16) | 0xFF00;
            CCBPtr->ccb_VDY = (run * vc->scale) << (16-flatColTexHeightShr-SCALEBITS);
            CCBPtr->ccb_PIXC = vc->light;

            CCBPtr++;
            vc++;
        } while (++xPos <= xEnd);
    }
    CCBArrayWallCurrent += numCels << screenScaleX;
}


/**********************************

	Compute and cache the weighted average colour of a texture from its
	actual texel data (4-bit coded, 16-entry PLUT).  The result is stored
	in tex->color (0 = uncomputed sentinel; we map 0 results to 1).
	Called lazily on first use so texture data is guaranteed loaded.
	Used as the flat fill colour for VW_DISCARD wall fallback rendering.

**********************************/

static Word computeTexAvgColor(texture_t *tex)
{
	uint16 *plut;
	Byte *pixels;
	int freq[16];
	int total, i;
	long r_sum, g_sum, b_sum;
	uint16 avg;

	/* Data layout: 32 bytes PLUT (16 × uint16) then packed 4-bit pixels */
	plut   = (uint16 *)*tex->data;
	pixels = (Byte *)*tex->data + 32;
	total  = (int)tex->width * (int)tex->height;

	/* Count frequency of each 4-bit palette index across all texels.
	   LRFORM interleaving doesn't affect per-index frequency counts. */
	for (i = 0; i < 16; i++) freq[i] = 0;
	for (i = 0; i < total / 2; i++) {
		freq[(pixels[i] >> 4) & 0xF]++;
		freq[pixels[i] & 0xF]++;
	}

	/* Weighted average of non-transparent PLUT entries (c==0 is transparent) */
	r_sum = g_sum = b_sum = 0;
	total = 0;
	for (i = 0; i < 16; i++) {
		if (freq[i] > 0) {
			uint16 c = plut[i];
			if (c != 0) {
				/* 3DO RGB555: bits 14-10=R, 9-5=G, 4-0=B */
				r_sum += freq[i] * (int)(c >> 10);
				g_sum += freq[i] * (int)((c >> 5) & 31);
				b_sum += freq[i] * (int)(c & 31);
				total += freq[i];
			}
		}
	}

	if (total == 0) return 1;  /* all-transparent texture: use near-black sentinel */

	avg = (uint16)(((r_sum / total) << 10) | ((g_sum / total) << 5) | (b_sum / total) | 1);
	return avg ? avg : 1;  /* bit 0 = opaque; never return 0 (uncomputed sentinel) */
}

/**********************************

	Draw a single wall texture.
	Also save states for pending ceiling, floor and future clipping

**********************************/

static void DrawSegAny(viswall_t *segl, bool isTop, bool isFlat)
{
    texture_t *tex;
	void *texPal = NULL;

    if (isTop) {
        tex = segl->t_texture;

        drawtex.topheight = segl->t_topheight;
        drawtex.bottomheight = segl->t_bottomheight;
        drawtex.texturemid = segl->t_texturemid;
    } else {
        tex = segl->b_texture;

        drawtex.topheight = segl->b_topheight;
        drawtex.bottomheight = segl->b_bottomheight;
        drawtex.texturemid = segl->b_texturemid;
    }

	/* Lazily compute and cache average texture colour (used for DISCARD fallback) */
	if (tex->color == 0 && tex->data && *tex->data) {
		tex->color = computeTexAvgColor(tex);
	}

	if (segl->special & SEC_SPEC_FOG) {
		LightTablePtr = LightTableFog;
	} else {
		LightTablePtr = LightTable;
	}

	if (segl->color!=0) {
		texPal = &coloredWallPals[currentWallCount << 4];
		if (++currentWallCount == MAXWALLCMDS) currentWallCount = 0;
	}

    if (isFlat) {
		if (segl->color==0) {
			/* tex->color may still be 0 if data wasn't loaded; use grey sentinel */
			static Word sDiscardFallbackColor = 0x3def;
			texPal = (void*)(tex->color ? &tex->color : &sDiscardFallbackColor);
		} else {
			initColoredPals((uint16*)&tex->color, texPal, 1, segl->color);
		}
		DrawWallSegmentFlat(&drawtex, texPal, CenterY);
    } else {
		drawtex.width = tex->width;
		drawtex.height = tex->height;
		drawtex.data = (Byte *)*tex->data;

		if (segl->color==0) {
			texPal = drawtex.data;
		} else {
			initColoredPals((uint16*)drawtex.data, texPal, 16, segl->color);
		}

		DrawWallSegment(&drawtex, texPal, CenterY);
    }
}

void DrawSeg(viswall_t *segl, ColumnStore *columnStoreData)
{
	viscol_t *viscol;

	Word xPos = segl->LeftX;
	const Word rightX = segl->RightX;

	const Fixed offset = segl->offset;
	const angle_t centerAngle = segl->CenterAngle;
	const Word distance = segl->distance >> VISWALL_DISTANCE_PRESHIFT;

	if (!(segl->WallActions & (AC_TOPTEXTURE|AC_BOTTOMTEXTURE))) return;

    drawtex.xStart = xPos;
    drawtex.xEnd = rightX;

    viscol = viscols;
    do {
        viscol->column = (offset-((finetangent[(centerAngle+xtoviewangle[xPos])>>ANGLETOFINESHIFT] * distance)>>(FRACBITS-VISWALL_DISTANCE_PRESHIFT)))>>FRACBITS;
        viscol->light = LightTablePtr[columnStoreData->light>>LIGHTSCALESHIFT];
        viscol->scale = columnStoreData->scale;
        viscol++;
		columnStoreData++;
    } while (++xPos <= rightX);

    if (segl->WallActions & AC_TOPTEXTURE)
        DrawSegAny(segl, true, false);

    if (segl->WallActions & AC_BOTTOMTEXTURE)
        DrawSegAny(segl, false, false);
}

void DrawSegFlat(viswall_t *segl, ColumnStore *columnStoreData)
{
	viscol_t *viscol;

	Word xPos = segl->LeftX;
	const Word rightX = segl->RightX;

	if (!(segl->WallActions & (AC_TOPTEXTURE|AC_BOTTOMTEXTURE))) return;

    drawtex.xStart = segl->LeftX;
    drawtex.xEnd = rightX;

    viscol = viscols;
    do {
        viscol->light = LightTablePtr[columnStoreData->light>>LIGHTSCALESHIFT];
        viscol->scale = columnStoreData->scale;
        viscol++;
		columnStoreData++;
    } while (++xPos <= rightX);

    if (segl->WallActions & AC_TOPTEXTURE)
        DrawSegAny(segl, true, true);

    if (segl->WallActions & AC_BOTTOMTEXTURE)
        DrawSegAny(segl, false, true);
}
