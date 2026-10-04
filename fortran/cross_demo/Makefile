# ============================================================================
# Makefile for the cross-language demo programs.
#
# Builds four executables:
#
#   cross_service.exe     Fortran beacon
#   cross_node.exe        Fortran worker (add / inv_seri)
#   cross_call.exe        Fortran caller  (same-language baseline)
#   cross_call_cpp.exe    C++ caller      (cross-language verification)
#
# The common bridge objects (LingoFuse.o, lf_fortran.o, lf_fortran_mod.o)
# are built by the parent c_ext directory. The 'all' target rebuilds
# them first via `$(MAKE) -C ../c_ext`, so this Makefile is self-contained.
# ============================================================================

FC       := gfortran
CXX      := g++
MAKE     := mingw32-make

C_EXT    := ../c_ext

FFLAGS   := -O2 -Wall -Wextra -std=f2008 -J. -I$(C_EXT)
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -I$(C_EXT)

COMMON_OBJS := $(C_EXT)/LingoFuse.o $(C_EXT)/lf_fortran.o
MOD_OBJS    := $(C_EXT)/lf_fortran_mod.o

all: cross_service.exe cross_node.exe cross_call.exe cross_call_cpp.exe

# ---- Ensure the parent bridge is built before we link against it ----

$(COMMON_OBJS) $(MOD_OBJS):
	$(MAKE) -C $(C_EXT)

# ---- Fortran executables (link Fortran objects + C++ runtime) ----

cross_service.exe: cross_service.o $(COMMON_OBJS) $(MOD_OBJS)
	$(CXX) -o $@ $^ -lgfortran

cross_node.exe: cross_node.o $(COMMON_OBJS) $(MOD_OBJS)
	$(CXX) -o $@ $^ -lgfortran

cross_call.exe: cross_call.o $(COMMON_OBJS) $(MOD_OBJS)
	$(CXX) -o $@ $^ -lgfortran

# ---- C++ executable (link only the C++ bridge objects) ----

cross_call_cpp.exe: cross_call_cpp.o $(COMMON_OBJS)
	$(CXX) -o $@ $^

# ---- Compilation rules ----

%.o: %.f90
	$(FC) $(FFLAGS) -c $< -o $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# The Fortran sources that use the module must wait for the module to
# be compiled. This is guaranteed by the $(MOD_OBJS) prerequisite on
# the link targets, and by the pattern rule's -I$(C_EXT) flag, which
# points to the directory where lf_fortran_mod.mod lives.

# ---- Cleanup ----

clean:
	-rm -f *.o *.mod *.exe

.PHONY: all clean