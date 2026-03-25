#include "Doom.h"
#include <IntMath.h>

#define OPENMARK ((MAXSCREENHEIGHT-1)<<8)

static BitmapCCB CCBArraySky[MAXSCREENWIDTH];       // Array of CCB struct for the sky columns

typedef struct {
	int scale;
	int ceilingclipy;
	int floorclipy;
} segloop_t;


int clipboundtop[MAXSCREENWIDTH];		// Bounds top y for vertical clipping
int clipboundbottom[MAXSCREENWIDTH];	// Bounds bottom y for vertical clipping

segloop_t segloops[MAXSCREENWIDTH];

bool skyOnView;                         // marker to know if at one frame sky was visible or not


void initCCBarraySky(void)
{
	BitmapCCB *CCBPtr;
	int i;

	const int skyScale = getSkyScale();

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
static bool isFloor;

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

	if (optGraphics->planeQuality == PLANE_QUALITY_LO) {
		const Word floorColor = segl->floorAndCeilingColor >> 16;
		color = (floorColor << 16) | floorColor | (1 << 15);
	} else {
		color = segl->color;
	}

	isFloor = true;
	SegLoopFloor_ASM(segl, screenCenterY, visplanes, color);
}

static void SegLoopCeiling(viswall_t *segl, Word screenCenterY)
{
	Word color;
	const int ceilingHeight = segl->ceilingheight;

	if (optGraphics->planeQuality == PLANE_QUALITY_LO) {
		const Word ceilingColor = segl->floorAndCeilingColor & 0x0000FFFF;
		color = (ceilingColor << 16) | ceilingColor | (1 << 15);
	} else {
		color = segl->color;
	}

	isFloor = false;

	/* Ugly hack: FindPlane always reads floor fields, so alias ceiling into them */
	segl->floorheight = ceilingHeight;
	segl->FloorPic = segl->CeilingPic;
	segl->flatFloorIdx = segl->flatCeilIdx;

	SegLoopCeiling_ASM(segl, screenCenterY, visplanes, color);
}

/* ARM assembly versions in silclip.s — branchless inner loops */
extern void SegLoopSpriteClipsBottom(viswall_t *segl, Word screenCenterY);
extern void SegLoopSpriteClipsTop(viswall_t *segl, Word screenCenterY);


static void SegLoopSky(viswall_t *segl, Word screenCenterY)
{
	int scale;
	int ceilingclipy, floorclipy;
	int bottom;

	BitmapCCB *CCBPtr = &CCBArraySky[0];
    Byte *Source = (Byte *)(*SkyTexture->data);

	segloop_t *segdata = segloops;

	const int ceilingHeight = segl->ceilingheight;

    Word x = segl->LeftX;
	const Word rightX = segl->RightX;
    do {
		scale = segdata->scale;
		ceilingclipy = segdata->ceilingclipy;
		floorclipy = segdata->floorclipy;

        bottom = screenCenterY - ((scale * ceilingHeight)>>(HEIGHTBITS+SCALEBITS));
        if (bottom > floorclipy) {
            bottom = floorclipy;
        }
        if ((ceilingclipy+1) < bottom) {		// Valid?
            CCBPtr->ccb_XPos = x<<16;                               // Set the x and y coord for start
            CCBPtr->ccb_SourcePtr = (CelData *)&Source[((((xtoviewangle[x]+viewangle)>>ANGLETOSKYSHIFT)&0xFF)<<6) + 32];	// Get the source ptr
            ++CCBPtr;
        }
        segdata++;
	} while (++x<=rightX);


	if (CCBPtr != &CCBArraySky[0]) {
        CCBArraySky[0].ccb_PLUTPtr = Source;    // plut pointer only for first element
        drawCCBarray(--CCBPtr, CCBArraySky);
	}
}

static void prepColumnStoreDataPoly(viswall_t *segl)
{
	Word x = segl->LeftX;
	const Word rightX = segl->RightX;

	int _scalefrac = segl->LeftScale;
	const int _scalestep = segl->ScaleStep;

    segloop_t *segdata = segloops;
    ColumnStore *columnStoreData = columnStoreArrayData;

	do {
        int scale = _scalefrac>>FIXEDTOSCALE;
		if (scale >= 0x2000) {
			scale = 0x1fff;
		}

		columnStoreData->scale = scale;
		columnStoreData++;
		segdata->scale = scale;
		segdata->ceilingclipy = clipboundtop[x];
		segdata->floorclipy = clipboundbottom[x];
        segdata++;

        _scalefrac += _scalestep;
	} while (++x<=rightX);

	columnStoreArrayData = columnStoreData;
}

static void prepColumnStoreDataUnlit(viswall_t *segl, bool forceDark)
{
	Word x = segl->LeftX;
	const Word rightX = segl->RightX;

	int _scalefrac = segl->LeftScale;
	const int _scalestep = segl->ScaleStep;

    segloop_t *segdata = segloops;
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
		segdata->scale = scale;
		segdata->ceilingclipy = clipboundtop[x];
		segdata->floorclipy = clipboundbottom[x];
        segdata++;

        _scalefrac += _scalestep;
	} while (++x<=rightX);
	columnStoreArrayData = columnStoreData;
}

