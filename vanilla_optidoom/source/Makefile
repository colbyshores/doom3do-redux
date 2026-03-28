NAME       = LaunchMe
FILESYSTEM = ../takeme
LAUNCHME   = $(FILESYSTEM)/LaunchMe
STACKSIZE  = 65536
BUILDDIR   = /tmp/vanilla-build

INCPATH  = ${TDO_DEVKIT_PATH}/include
INCFLAGS = -I. -I$(INCPATH)/3do -I$(INCPATH)/community -I$(INCPATH)/ttl
CFLAGS   = -O2 -Otime -bigend -zps1 -za1 -wn -ff -fa -fpu none -arch 3 -apcs "3/32/nofp"
ASFLAGS  = -bigend -fpu none -arch 3 -apcs "3/32/nofp"
LIBPATH  = ${TDO_DEVKIT_PATH}/lib
LDFLAGS  = -match 0x1 -nodebug -noscanlib -nozeropad -verbose -remove -aif -reloc -dupok -ro-base 0
STARTUP  = $(LIBPATH)/3do/cstartup.o

INTERNAL_LIBS = /tmp/vanilla-libs

LIBS = \
	$(INTERNAL_LIBS)/burger.lib \
	$(INTERNAL_LIBS)/intmath.lib \
	$(INTERNAL_LIBS)/string.lib \
	$(LIBPATH)/3do/armlib_c.32b \
	$(LIBPATH)/3do/lib3do.lib \
	$(LIBPATH)/3do/clib.lib \
	$(LIBPATH)/3do/graphics.lib \
	$(LIBPATH)/3do/operamath.lib \
	$(LIBPATH)/3do/audio.lib \
	$(LIBPATH)/3do/music.lib \
	$(LIBPATH)/3do/filesystem.lib \
	$(LIBPATH)/3do/exampleslib.lib \
	$(LIBPATH)/3do/input.lib \
	$(LIBPATH)/3do/swi.lib \
	$(LIBPATH)/3do/intmath.lib \
	$(LIBPATH)/3do/string.lib

SRCS_C = $(wildcard *.c)
SRCS_S = $(wildcard *.s)
OBJS = $(addprefix $(BUILDDIR)/,$(SRCS_C:.c=.o) $(SRCS_S:.s=.o))

all: $(BUILDDIR) $(LAUNCHME)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(LAUNCHME): $(OBJS)
	mkdir -p $(FILESYSTEM)
	armlink -o $(LAUNCHME) $(LDFLAGS) $(STARTUP) $(LIBS) $(OBJS)
	modbin --name="optidoom" --time --stack=$(STACKSIZE) $(LAUNCHME) $(LAUNCHME)

$(BUILDDIR)/%.o: %.c
	armcc $(INCFLAGS) $(CFLAGS) -c $< -o $@

$(BUILDDIR)/%.o: %.s
	armasm $(ASFLAGS) $< -o $@

clean:
	rm -rf $(BUILDDIR) $(LAUNCHME)
