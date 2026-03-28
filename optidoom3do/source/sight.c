#include "Doom.h"
#include <IntMath.h>

static Fixed sightzstart;			// eye z of looker
static Fixed topslope, bottomslope;	// slopes to top and bottom of target

static vector_t strace;					// from t1 to t2
static Fixed t2x, t2y;

static int t1xs,t1ys,t2xs,t2ys;
static int sightdx, sightdy;	/* Precomputed sight ray direction (t2-t1) */


/*
=================
=
= PS_SightCrossLine
=
= Optimized: sight ray direction (sightdx/sightdy) precomputed in CheckSight.
= Eliminates redundant subtraction per call.
=================
*/

static Fixed PS_SightCrossLine (line_t *line)
{
	int			s1, s2;
	int			p1x,p1y,p2x,p2y,dx,dy,ndx,ndy;

// p1, p2 are line endpoints
	p1x = line->v1.x >> 16;
	p1y = line->v1.y >> 16;
	p2x = line->v2.x >> 16;
	p2y = line->v2.y >> 16;

// Side test using precomputed sight direction
	dx = p2x - t1xs;
	dy = p2y - t1ys;

	s1 =  (sightdy * dx) <  (dy * sightdx);

	dx = p1x - t1xs;
	dy = p1y - t1ys;

	s2 =  (sightdy * dx) <  (dy * sightdx);

	if (s1 == s2)
		return -1;			// line isn't crossed

	ndx = p1y - p2y;		// vector normal to world line
	ndy = p2x - p1x;

	s1 = ndx*dx + ndy*dy;	// distance projected onto normal

	dx = t2xs - p1x;
	dy = t2ys - p1y;

	s2 = ndx*dx + ndy*dy;	// distance projected onto normal

	s2 = IMFixDiv (s1,(s1+s2));

	return s2;
}

/*
=================
=
= PS_CrossSubsector
=
= Returns true if strace crosses the given subsector successfuly
=================
*/

static Boolean PS_CrossSubsector (subsector_t *sub)
{
	seg_t		*seg;
	line_t		*line;
	int			count;
	sector_t	*front, *back;
	Fixed		opentop, openbottom;
	Fixed		frac, slope;

//
// check lines
//
	count = sub->numsublines;
	seg = sub->firstline;

	for ( ; count ; seg++, count--)
	{
		line = seg->linedef;

		if (line->validcount == validcount)
			continue;		// allready checked other side
		line->validcount = validcount;

		frac = PS_SightCrossLine (line);

		if (frac < 4 || frac > FRACUNIT)
			continue;

	//
	// crosses line
	//
		back = line->backsector;
		if (!back)
			return FALSE;	// one sided line
		front = line->frontsector;

		if (front->floorheight == back->floorheight
		&& front->ceilingheight == back->ceilingheight)
			continue;		// no wall to block sight with

		if (front->ceilingheight < back->ceilingheight)
			opentop = front->ceilingheight;
		else
			opentop = back->ceilingheight;
		if (front->floorheight > back->floorheight)
			openbottom = front->floorheight;
		else
			openbottom = back->floorheight;

		if (openbottom >= opentop)	// quick test for totally closed doors
			return FALSE;	// stop

		frac >>= 2;

		if (front->floorheight != back->floorheight)
		{
			slope =  (((openbottom - sightzstart)<<6) / frac) << 8;
			if (slope > bottomslope)
				bottomslope = slope;
		}

		if (front->ceilingheight != back->ceilingheight)
		{
			slope = (((opentop - sightzstart)<<6) / frac) << 8;
			if (slope < topslope)
				topslope = slope;
		}

		if (topslope <= bottomslope)
			return FALSE;	// stop

	}


	return TRUE;			// passed the subsector ok
}

/*
=================
=
= PS_CrossBSPNode
=
= Returns true if strace crosses the given node successfuly
=================
*/

static Boolean PS_CrossBSPNode(node_t *bsp)
{

	Word side;

	if ((Word)bsp & 1) {
		return PS_CrossSubsector((subsector_t *)((LongWord)bsp&(~1UL)));
	}

//
// decide which side the start point is on
//
	side = PointOnVectorSide(strace.x, strace.y,&bsp->Line);

// cross the starting side

	if (!PS_CrossBSPNode((node_t *)bsp->Children[side]) )
		return FALSE;

// the partition plane is crossed here

	if (side == PointOnVectorSide(t2x,t2y,&bsp->Line))
		return TRUE;			// the line doesn't touch the other side

// cross the ending side
	return PS_CrossBSPNode((node_t *)bsp->Children[side^1]);
}

/**********************************

	Returns true if a straight line between t1 and t2 is unobstructed

**********************************/

Word CheckSight(mobj_t *t1,mobj_t *t2)
{
	int	s1, s2;
	int	pnum, bytenum, bitnum;

//
// check for trivial rejection
//
	s1 = (t1->subsector->sector - sectors);
	s2 = (t2->subsector->sector - sectors);
	pnum = s1*numsectors + s2;
	bytenum = pnum>>3;
	bitnum = 1 << (pnum&7);

	if (RejectMatrix[bytenum]&bitnum) {
		return FALSE;	// can't possibly be connected
	}

// look from eyes of t1 to any part of t2

	++validcount;

// make sure it never lies exactly on a vertex coordinate

	strace.x = (t1->x & ~0x1ffff) | 0x10000;
	strace.y = (t1->y & ~0x1ffff) | 0x10000;
	t2x = (t2->x & ~0x1ffff) | 0x10000;
	t2y = (t2->y & ~0x1ffff) | 0x10000;
	strace.dx = t2x - strace.x;
	strace.dy = t2y - strace.y;

	t1xs = strace.x >> 16;
	t1ys = strace.y >> 16;
	t2xs = t2x >> 16;
	t2ys = t2y >> 16;
	sightdx = t2xs - t1xs;		/* Precompute sight ray direction */
	sightdy = t2ys - t1ys;

	sightzstart = t1->z + t1->height - (t1->height>>2);
	topslope = (t2->z+t2->height) - sightzstart;
	bottomslope = (t2->z) - sightzstart;

	return PS_CrossBSPNode(FirstBSPNode);
}


