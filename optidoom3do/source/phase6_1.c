#include "Doom.h"
#include <IntMath.h>

#define OPENMARK ((MAXSCREENHEIGHT-1)<<8)

static BitmapCCB CCBArraySky[MAXSCREENWIDTH];       // Array of CCB struct for the sky columns

int clipboundtop[MAXSCREENWIDTH];		// Bounds top y for vertical clipping
int clipboundbottom[MAXSCREENWIDTH];	// Bounds bottom y for vertical clipping

bool skyOnView;                         // marker to know if at one frame sky was visible or not


void initCCBarraySky(void)
{
	BitmapCCB *CCBPtr;
	int i;

	const int skyScale = (Fixed)(1048576.0 * ((float)ScreenHeight / 160.0));

	CCBPtr = CCBArraySky;
	for (i=0; i<MAXSCREENWIDTH; ++i) {
		CCBPtr->ccb_NextPtr = (BitmapCCB *)(sizeof(BitmapCCB)-8);	// Create the next offset

		// Set all the defaults
        CCBPtr->ccb_Flags = CCB_SPABS|CCB_LDSIZE|CCB_LDPPMP|CCB_CCBPRE|CCB_YOXY|CCB_ACW|CCB_ACCW|
                            CCB_ACE|CCB_BGND|/*CCB_NOBLK|*/CCB_PPABS;	// ccb_flags

        if (i==0) CCBPtr->ccb_Flags |= CCB_LDPLUT;  // First CEL column will set the palette for the rest

        CCBPtr->ccb_PRE0 = 0x03;
        CCBPtr->ccb_PRE1 = 0x3E005000|(128-1);  // Project the pixels
        CCBPtr->ccb_YPos = 0<<16;
        CCBPtr->ccb_HDX = 0<<20;		        // Convert 6 bit frac to CCB scale
        CCBPtr->ccb_HDY = skyScale;             // Video stretch factor
        CCBPtr->ccb_VDX = 1<<16;
        CCBPtr->ccb_VDY = 0<<16;
        CCBPtr->ccb_PIXC = 0x1F00;              // PIXC control

		++CCBPtr;
	}
}


/**********************************

	Given a span of pixels, see if it is already defined
	in a record somewhere. If it is, then merge it otherwise
	make a new plane definition.

	Uses a direct-mapped hash cache for O(1) lookup in the common
	case (adjacent wall segments sharing the same floor/ceiling).

**********************************/

int visplanesCountMax = 0;
bool isFloor;   /* exported — planeclip.s imports for SegLoopFloorCeiling_ASM rare paths */

#define PLANE_HASH_BITS 5
#define PLANE_HASH_SIZE (1 << PLANE_HASH_BITS)
#define PLANE_HASH_MASK (PLANE_HASH_SIZE - 1)

static visplane_t *planeHash[PLANE_HASH_SIZE];

void ClearPlaneHash(void)
{
	Word i = 0;
	do {
		planeHash[i] = 0;
	} while (++i < PLANE_HASH_SIZE);
}

static Word PlaneHashKey(Fixed height, void **PicHandle, Word Light, Word color, Word special)
{
	Word h = (Word)(height >> FRACBITS);
	h ^= (Word)((LongWord)PicHandle >> 2);
	h ^= Light * 7;
	h ^= color;
	h ^= special << 3;
	return h & PLANE_HASH_MASK;
}

