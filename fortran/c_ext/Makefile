# ============================================================================
# Makefile for the LingoFuse C-ABI bridge and its test programs.
#
# Targets:
#   all       Build all three test executables (default)
#   run-c     Build and run the C test
#   run-f     Build and run the Fortran test
#   run-j     Build and run the Fortran JSON test
#   run       Build and run all three
#   clean     Remove all build artifacts
#
# Toolchain override (from the command line):
#   mingw32-make FC=x86_64-w64-mingw32-gfortran \
#                CXX=x86_64-w64-mingw32-g++ \
#                CC=x86_64-w64-mingw32-gcc
# ============================================================================

FC       := gfortran
CXX      := g++
CC       := gcc

FFLAGS   := -O2 -Wall -Wextra -std=f2008 -J.
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra
CFLAGS   := -std=c11  -O2 -Wall -Wextra

COMMON_OBJS := LingoFuse.o lf_fortran.o
MOD_OBJS    := lf_fortran_mod.o

all: test_lf_fortran_c.exe test_lf_fortran_f.exe test_lf_json_f.exe

# ---- Test executables ----

test_lf_fortran_c.exe: $(COMMON_OBJS) test_lf_fortran.o
	$(CXX) -o $@ $^

test_lf_fortran_f.exe: $(COMMON_OBJS) $(MOD_OBJS) test_lf_fortran_f.o
	$(CXX) -o $@ $^ -lgfortran

test_lf_json_f.exe: $(COMMON_OBJS) $(MOD_OBJS) test_lf_json_f.o
	$(CXX) -o $@ $^ -lgfortran

# ---- Compilation rules ----

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.o: %.f90
	$(FC) $(FFLAGS) -c $< -o $@

# The Fortran test programs use lf_fortran_mod, so they must be
# compiled after the module.
test_lf_fortran_f.o: $(MOD_OBJS)
test_lf_json_f.o:    $(MOD_OBJS)

# ---- Convenience targets ----

run-c: test_lf_fortran_c.exe
	./test_lf_fortran_c.exe

run-f: test_lf_fortran_f.exe
	./test_lf_fortran_f.exe

run-j: test_lf_json_f.exe
	./test_lf_json_f.exe

run: run-c run-f run-j

clean:
	-rm -f *.o *.mod test_lf_fortran_c.exe test_lf_fortran_f.exe test_lf_json_f.exe

.PHONY: all run run-c run-f run-j clean