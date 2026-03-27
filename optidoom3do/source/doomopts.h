/* ========= Game Options ========= */

/* Graphics quality presets */
enum
{
	PRESET_GFX_DEFAULT,
	PRESET_GFX_FASTER,
	PRESET_GFX_CUSTOM,
	PRESET_GFX_MAX,
	PRESET_OPTIONS_NUM
};

/* Stats overlay */
enum
{
	STATS_OFF,
	STATS_FPS,
	STATS_MEM,
	STATS_ALL,
	STATS_OPTIONS_NUM
};

/* Input modes */
enum
{
	INPUT_DPAD_ONLY,
	INPUT_MOUSE_ONLY,
	INPUT_MOUSE_AND_DPAD,
	INPUT_MOUSE_AND_DPAD_TILT,
	INPUT_MOUSE_AND_ABC,
	INPUT_OPTIONS_NUM
};

/* Floor/ceiling quality */
enum
{
    PLANE_QUALITY_LO,   /* flat colored (new, fastest) */
    PLANE_QUALITY_MID,  /* half-res textured (old LO) */
    PLANE_QUALITY_HI,   /* full-res textured (unchanged) */
    PLANE_QUALITY_OPTIONS_NUM
};

/* Wall renderer */
enum
{
    RENDERER_DOOM,
    RENDERER_POLY,
    RENDERER_OPTIONS_NUM
};

/* Depth shading modes */
enum
{
    DEPTH_SHADING_DARK,
    DEPTH_SHADING_BRIGHT,
    DEPTH_SHADING_DITHERED,
    DEPTH_SHADING_ON,
    DEPTH_SHADING_OPTIONS_NUM
};

/* Frame limiter */
enum
{
	FRAME_LIMIT_OFF,
	FRAME_LIMIT_1VBL,
	FRAME_LIMIT_2VBL,
	FRAME_LIMIT_3VBL,
	FRAME_LIMIT_4VBL,
	FRAME_LIMIT_VSYNC,
	FRAME_LIMIT_OPTIONS_NUM
};

/* Sky types */
enum {
    SKY_DEFAULT,
    SKY_GRADIENT_DAY,
    SKY_GRADIENT_NIGHT,
    SKY_GRADIENT_DUSK,
    SKY_GRADIENT_DAWN,
    SKY_PLAYSTATION,
    SKY_OPTIONS_NUM
};

/* Cheats revealed level */
enum
{
    CHEATS_OFF,
    CHEATS_HALF,
    CHEATS_FULL,
    CHEATS_REVEALED_OPTIONS_NUM
};

/* Automap cheat modes */
enum
{
    AUTOMAP_CHEAT_OFF,
    AUTOMAP_CHEAT_SHOWTHINGS,
    AUTOMAP_CHEAT_SHOWLINES,
    AUTOMAP_CHEAT_SHOWALL,
    AUTOMAP_OPTIONS_NUM
};

/* Player speed multiplier */
enum
{
    PLAYER_SPEED_1X,
    PLAYER_SPEED_1_5X,
    PLAYER_SPEED_2X,
    PLAYER_SPEED_OPTIONS_NUM
};

/* Enemy speed multiplier */
enum
{
    ENEMY_SPEED_0X,
    ENEMY_SPEED_0_5X,
    ENEMY_SPEED_1X,
    ENEMY_SPEED_2X,
    ENEMY_SPEED_OPTIONS_NUM
};

typedef struct GraphicsOptions
{
	Word frameLimit;
	Word screenSizeIndex;
	Word planeQuality;
	Word depthShading;
	Word thingsShading;
	Word renderer;
	Word gamma;
} GraphicsOptions;

typedef struct OtherOptions
{
	Word input;
	Word sensitivityX;
	Word sensitivityY;
	Word alwaysRun;
	Word stats;
	Word border;
	Word thickLines;
	Word sky;
	Word fireSkyHeight;
	Word cheatsRevealed;
    Word cheatAutomap;
    Word cheatIDKFAdummy;
	Word cheatNoclip;
	Word cheatIDDQD;
	Word playerSpeed;
	Word enemySpeed;
	Word extraBlood;
	Word fly;
} OtherOptions;

typedef struct AllOptions
{
	GraphicsOptions graphics;
	OtherOptions other;
} AllOptions;

/* Globals (defined in omain.c) */
extern Word presets;
extern GraphicsOptions *optGraphics;
extern OtherOptions *optOther;
