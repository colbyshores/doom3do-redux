/* mem_fix.c — Override broken C-heap malloc/free with working AllocMem/FreeMem.
 *
 * On the Opera libretro emulator, the 3DO C library's malloc (which uses
 * AllocMemBlocks SWI) returns NULL. But AllocMemFromMemLists (the basis of
 * the AllocMem macro) DOES work.  This file provides replacement malloc/free
 * that are linked BEFORE clib.lib so they take precedence.
 *
 * Also provides a working availMem that returns a fixed estimate so that
 * burger.lib's GotAChunk can determine how much memory to request.
 */

#include <mem.h>
#include <kernel.h>
#include <string.h>

/* malloc: allocate from the current task's memory lists.
 * Signature matches 3DO stdlib.h: void *malloc(long size) */
void *malloc(long size)
{
    if (size <= 0) size = 1;
    return AllocMem((unsigned long)size, MEMTYPE_TRACKSIZE);
}

/* calloc: allocate + zero (size_t = unsigned int on 3DO) */
void *calloc(unsigned int nmemb, unsigned int elsize)
{
    unsigned int total = nmemb * elsize;
    void *p = malloc((long)total);
    if (p) memset(p, 0, total);
    return p;
}

/* free: return memory to the task's lists.
 * MEMTYPE_TRACKSIZE stores the size, so FreeMem(-1) works. */
void free(void *ptr)
{
    if (ptr) FreeMem(ptr, -1);
}

/* realloc: burger.lib doesn't call realloc, but provide a stub */
void *realloc(void *ptr, unsigned int size)
{
    if (!ptr) return malloc((long)size);
    if (!size) { free(ptr); return 0; }
    free(ptr);
    return malloc((long)size);
}

/* availMem override: return a fixed estimate of available memory.
 * The real availMem may not work in Opera.
 * GotAChunk uses this to bound its malloc request size. */
void availMem(MemInfo *info, uint32 type)
{
    info->minfo_SysFree    = 0x180000;   /* 1.5 MB estimate */
    info->minfo_SysLargest = 0x180000;
    info->minfo_TaskFree   = 0;
    info->minfo_TaskLargest = 0;
}