visplane_t *FindPlane(visplane_t *check, viswall_t *segl, int start, Word color)
{
	const Fixed height = segl->floorheight;
	void **PicHandle = segl->FloorPic;
	const int stop = segl->RightX;
	const Word Light = segl->seglightlevel;
	const Word special = segl->special & SEC_SPEC_RENDER_BITS;
	Word hk;
	visplane_t *cached;

	if (visplanesCount > maxVisplanes-2) return 0;

	/* Fast path: check hash cache first */
	hk = PlaneHashKey(height, PicHandle, Light, color, special);
	cached = planeHash[hk];
	if (cached &&
		height == cached->height &&
		PicHandle == cached->PicHandle &&
		Light == cached->PlaneLight &&
		color == cached->color &&
		special == cached->special &&
		cached->open[start] == OPENMARK) {
		if (start < cached->minx) {
			cached->minx = start;
		}
		if (stop > cached->maxx) {
			cached->maxx = stop;
		}
		return cached;
	}

	/* Hash miss — fall back to linear scan */
	++check;		/* Automatically skip to the next plane */
	if (check<lastvisplane) {
		do {
			if (height == check->height &&		/* Same plane as before? */
				PicHandle == check->PicHandle &&
				Light == check->PlaneLight &&
				color == check->color &&
				special == check->special &&
				check->open[start] == OPENMARK) {	/* Not defined yet? */
				if (start < check->minx) {	/* In range of the plane? */
					check->minx = start;	/* Mark the new edge */
				}
				if (stop > check->maxx) {
					check->maxx = stop;		/* Mark the new edge */
				}
				planeHash[hk] = check;		/* Update hash cache */
				return check;			/* Use the same one as before */
			}
		} while (++check<lastvisplane);
	}

/* make a new plane */

	check = lastvisplane;
	++lastvisplane;
	++visplanesCount;
	check->height = height;		/* Init all the vars in the visplane */
	check->PicHandle = PicHandle;
	check->flatIndex = segl->flatFloorIdx;	/* For 32x32 mipmap lookup */
	check->color = color;
	check->special = special;
	check->isFloor = isFloor;
	check->minx = start;
	check->maxx = stop;
	check->PlaneLight = Light;		/* Set the light level */

	if (visplanesCount > visplanesCountMax) visplanesCountMax = visplanesCount;

/* Quickly fill in the visplane table */
    {
        Word i, j;
        Word *set;

        i = OPENMARK;
        set = check->open;	/* A brute force method to fill in the visplane record FAST! */
        j = ScreenWidth/4;
        do {
            set[0] = i;
            set[1] = i;
            set[2] = i;
            set[3] = i;
            set+=4;
        } while (--j);

        check->miny = MAXSCREENHEIGHT;
        check->maxy = -1;
    }
	planeHash[hk] = check;		/* Insert new plane into hash cache */
	return check;
}


/**********************************

	Do a fake wall rendering so I can get all the visplane records.
	This is a fake-o routine so I can later draw the wall segments from back to front.

**********************************/

/* ARM assembly inner loops in planeclip.s — branchless MUL+clamp+store */
extern void SegLoopFloor_ASM(viswall_t *segl, Word screenCenterY, visplane_t *plane, Word color);
extern void SegLoopCeiling_ASM(viswall_t *segl, Word screenCenterY, visplane_t *plane, Word color);

static void SegLoopFloor(viswall_t *segl, Word screenCenterY)
{
	Word color;

	color = segl->color;

	isFloor = true;
	SegLoopFloor_ASM(segl, screenCenterY, visplanes, color);
}

static void SegLoopCeiling(viswall_t *segl, Word screenCenterY)
{
	Word color;
	const int ceilingHeight = segl->ceilingheight;

	color = segl->color;

	isFloor = false;

	/* Ugly hack: FindPlane always reads floor fields, so alias ceiling into them */
	segl->floorheight = ceilingHeight;
	segl->FloorPic = segl->CeilingPic;
	segl->flatFloorIdx = segl->flatCeilIdx;

	SegLoopCeiling_ASM(segl, screenCenterY, visplanes, color);
}

/* Fused floor+ceiling pass — both floor and ceiling in one loop.
   Called when both AC_ADDFLOOR and AC_ADDCEILING are set.
   segl is NOT pre-aliased; aliasing for ceiling FindPlane is handled inside the ASM. */
extern void SegLoopFloorCeiling_ASM(viswall_t *segl, Word screenCenterY,
                                     visplane_t *floorPlane, Word floorColor,
                                     visplane_t *ceilPlane,  Word ceilColor);

static void SegLoopFloorCeiling(viswall_t *segl, Word screenCenterY)
{
	Word floorColor, ceilColor;

	floorColor = ceilColor = segl->color;

	isFloor = true;
	SegLoopFloorCeiling_ASM(segl, screenCenterY, visplanes, floorColor, visplanes, ceilColor);
}

/* ARM assembly versions in silclip.s — branchless inner loops */
extern void SegLoopSpriteClipsBottom(viswall_t *segl, Word screenCenterY);
extern void SegLoopSpriteClipsTop(viswall_t *segl, Word screenCenterY);
/* Fused both-pass: called only when AC_BOTTOMSIL|AC_NEWFLOOR|AC_TOPSIL|AC_NEWCEILING all set */
extern void SegLoopSpriteClipsBoth(viswall_t *segl, Word screenCenterY);
#define SIL_BOTH_MASK (AC_BOTTOMSIL|AC_NEWFLOOR|AC_TOPSIL|AC_NEWCEILING)


