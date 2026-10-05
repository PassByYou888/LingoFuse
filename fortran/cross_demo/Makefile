# cross_demo/Makefile
#
# Builds the four cross-language demo programs. All paths are
# relative to this file, so the entire fortran/ directory can be
# relocated.
#
# Outputs:
#   cross_service.exe     Fortran beacon
#   cross_node.exe        Fortran worker node
#   cross_call.exe        Fortran caller (same-language baseline)
#   cross_call_cpp.exe    C++ caller (cross-language verification)
#
# The objects produced by ../c_ext (LingoFuse.o, lf_fortran.o,
# lf_fortran_mod.o) are linked in. Build c_ext first.

# ------------------------------------------------------------------ #
# Platform detection
# ------------------------------------------------------------------ #

ifeq ($(OS),Windows_NT)
    EXE_EXT       := .exe
    RM            := rm -f
    LDFLAGS_EXTRA := -lkernel32
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Darwin)
        EXE_EXT       :=
        RM            := rm -f
        LDFLAGS_EXTRA :=
    else
        EXE_EXT       :=
        RM            := rm -f
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
FFLAGS   := -O2 -Wall -Wextra -std=f2008 -I../c_ext -J../c_ext

C_EXT_OBJS := ../c_ext/LingoFuse.o \
              ../c_ext/lf_fortran.o \
              ../c_ext/lf_fortran_mod.o

ALL_EXES := cross_service$(EXE_EXT) \
            cross_node$(EXE_EXT) \
            cross_call$(EXE_EXT) \
            cross_call_cpp$(EXE_EXT)

.PHONY: all clean

all: $(ALL_EXES)

# ------------------------------------------------------------------ #
# Fortran programs
# ------------------------------------------------------------------ #

cross_service$(EXE_EXT): cross_service.f90 $(C_EXT_OBJS)
	$(FC) $(FFLAGS) cross_service.f90 $(C_EXT_OBJS) -o $@ \
	    -lstdc++ $(LDFLAGS_EXTRA)

cross_node$(EXE_EXT): cross_node.f90 $(C_EXT_OBJS)
	$(FC) $(FFLAGS) cross_node.f90 $(C_EXT_OBJS) -o $@ \
	    -lstdc++ $(LDFLAGS_EXTRA)

cross_call$(EXE_EXT): cross_call.f90 $(C_EXT_OBJS)
	$(FC) $(FFLAGS) cross_call.f90 $(C_EXT_OBJS) -o $@ \
	    -lstdc++ $(LDFLAGS_EXTRA)

# ------------------------------------------------------------------ #
# C++ program
# ------------------------------------------------------------------ #

cross_call_cpp$(EXE_EXT): cross_call_cpp.cpp $(C_EXT_OBJS)
	$(CXX) $(CXXFLAGS) -I../c_ext cross_call_cpp.cpp $(C_EXT_OBJS) \
	    -o $@ -lgfortran $(LDFLAGS_EXTRA)

# ------------------------------------------------------------------ #
# Clean
# ------------------------------------------------------------------ #

clean:
	$(RM) $(ALL_EXES)