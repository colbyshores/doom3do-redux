/* Compatibility header for building optidoom3do with trapexit/3do-devkit */
#ifndef COMPAT_H
#define COMPAT_H

/* burger.h defines Word/Byte/Fixed/LongWord but not Boolean */
#ifndef Boolean
typedef unsigned int Boolean;
#endif

/* TRUE/FALSE may not be defined */
#ifndef TRUE
#define TRUE  1
#endif
#ifndef FALSE
#define FALSE 0
#endif

#endif /* COMPAT_H */
