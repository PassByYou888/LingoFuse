# ============================================================================
# c_ext/Makefile
#
# Build the LingoFuse Fortran C-ABI bridge, its C helpers, and the
# four test executables:
#
#   test_lf_fortran_c.exe   C ABI test
#   test_lf_fortran_f.exe   Fortran binding test
#   test_lf_json_f.exe      Fortran JSON test
#   test_lf_tasks_f.exe     Fortran task-handle async test
#
# ============================================================================
# Toolchain
# ============================================================================
#
# The three compilers must come from the SAME toolchain (e.g. one
# MinGW-Builds or MSYS2 distribution). Mixing versions across gcc,
# g++, and gfortran will produce undefined references to
# __gfortran_* at link time.
#
#   CC   -- C11 compiler   (gcc)
#   CXX  -- C++17 compiler (g++)
#   FC   -- Fortran 2008 compiler (gfortran)
#
# NOTE ON ASSIGNMENT OPERATOR:
#   We use `=` (not `?=`) so that these assignments OVERRIDE GNU Make's
#   built-in defaults (CC = cc, CXX = g++, FC = f77). The built-in
#   defaults are defined by Make itself, so a `?=` would not replace
#   them. A command-line override (e.g. `make FC=my-fortran`) still
#   takes precedence over a plain `=` assignment inside the Makefile.
#
# ============================================================================

CC  = gcc
CXX = g++
FC  = gfortran

# ============================================================================
# Flags
# ============================================================================

CFLAGS   := -O2 -Wall -Wextra -std=c11
CXXFLAGS := -O2 -Wall -Wextra -std=c++17
FCFLAGS  := -O2 -Wall -Wextra -std=f2008 -J. -I.

# Link libraries.
#
#   -lstdc++     -- required because lf_fortran.o is C++
#   -lkernel32   -- required for the Sleep() import used by the demos
#
# Do NOT remove -lstdc++; the C++ bridge is linked into every
# executable that talks to LingoFuse.
LDLIBS := -lstdc++ -lkernel32

# ============================================================================
# Source / object layout
# ============================================================================

OBJS := \
    LingoFuse.o \
    lf_fortran.o \
    lf_task_support.o \
    lf_fortran_mod.o \
    lf_fortran_tasks.o

TEST_EXES := \
    test_lf_fortran_c.exe \
    test_lf_fortran_f.exe \
    test_lf_json_f.exe \
    test_lf_tasks_f.exe

# ============================================================================
# Phony targets
# ============================================================================

.PHONY: all clean

all: $(TEST_EXES)

clean:
	rm -f *.o *.mod $(TEST_EXES)

# ============================================================================
# Object rules
# ============================================================================

# ---- C helper: dynamic loader + typed wrappers ----

LingoFuse.o: LingoFuse.c LingoFuse.h
	$(CC) $(CFLAGS) -c LingoFuse.c -o LingoFuse.o

# ---- C atomic support for the Fortran task module ----
#
# Provides lf_task_atomic_cas_int / lf_task_atomic_store_int /
# lf_task_atomic_load_int. Used only by lf_fortran_tasks.

lf_task_support.o: lf_task_support.c lf_task_support.h
	$(CC) $(CFLAGS) -c lf_task_support.c -o lf_task_support.o

# ---- C++ bridge: extern "C" ABI on top of the C helper ----

lf_fortran.o: lf_fortran.cpp lf_fortran.h LingoFuse.h
	$(CXX) $(CXXFLAGS) -c lf_fortran.cpp -o lf_fortran.o

# ---- Fortran module: the public lf_fortran_mod ----
#
# -J. writes the .mod file into the current directory; -I. reads
# it back. gfortran produces lf_fortran_mod.mod on success.

lf_fortran_mod.o: lf_fortran_mod.f90
	$(FC) $(FCFLAGS) -c lf_fortran_mod.f90 -o lf_fortran_mod.o

# ---- Fortran module: the optional task-handle extension ----
#
# Depends on lf_fortran_mod (USE) and on lf_task_support (bind(C)).

lf_fortran_tasks.o: lf_fortran_tasks.f90 lf_fortran_mod.o
	$(FC) $(FCFLAGS) -c lf_fortran_tasks.f90 -o lf_fortran_tasks.o

# ============================================================================
# Executable rules
# ============================================================================

# ---- C ABI test ----
#
# Compiled with gcc, linked with the C++ bridge object. The C++
# runtime is required transitively.

test_lf_fortran_c.exe: test_lf_fortran.c LingoFuse.o lf_fortran.o
	$(CC) $(CFLAGS) test_lf_fortran.c LingoFuse.o lf_fortran.o \
	    -o $@ $(LDLIBS)

# ---- Fortran binding test ----

test_lf_fortran_f.exe: test_lf_fortran_f.f90 \
                       lf_fortran_mod.o LingoFuse.o lf_fortran.o
	$(FC) $(FCFLAGS) test_lf_fortran_f.f90 \
	    lf_fortran_mod.o LingoFuse.o lf_fortran.o \
	    -o $@ $(LDLIBS)

# ---- Fortran JSON test ----

test_lf_json_f.exe: test_lf_json_f.f90 \
                    lf_fortran_mod.o LingoFuse.o lf_fortran.o
	$(FC) $(FCFLAGS) test_lf_json_f.f90 \
	    lf_fortran_mod.o LingoFuse.o lf_fortran.o \
	    -o $@ $(LDLIBS)

# ---- Fortran task-handle async test ----
#
# Links both Fortran modules and the C atomic support object.

test_lf_tasks_f.exe: test_lf_tasks_f.f90 \
                     lf_fortran_tasks.o lf_fortran_mod.o \
                     lf_task_support.o \
                     LingoFuse.o lf_fortran.o
	$(FC) $(FCFLAGS) test_lf_tasks_f.f90 \
	    lf_fortran_tasks.o lf_fortran_mod.o \
	    lf_task_support.o \
	    LingoFuse.o lf_fortran.o \
	    -o $@ $(LDLIBS)