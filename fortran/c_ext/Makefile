# c_ext/Makefile
#
# Builds the LingoFuse Fortran bridge, its test programs, and its
# Fortran module. All paths are relative to this file so the entire
# fortran/ directory can be relocated.
#
# Outputs:
#   test_lf_fortran_c.exe   C ABI test
#   test_lf_fortran_f.exe   Fortran binding test
#   test_lf_json_f.exe      Fortran JSON test
#   lf_fortran_mod.mod      Fortran module interface file
#
# The LingoFuse runtime DLL is resolved at runtime by LingoFuse.c,
# not at link time. It is not referenced from this Makefile.

# ------------------------------------------------------------------ #
# Platform detection
# ------------------------------------------------------------------ #

ifeq ($(OS),Windows_NT)
    PLATFORM      := windows
    EXE_EXT       := .exe
    RM            := rm -f
    NULL_DEV      := NUL
    LDFLAGS_EXTRA := -lkernel32
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Darwin)
        PLATFORM      := macos
        EXE_EXT       :=
        RM            := rm -f
        NULL_DEV      := /dev/null
        LDFLAGS_EXTRA :=
    else
        PLATFORM      := linux
        EXE_EXT       :=
        RM            := rm -f
        NULL_DEV      := /dev/null
        LDFLAGS_EXTRA := -ldl -lpthread
    endif
endif

# ------------------------------------------------------------------ #
# Toolchain
# ------------------------------------------------------------------ #

CC  := gcc
CXX := g++
FC  := gfortran

CFLAGS   := -O2 -Wall -Wextra -std=c11
CXXFLAGS := -O2 -Wall -Wextra -std=c++17
FFLAGS   := -O2 -Wall -Wextra -std=f2008 -J. -I.

# ------------------------------------------------------------------ #
# Targets
# ------------------------------------------------------------------ #

COMMON_OBJS := LingoFuse.o lf_fortran.o

ALL_EXES := test_lf_fortran_c$(EXE_EXT) \
            test_lf_fortran_f$(EXE_EXT) \
            test_lf_json_f$(EXE_EXT)

.PHONY: all clean

all: $(ALL_EXES)

# ------------------------------------------------------------------ #
# Bridge objects
# ------------------------------------------------------------------ #

LingoFuse.o: LingoFuse.c LingoFuse.h
	$(CC) $(CFLAGS) -c LingoFuse.c -o $@

lf_fortran.o: lf_fortran.cpp lf_fortran.h LingoFuse.h
	$(CXX) $(CXXFLAGS) -c lf_fortran.cpp -o $@

lf_fortran_mod.o lf_fortran_mod.mod: lf_fortran_mod.f90
	$(FC) $(FFLAGS) -c lf_fortran_mod.f90 -o lf_fortran_mod.o

# ------------------------------------------------------------------ #
# Tests
# ------------------------------------------------------------------ #

test_lf_fortran_c$(EXE_EXT): test_lf_fortran.c $(COMMON_OBJS)
	$(CC) $(CFLAGS) test_lf_fortran.c $(COMMON_OBJS) -o $@ \
	    -lstdc++ $(LDFLAGS_EXTRA)

test_lf_fortran_f$(EXE_EXT): test_lf_fortran_f.f90 lf_fortran_mod.o $(COMMON_OBJS)
	$(FC) $(FFLAGS) test_lf_fortran_f.f90 lf_fortran_mod.o $(COMMON_OBJS) \
	    -o $@ -lstdc++ $(LDFLAGS_EXTRA)

test_lf_json_f$(EXE_EXT): test_lf_json_f.f90 lf_fortran_mod.o $(COMMON_OBJS)
	$(FC) $(FFLAGS) test_lf_json_f.f90 lf_fortran_mod.o $(COMMON_OBJS) \
	    -o $@ -lstdc++ $(LDFLAGS_EXTRA)

# ------------------------------------------------------------------ #
# Clean
# ------------------------------------------------------------------ #

clean:
	$(RM) *.o *.mod $(ALL_EXES)