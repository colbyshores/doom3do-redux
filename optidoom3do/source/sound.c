#include "Doom.h"
#include <IntMath.h>
#include <audio.h>
#include <soundfile.h>
#include <kernel.h>
#include "stdio.h"

#define S_CLIPPING_DIST (3600*0x10000)		/* Clip sounds beyond this distance */
#define S_CLOSE_DIST (200*0x10000)			/* Too close! */
#define S_ATTENUATOR ((S_CLIPPING_DIST-S_CLOSE_DIST)>>FRACBITS)
#define S_STEREO_SWING (96*0x10000)

/**********************************

	Clear the sound buffers and stop all sound

**********************************/

void S_Clear(void)
{
	Word i;
	i = 1;
	do {
		StopSound(i);
	} while (++i<NUMSFX);
}

/**********************************

	Start a new sound, use the origin to affect
	the stereo panning

**********************************/

void S_StartSound(Fixed *OriginXY,Word sound_id)
{
	Fixed dist;
	angle_t angle;
	int vol;
	int sep;
	
	if (sound_id<NUMSFX && sound_id) {
		if (OriginXY) {
			mobj_t *Listener;
			
			Listener = players.mo;
			if (OriginXY!=&Listener->x) {
				dist = GetApproxDistance(Listener->x-OriginXY[0],Listener->y-OriginXY[1]);
				if (dist>S_CLIPPING_DIST) {
					return;			/* Too far away! */
				}
				angle = PointToAngle(Listener->x,Listener->y,OriginXY[0],OriginXY[1]);
				angle = angle-Listener->angle;			
				angle>>=ANGLETOFINESHIFT;
				if (dist>=S_CLOSE_DIST) {
					vol = (255 * ((S_CLIPPING_DIST-dist)>>FRACBITS))/S_ATTENUATOR;
					if (!vol) {		/* Too quiet? */
						return;
					}
					sep = 128-(IMFixMul(S_STEREO_SWING,finesine[angle])>>FRACBITS);
					RightVolume = (sep*vol)>>8;
					LeftVolume = ((256-sep)*vol)>>8;
				}
			}
		}
		PlaySound(sound_id);
	}
}

/**********************************

	Start music

**********************************/

static Byte SongLookup[] = {
	 0,
	 11,	/* Intro */
	 12, /* Final */
	 3,	/* Bunny */
	 5,	/* Intermission */
	 5, 6, 7, 8, 9,10,11,12,13,14,	/* Map 1 */
	15, 5, 6, 7, 8, 9,10,11,13,14,
	15,10,12,29, 1, 1, 1, 1, 1, 1,
	1
};

/* --- Custom SoundFilePlayer-based music --- */

#define MUSIC_NUM_BUFS  4
#define MUSIC_BUF_SIZE  (32 * 1024)   /* 32KB × 4 bufs = ~740ms buffered at 44100Hz stereo */

static SoundFilePlayer *gMusicPlayer  = NULL;
static Boolean          gMusicLooping = FALSE;

/**********************************

	Per-frame music service — call once per frame.
	Uses GetCurrentSignals() for a non-blocking poll;
	WaitSignal() returns instantly when signals are already pending.

**********************************/

void MusicUpdate(void)
{
	int32 pending, neededSigs;

	if (!gMusicPlayer) return;

	pending = GetCurrentSignals() & gMusicPlayer->sfp_Spooler->sspl_SignalMask;
	if (!pending) return;

	WaitSignal(pending);   /* consume — instant, signals are already pending */
	ServiceSoundFile(gMusicPlayer, pending, &neededSigs);

	/* Loop: rewind and restart when all buffers have played through */
	if (gMusicLooping &&
	    gMusicPlayer->sfp_BuffersPlayed >= gMusicPlayer->sfp_BuffersToPlay) {
		RewindSoundFile(gMusicPlayer);
		StartSoundFile(gMusicPlayer, MAXDSPAMPLITUDE);
	}
}

/**********************************

	Start music

**********************************/

void S_StartSong(Word music_id,Boolean looping)
{
	char path[48];
	Byte songNum;

	if (music_id >= sizeof(SongLookup)) return;
	songNum = SongLookup[music_id];
	if (songNum == 0) return;

	S_StopSong();

	sprintf(path, "$app/Music/Song%d", (int)songNum);
	gMusicPlayer = OpenSoundFile(path, MUSIC_NUM_BUFS, MUSIC_BUF_SIZE);
	if (!gMusicPlayer) return;

	gMusicLooping = looping;
	StartSoundFile(gMusicPlayer, MAXDSPAMPLITUDE);
}

/**********************************

    Stop music

**********************************/

void S_StopSong(void)
{
	if (!gMusicPlayer) return;
	StopSoundFile(gMusicPlayer);
	CloseSoundFile(gMusicPlayer);
	gMusicPlayer = NULL;
}