static void prepColumnStoreDataLight(viswall_t *segl)
{
	Word x;
	const Word leftX = segl->LeftX + 4;
	const Word rightX = segl->RightX;

    ColumnStore *columnStoreData = columnStoreArrayData;

	const Word lightIndex = segl->seglightlevelContrast;
    const Fixed lightminF = lightmins[lightIndex];
    const Fixed lightmaxF = lightIndex;
	const Fixed lightsub = lightsubs[lightIndex];
	Fixed lightcoefF = ((segl->LeftScale >> 4) * (lightcoefs[lightIndex] >> 4)) >> (2 * FIXEDTOSCALE - 8);
	Fixed lightcoefFstep = 4 * (((segl->ScaleStep >> 4) * (lightcoefs[lightIndex] >> 4)) >> (2 * FIXEDTOSCALE - 8));

	int prevWallColumnLight = (lightcoefF >> (16 - FIXEDTOSCALE)) - lightsub;
	if (prevWallColumnLight < lightminF) prevWallColumnLight = lightminF;
	if (prevWallColumnLight > lightmaxF) prevWallColumnLight = lightmaxF;
	lightcoefF += lightcoefFstep;
	columnStoreData->light = prevWallColumnLight;
	columnStoreData++;

	for (x=leftX; x<=rightX; x+=4) {
		int wallColumnLightHalf;
		int wallColumnLight = (lightcoefF >> (16 - FIXEDTOSCALE)) - lightsub;
        if (wallColumnLight < lightminF) wallColumnLight = lightminF;
        if (wallColumnLight > lightmaxF) wallColumnLight = lightmaxF;
		lightcoefF += lightcoefFstep;
		
		wallColumnLightHalf = (prevWallColumnLight + wallColumnLight) >> 1;

		columnStoreData[0].light = (prevWallColumnLight + wallColumnLightHalf) >> 1;
		columnStoreData[1].light = wallColumnLightHalf;
		columnStoreData[2].light = (wallColumnLightHalf + wallColumnLight) >> 1;
		columnStoreData[3].light = wallColumnLight;
		columnStoreData+=4;

		prevWallColumnLight = wallColumnLight;
	}
	lightcoefFstep >>= 2;
	for (x-=3; x<=rightX; ++x) {
		prevWallColumnLight = (lightcoefF >> (16 - FIXEDTOSCALE)) - lightsub;
		if (prevWallColumnLight < lightminF) prevWallColumnLight = lightminF;
		if (prevWallColumnLight > lightmaxF) prevWallColumnLight = lightmaxF;
		lightcoefF += lightcoefFstep;
		columnStoreData->light = prevWallColumnLight;
		columnStoreData++;
	}
}

static void prepColumnStoreData(viswall_t *segl)
{
	Word x = segl->LeftX;
	const Word rightX = segl->RightX;

	int _scalefrac = segl->LeftScale;
	const int _scalestep = segl->ScaleStep;

    segloop_t *segdata = segloops;
    ColumnStore *columnStoreData = columnStoreArrayData;

	do {
        int scale = _scalefrac>>FIXEDTOSCALE;
		if (scale >= 0x2000) {
			scale = 0x1fff;
		}

		columnStoreData->scale = scale;
		columnStoreData++;
		segdata->scale = scale;
		segdata->ceilingclipy = clipboundtop[x];
		segdata->floorclipy = clipboundbottom[x];
        segdata++;

        _scalefrac += _scalestep;
	} while (++x<=rightX);

	prepColumnStoreDataLight(segl);

	columnStoreArrayData = columnStoreData;
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
	} else {
		if (segl->renderKind >= VW_FAR) {
			prepColumnStoreDataUnlit(segl, optGraphics->depthShading >= DEPTH_SHADING_DITHERED);
		} else {
			prepColumnStoreDataPoly(segl);
		}
	}
endBenchPeriod(4);

// Shall I add the floor?
    if (segl->WallActions & AC_ADDFLOOR) {
startBenchPeriod(5, "FloorPlane");
        SegLoopFloor(segl, CenterY);
endBenchPeriod(5);
    }

// Handle ceilings
    if (segl->WallActions & AC_ADDCEILING) {
startBenchPeriod(6, "CeilPlane");
        SegLoopCeiling(segl, CenterY);
endBenchPeriod(6);
    }

// Sprite clip sils
	{
		const bool silsTop = segl->WallActions & (AC_TOPSIL|AC_NEWCEILING);
		const bool silsBottom = segl->WallActions & (AC_BOTTOMSIL|AC_NEWFLOOR);

		if (silsTop || silsBottom) {
startBenchPeriod(7, "SpriteSil");
			if (silsTop && silsBottom) {
				SegLoopSpriteClipsTop(segl, CenterY);
				SegLoopSpriteClipsBottom(segl, CenterY);
			} else if (silsBottom) {
				SegLoopSpriteClipsBottom(segl, CenterY);
			} else {
				SegLoopSpriteClipsTop(segl, CenterY);
			}
endBenchPeriod(7);
		}
	}

// I can draw the sky right now!!
    if (!enableWireframeMode) {
        if (segl->WallActions & AC_ADDSKY) {
            skyOnView = true;
            if (optOther->sky==SKY_DEFAULT) {
startBenchPeriod(8, "Sky");
                SegLoopSky(segl, CenterY);
endBenchPeriod(8);
            }
        }
    }
}

void PrepareSegLoop()
{
    Word i = 0;		// Init the vertical clipping records
    do {
        clipboundtop[i] = -1;		// Allow to the ceiling
        clipboundbottom[i] = ScreenHeight;	// Stop at the floor
    } while (++i<ScreenWidth);
}
