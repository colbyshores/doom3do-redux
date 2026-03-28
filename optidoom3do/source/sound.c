#include "Doom.h"
#include <IntMath.h>
#include <audio.h>
#include <soundspooler.h>
#include <filefunctions.h>
#include <driver.h>
#include <device.h>
#include <cdrom.h>
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
	 12,	/* Final */
	 3,		/* Bunny */
	 5,		/* Intermission */
	 5, 6, 7, 8, 9,10,11,12,13,14,	/* Map 1 */
	15, 5, 6, 7, 8, 9,10,11,13,14,
	15,10,12,29, 1, 1, 1, 1, 1, 1,
	1
};

#ifdef ENABLE_MUSIC

/**********************************

	Raw CDROM streaming music player.

	Bypasses Portfolio filesystem (which hits a 3-4 read limit per file
	in Opera emulator) by reading sectors directly via the "CD-ROM" device.

	KEY DISCOVERY: The CDROM device CMD_READ uses physical sector numbers
	(LBA + 150 pregap frames), not logical ISO sector numbers. To read
	logical sector N, pass ioi_Offset = N + 150.

	DSP chain: dcsqxdstereo.dsp (SDX2 decode) -> directout.dsp (DAC).
	Spooler signals polled non-blocking via GetCurrentSignals()/WaitSignal().

**********************************/

#define MUSIC_NUM_BUFS  2
#define MUSIC_BUF_SIZE  32768	/* 16 sectors; ~1.5 sec at 22050Hz SDX2 stereo */

/*
 * Logical ISO sector for the start of each Song file on disc.
 * Determined from the 3DO filesystem directory at sector 79447.
 * The actual AIFF-C data begins at avatar[0]+1 (the catalog block
 * is at avatar[0]; FORM header is at the following sector).
 *
 * Unused slots (no file on disc) are 0.
 */
static const uint32 gSongDiscSector[30] = {
	0,      /* 0: unused */
	4340,   /* Song1  */
	0,      /* 2: unused */
	42095,  /* Song3  */
	0,      /* 4: unused */
	44728,  /* Song5  */
	50098,  /* Song6  */
	56788,  /* Song7  */
	64159,  /* Song8  */
	71317,  /* Song9  */
	4722,   /* Song10 */
	8246,   /* Song11 */
	14557,  /* Song12 */
	20934,  /* Song13 */
	27145,  /* Song14 */
	32059,  /* Song15 */
	0,0,0,0,0,0,0,0,0,0,0,0,0, /* Song16-28: unused */
	36330   /* Song29 */
};

static struct {
	Item         cdromDevice;	/* raw "CD-ROM" device item */
	Item         cdromIOReq;	/* IOReq for raw sector reads */
	Item         instrument;	/* dcsqxdstereo.dsp */
	Item         outputIns;		/* directout.dsp */
	SoundSpooler *spooler;
	char         *bufs[MUSIC_NUM_BUFS];
	uint32  discSector;		/* logical ISO sector of song AIFF start */
	uint32  ssndStart;		/* byte offset of audio data within first sector */
	uint32  ssndSize;		/* total audio bytes in SSND chunk */
	uint32  readPos;		/* bytes of audio data queued so far */
	Boolean looping;
	Boolean active;
} gM;

/*
 * Parse the first 2048-byte sector of an AIFF-C file.
 * Locates the SSND chunk and records its position/size in gM.
 * Returns 1 on success, 0 if not a valid AIFF-C file.
 */
static int musicParseHeader(Byte *buf, uint32 len)
{
	uint32 pos;
	uint32 formSize;
	uint32 chunkId;
	uint32 chunkSize;
	uint32 w0, w1;

	if (len < 12) return 0;
	w0 = ((uint32)buf[0]<<24)|((uint32)buf[1]<<16)|((uint32)buf[2]<<8)|buf[3];
	w1 = ((uint32)buf[8]<<24)|((uint32)buf[9]<<16)|((uint32)buf[10]<<8)|buf[11];
	if (w0 != 0x464F524Du) return 0;	/* 'FORM' */
	if (w1 != 0x41494643u) return 0;	/* 'AIFC' */

	formSize = ((uint32)buf[4]<<24)|((uint32)buf[5]<<16)|((uint32)buf[6]<<8)|buf[7];
	pos = 12;

	while (pos + 8 <= len && pos < formSize + 8u) {
		chunkId   = ((uint32)buf[pos]<<24)|((uint32)buf[pos+1]<<16)|
		            ((uint32)buf[pos+2]<<8)|buf[pos+3];
		chunkSize = ((uint32)buf[pos+4]<<24)|((uint32)buf[pos+5]<<16)|
		            ((uint32)buf[pos+6]<<8)|buf[pos+7];

		if (chunkId == 0x53534E44u) {	/* 'SSND' */
			/* SSND layout: chunkId(4) + chunkSize(4) + offset(4) + blockSize(4) + data */
			gM.ssndStart = pos + 16;	/* skip chunk header (8) + offset + blockSize (8) */
			gM.ssndSize  = chunkSize - 8;
			return 1;
		}
		pos += 8 + ((chunkSize + 1u) & ~1u);
	}
	return 0;
}

