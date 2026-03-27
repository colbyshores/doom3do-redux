/* xskies.c — Alternative sky rendering (non-texture sky backgrounds) */

#include "Doom.h"

/* Draw a non-default sky background (gradient, solid color, etc.) */
void drawNewSky(int which)
{
    /* All non-default sky types just draw a black background for now */
    DrawARect(0, 0, ScreenWidth, ScreenHeight, 0);
}