static void SegLoopSky(viswall_t *segl, Word screenCenterY)
{
	BitmapCCB *CCBPtr = &CCBArraySky[0];
    Byte *Source = (Byte *)(*SkyTexture->data);

	const int ceilingHeight = segl->ceilingheight;
	int scalefrac = segl->LeftScale;
	const int scalestep = segl->ScaleStep;

    Word x = segl->LeftX;
	const Word rightX = segl->RightX;
    do {
		int scale;
		int ceilingclipy;
		int floorclipy;
		int bottom;

		scale = scalefrac >> FIXEDTOSCALE;
		if (scale >= 0x2000) scale = 0x1fff;
		ceilingclipy = clipboundtop[x];
		floorclipy = clipboundbottom[x];

        bottom = screenCenterY - ((scale * ceilingHeight)>>(HEIGHTBITS+SCALEBITS));
        if (bottom > floorclipy) {
            bottom = floorclipy;
        }
        if ((ceilingclipy+1) < bottom) {
            CCBPtr->ccb_XPos = x<<16;
            CCBPtr->ccb_SourcePtr = (CelData *)&Source[((((xtoviewangle[x]+viewangle)>>ANGLETOSKYSHIFT)&0xFF)<<6) + 32];
            ++CCBPtr;
        }
        scalefrac += scalestep;
	} while (++x<=rightX);


	if (CCBPtr != &CCBArraySky[0]) {
        CCBArraySky[0].ccb_PLUTPtr = Source;    // plut pointer only for first element
        drawCCBarray(--CCBPtr, CCBArraySky);
	}
}

static void prepColumnStoreDataUnlit(viswall_t *segl, bool forceDark)
{
	Word x = segl->LeftX;
	const Word rightX = segl->RightX;

	int _scalefrac = segl->LeftScale;
	const int _scalestep = segl->ScaleStep;

    ColumnStore *columnStoreData = columnStoreArrayData;

	int wallColumnLight = segl->seglightlevelContrast;
	if (forceDark || optGraphics->depthShading == DEPTH_SHADING_DARK) wallColumnLight = lightmins[wallColumnLight];

	do {
        int scale = _scalefrac>>FIXEDTOSCALE;
		if (scale >= 0x2000) {
			scale = 0x1fff;
		}

		columnStoreData->scale = scale;
		columnStoreData->light = wallColumnLight;
		columnStoreData++;

        _scalefrac += _scalestep;
	} while (++x<=rightX);
	columnStoreArrayData = columnStoreData;
}


extern void ColStoreFused_ASM(int x, int rightX,
                              int scalefrac, int scalestep,
                              ColumnStore *col,
                              int lightcoefF, int perColStep,
                              int lightmin, int lightmax, int lightsub);

static void prepColumnStoreData(viswall_t *segl)
{
	const Word leftX  = segl->LeftX;
	const Word rightX = segl->RightX;
	const Word lightIndex = segl->seglightlevelContrast;
	const int  lc = lightcoefs[lightIndex] >> 4;

	const int lightcoefF  = ((segl->LeftScale  >> 4) * lc) >> (2 * FIXEDTOSCALE - 8);
	const int perColStep  = ((segl->ScaleStep   >> 4) * lc) >> (2 * FIXEDTOSCALE - 8);

	ColStoreFused_ASM(leftX, rightX,
	                  segl->LeftScale, segl->ScaleStep,
	                  columnStoreArrayData,
	                  lightcoefF, perColStep,
	                  lightmins[lightIndex], lightIndex, lightsubs[lightIndex]);

	columnStoreArrayData += rightX - leftX + 1;
}