/**********************************

	Per-frame music service.
	Call once per frame from UpdateAndPageFlip.

**********************************/

void MusicUpdate(void)
{
	SoundBufferNode *freeSbn;
	IOInfo params;
	int idx;
	int32 err;
	uint32 remaining, sz, fileBytePos, readSector;

	if (!gM.active) return;

	/* Non-blocking signal check: only wait if signals are already pending */
	{
		uint32 pending = GetCurrentSignals();
		if (pending & (uint32)gM.spooler->sspl_SignalMask) {
			WaitSignal((uint32)gM.spooler->sspl_SignalMask & pending);
			ssplProcessSignals(gM.spooler, pending, NULL);
		}
	}

	while ((freeSbn = ssplRequestBuffer(gM.spooler)) != NULL) {
		idx = (int)(int32)ssplGetUserData(gM.spooler, freeSbn);

		if (gM.readPos >= gM.ssndSize) {
			if (!gM.looping) {
				ssplUnrequestBuffer(gM.spooler, freeSbn);
				break;
			}
			gM.readPos = 0;
		}

		/* Physical sector = logical sector + 150 (2-second CD pregap) */
		fileBytePos = gM.ssndStart + gM.readPos;
		readSector  = gM.discSector + fileBytePos / 2048u + 150u;

		remaining = gM.ssndSize - gM.readPos;
		sz        = (remaining < MUSIC_BUF_SIZE) ? remaining : MUSIC_BUF_SIZE;

		memset(&params, 0, sizeof(params));
		params.ioi_Command         = CMD_READ;
		params.ioi_Offset          = (int32)readSector;
		params.ioi_Recv.iob_Buffer = gM.bufs[idx];
		params.ioi_Recv.iob_Len    = MUSIC_BUF_SIZE;

		err = DoIO(gM.cdromIOReq, &params);
		if (err >= 0) {
			ssplSetBufferAddressLength(gM.spooler, freeSbn, gM.bufs[idx], (int32)sz);
			ssplSendBuffer(gM.spooler, freeSbn);
			gM.readPos += sz;
		} else {
			ssplUnrequestBuffer(gM.spooler, freeSbn);
			break;
		}
	}
}

/**********************************

	Start music.
	Opens raw CD-ROM device, parses AIFF-C header, pre-fills
	spooler buffers, and starts the DSP decode chain.

**********************************/

void S_StartSong(Word music_id, Boolean looping)
{
	Byte   songNum;
	int    i;
	int32  err;
	IOInfo params;

	if (music_id >= sizeof(SongLookup)) return;
	songNum = SongLookup[music_id];
	if (songNum == 0 || songNum >= 30) return;
	if (gSongDiscSector[songNum] == 0) return;

	S_StopSong();

	gM.discSector = gSongDiscSector[songNum];

	/* Open raw CD-ROM device — bypasses filesystem, no per-file read limit */
	gM.cdromDevice = FindAndOpenDevice("CD-ROM");
	if (gM.cdromDevice < 0) return;

	gM.cdromIOReq = CreateIOReq(NULL, 0, gM.cdromDevice, 0);
	if (gM.cdromIOReq < 0) {
		CloseItem(gM.cdromDevice); gM.cdromDevice = 0;
		return;
	}

	/* Load directout.dsp — routes decoded PCM to the hardware DAC */
	gM.outputIns = LoadInstrument("directout.dsp", 0, 0);
	if (gM.outputIns < 0) {
		DeleteIOReq(gM.cdromIOReq); gM.cdromIOReq = 0;
		CloseItem(gM.cdromDevice); gM.cdromDevice = 0;
		return;
	}
	StartInstrument(gM.outputIns, NULL);

	/* Load SDX2 stereo decoder */
	gM.instrument = LoadInstrument("dcsqxdstereo.dsp", 0, 100);
	if (gM.instrument < 0) {
		UnloadInstrument(gM.outputIns); gM.outputIns = 0;
		DeleteIOReq(gM.cdromIOReq); gM.cdromIOReq = 0;
		CloseItem(gM.cdromDevice); gM.cdromDevice = 0;
		return;
	}

	ConnectInstruments(gM.instrument, "LeftOutput",  gM.outputIns, "InputLeft");
	ConnectInstruments(gM.instrument, "RightOutput", gM.outputIns, "InputRight");

	gM.spooler = ssplCreateSoundSpooler(MUSIC_NUM_BUFS, gM.instrument);
	if (!gM.spooler) {
		UnloadInstrument(gM.instrument); gM.instrument = 0;
		UnloadInstrument(gM.outputIns); gM.outputIns = 0;
		DeleteIOReq(gM.cdromIOReq); gM.cdromIOReq = 0;
		CloseItem(gM.cdromDevice); gM.cdromDevice = 0;
		return;
	}

	/* Allocate audio DMA buffers (must be MEMTYPE_AUDIO for DSP DMA) */
	for (i = 0; i < MUSIC_NUM_BUFS; i++) {
		gM.bufs[i] = AllocMem(MUSIC_BUF_SIZE, MEMTYPE_AUDIO);
		if (!gM.bufs[i]) {
			while (--i >= 0) FreeMem(gM.bufs[i], MUSIC_BUF_SIZE);
			ssplDeleteSoundSpooler(gM.spooler); gM.spooler = NULL;
			UnloadInstrument(gM.instrument); gM.instrument = 0;
			UnloadInstrument(gM.outputIns); gM.outputIns = 0;
			DeleteIOReq(gM.cdromIOReq); gM.cdromIOReq = 0;
			CloseItem(gM.cdromDevice); gM.cdromDevice = 0;
			return;
		}
	}

	/* Read first sector (physical = logical + 150) to parse AIFF-C header */
	memset(&params, 0, sizeof(params));
	params.ioi_Command         = CMD_READ;
	params.ioi_Offset          = (int32)(gM.discSector + 150);
	params.ioi_Recv.iob_Buffer = gM.bufs[0];
	params.ioi_Recv.iob_Len    = 2048;
	err = DoIO(gM.cdromIOReq, &params);
	if (err < 0 || !musicParseHeader((Byte*)gM.bufs[0], 2048)) {
		for (i = 0; i < MUSIC_NUM_BUFS; i++) FreeMem(gM.bufs[i], MUSIC_BUF_SIZE);
		ssplDeleteSoundSpooler(gM.spooler); gM.spooler = NULL;
		UnloadInstrument(gM.instrument); gM.instrument = 0;
		UnloadInstrument(gM.outputIns); gM.outputIns = 0;
		DeleteIOReq(gM.cdromIOReq); gM.cdromIOReq = 0;
		CloseItem(gM.cdromDevice); gM.cdromDevice = 0;
		return;
	}

	/* Pre-fill spooler buffers */
	gM.readPos = 0;
	for (i = 0; i < MUSIC_NUM_BUFS; i++) {
		SoundBufferNode *sbn = ssplRequestBuffer(gM.spooler);
		ssplSetUserData(gM.spooler, sbn, (void*)i);

		if (i == 0) {
			/* buf[0] already holds the header sector; audio starts at ssndStart */
			uint32 audioBytes = 2048u - gM.ssndStart;
			if (audioBytes > gM.ssndSize) audioBytes = gM.ssndSize;
			ssplSetBufferAddressLength(gM.spooler, sbn,
			    gM.bufs[0] + gM.ssndStart, (int32)audioBytes);
			ssplSendBuffer(gM.spooler, sbn);
			gM.readPos = audioBytes;
		} else {
			if (gM.readPos < gM.ssndSize) {
				uint32 fileBytePos = gM.ssndStart + gM.readPos;
				uint32 readSector  = gM.discSector + fileBytePos / 2048u + 150u;
				uint32 sz = gM.ssndSize - gM.readPos;
				if (sz > MUSIC_BUF_SIZE) sz = MUSIC_BUF_SIZE;

				memset(&params, 0, sizeof(params));
				params.ioi_Command         = CMD_READ;
				params.ioi_Offset          = (int32)readSector;
				params.ioi_Recv.iob_Buffer = gM.bufs[i];
				params.ioi_Recv.iob_Len    = MUSIC_BUF_SIZE;
				err = DoIO(gM.cdromIOReq, &params);
				if (err >= 0) {
					ssplSetBufferAddressLength(gM.spooler, sbn, gM.bufs[i], (int32)sz);
					ssplSendBuffer(gM.spooler, sbn);
					gM.readPos += sz;
				} else {
					ssplUnrequestBuffer(gM.spooler, sbn);
				}
			} else {
				ssplUnrequestBuffer(gM.spooler, sbn);
			}
		}
	}

	gM.looping = looping;
	gM.active  = TRUE;

	ssplStartSpooler(gM.spooler, MAXDSPAMPLITUDE);
}

/**********************************

	Stop music and release all resources.

**********************************/

void S_StopSong(void)
{
	int i;

	if (!gM.active) return;
	gM.active = FALSE;

	ssplStopSpooler(gM.spooler);
	ssplAbort(gM.spooler, NULL);
	ssplDeleteSoundSpooler(gM.spooler);
	gM.spooler = NULL;

	UnloadInstrument(gM.instrument);
	gM.instrument = 0;
	UnloadInstrument(gM.outputIns);
	gM.outputIns = 0;

	DeleteIOReq(gM.cdromIOReq);
	gM.cdromIOReq = 0;
	CloseItem(gM.cdromDevice);
	gM.cdromDevice = 0;

	for (i = 0; i < MUSIC_NUM_BUFS; i++) {
		if (gM.bufs[i]) {
			FreeMem(gM.bufs[i], MUSIC_BUF_SIZE);
			gM.bufs[i] = NULL;
		}
	}

	gM.readPos = 0;
}

#else /* !ENABLE_MUSIC */

void MusicUpdate(void) {}
void S_StartSong(Word music_id, Boolean looping) { (void)music_id; (void)looping; }
void S_StopSong(void) {}

#endif /* ENABLE_MUSIC */