/*
Culling idea that didn't work well so far (bugs, walls dissapear, not actually doing the clipping even)
Commenting out and will revisit in the future.
I am checking wall segment top bottom but those should be different depending if it's a mid wall or upper/lower walls separately.
Will even need to do this check at other places separately but mark for the renderer what to and not to render.
It's pretty hard to pull without destroying the visuals and actually not even gaining speed in most cases.

bool isSegWallOccluded(viswall_t *segl)
{

	const bool silsTop = segl->WallActions & (AC_TOPSIL|AC_NEWCEILING);
	const bool silsBottom = segl->WallActions & (AC_BOTTOMSIL|AC_NEWFLOOR);

	if (!silsTop && silsBottom) {
		const int xl = segl->LeftX;
		const int xr = segl->RightX;

		const int scaleLeft = (int)(segl->LeftScale >> FIXEDTOSCALE);
		const int scaleRight = (int)(segl->RightScale >> FIXEDTOSCALE);
		const int floorNewHeight = segl->floornewheight;
		const int ceilingNewHeight = segl->ceilingnewheight;

		const int bottomLeft = CenterY - ((scaleLeft * floorNewHeight)>>(HEIGHTBITS+SCALEBITS));
		const int bottomRight = CenterY - ((scaleRight * floorNewHeight)>>(HEIGHTBITS+SCALEBITS));

		if (bottomLeft < clipboundtop[xl] && bottomRight < clipboundtop[xr]) {
			const int topLeft = (CenterY-1) - ((scaleLeft * ceilingNewHeight)>>(HEIGHTBITS+SCALEBITS));
			const int topRight = (CenterY-1) - ((scaleRight * ceilingNewHeight)>>(HEIGHTBITS+SCALEBITS));

			if (segl->WallActions & AC_ADDSKY) {
				skyOnView = true;
			}

			if (topLeft > clipboundbottom[xl] && topRight > clipboundbottom[xr]) return true;
		}
	}
	return false;
}*/

void SegLoop(viswall_t *segl)
{
startBenchPeriod(4, "ColStore");
	if (optGraphics->renderer == RENDERER_DOOM) {
		if (optGraphics->depthShading >= DEPTH_SHADING_DITHERED) {
			if (segl->renderKind >= VW_MID) {
				prepColumnStoreDataUnlit(segl, true);
			} else {
				prepColumnStoreData(segl);
			}
		} else {
			prepColumnStoreDataUnlit(segl, false);
		}
	}
endBenchPeriod(4);

// Floor + ceiling: fuse into one pass when both active
	{
		const bool addFloor   = segl->WallActions & AC_ADDFLOOR;
		const bool addCeiling = segl->WallActions & AC_ADDCEILING;
		if (addFloor && addCeiling) {
startBenchPeriod(5, "FloorPlane");
			SegLoopFloorCeiling(segl, CenterY);
endBenchPeriod(5);
		} else if (addFloor) {
startBenchPeriod(5, "FloorPlane");
			SegLoopFloor(segl, CenterY);
endBenchPeriod(5);
		} else if (addCeiling) {
startBenchPeriod(6, "CeilPlane");
			SegLoopCeiling(segl, CenterY);
endBenchPeriod(6);
		}
	}

// Sky must run BEFORE silclip: silclip updates clipboundtop/clipboundbottom,
// but SegLoopSky needs the pre-silclip values (old code cached them in segloops[]).
    if (segl->WallActions & AC_ADDSKY) {
        skyOnView = true;
        if (optOther->sky==SKY_DEFAULT) {
startBenchPeriod(8, "Sky");
            SegLoopSky(segl, CenterY);
endBenchPeriod(8);
        }
    }

// Sprite clip sils (updates clipboundtop/clipboundbottom for subsequent segments)
	{
		const bool silsTop = segl->WallActions & (AC_TOPSIL|AC_NEWCEILING);
		const bool silsBottom = segl->WallActions & (AC_BOTTOMSIL|AC_NEWFLOOR);

		if (silsTop || silsBottom) {
startBenchPeriod(7, "SpriteSil");
			if (silsTop && silsBottom) {
				if ((segl->WallActions & SIL_BOTH_MASK) == SIL_BOTH_MASK) {
					SegLoopSpriteClipsBoth(segl, CenterY);
				} else {
					SegLoopSpriteClipsTop(segl, CenterY);
					SegLoopSpriteClipsBottom(segl, CenterY);
				}
			} else if (silsBottom) {
				SegLoopSpriteClipsBottom(segl, CenterY);
			} else {
				SegLoopSpriteClipsTop(segl, CenterY);
			}
endBenchPeriod(7);
		}
	}
}

void PrepareSegLoop()
{
    int *top = clipboundtop;
    int *bot = clipboundbottom;
    Word count = ScreenWidth;
    do {
        *top++ = -1;
        *bot++ = ScreenHeight;
    } while (--count);
}
