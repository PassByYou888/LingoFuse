# c_src/Makefile
#
# Builds the LingoFuse NIF shared library.
#
# The NIF is written in pure C11. It links dynamically against the
# Erlang runtime (erts) headers for the NIF API, and loads the
# LingoFuse native library at runtime via lf_loader.c.
#
# Output:
#   Linux / macOS / *BSD : ../priv/lingofuse_nif.so
#   Windows              : ../priv/lingofuse_nif.dll
#
# Environment overrides:
#   ERL_ROOT   - root directory of the Erlang/OTP installation.
#                Defaults to the result of `erl -eval code:root_dir()`.
#   ERTS_VER   - erts version string, e.g. "14.1".
#                Defaults to `erl -eval erlang:system_info(version)`.
#   CC         - C compiler. Defaults to "cc".
#
# Windows note: use MSYS2's `make` (mingw32-make). The MSYS2 shell
# provides a POSIX-compatible environment for this Makefile; the
# produced DLL is a native Windows DLL. Do NOT use MSVC's nmake.

# ----------------------------------------------------------------------
# Platform detection
# ----------------------------------------------------------------------

ifeq ($(OS),Windows_NT)
    IS_WINDOWS := 1
else
    IS_WINDOWS := 0
endif

# ----------------------------------------------------------------------
# Erlang root and erts include directory
#
# The two shell invocations below use double quotes so that they work
# under cmd.exe (which does not understand single quotes) as well as
# under a POSIX shell. The `halt()` call is explicit to avoid waiting
# for stdin.
# ----------------------------------------------------------------------

ERL_ROOT ?= $(shell erl -noshell -eval "io:format(\"~s\", [code:root_dir()]), halt().")
ERTS_VER ?= $(shell erl -noshell -eval "io:format(\"~s\", [erlang:system_info(version)]), halt().")

ERTS_INCLUDE := $(ERL_ROOT)/erts-$(ERTS_VER)/include

# Verify that the headers are actually present, so that a misconfigured
# ERL_ROOT produces an early, clear error rather than a wall of "file
# not found" messages from the compiler.
ifeq ($(wildcard $(ERTS_INCLUDE)/erl_nif.h),)
$(error Cannot find erl_nif.h under $(ERTS_INCLUDE). Set ERL_ROOT and ERTS_VER correctly.)
endif

# ----------------------------------------------------------------------
# Target and toolchain
# ----------------------------------------------------------------------

TARGET_DIR := ../priv

ifeq ($(IS_WINDOWS),1)
    TARGET      := $(TARGET_DIR)/lingofuse_nif.dll
    MKDIR_TDIR  := if not exist "$(TARGET_DIR)" mkdir "$(TARGET_DIR)"
    CLEAN_OBJ   := del /Q
else
    TARGET      := $(TARGET_DIR)/lingofuse_nif.so
    MKDIR_TDIR  := mkdir -p $(TARGET_DIR)
    CLEAN_OBJ   := rm -f
endif

CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra -fPIC -std=c11
CFLAGS += -I$(ERTS_INCLUDE)

# ----------------------------------------------------------------------
# Linker flags
#
# macOS needs `-bundle -undefined dynamic_lookup` because a NIF is a
# bundle, not a shared library, and the erl_* symbols are resolved at
# load time by the BEAM.
# Windows and Linux use `-shared`.
# ----------------------------------------------------------------------

ifeq ($(IS_WINDOWS),1)
    LDFLAGS := -shared
else
    UNAME_S := $(shell uname -s 2>/dev/null)
    ifeq ($(UNAME_S),Darwin)
        LDFLAGS := -bundle -undefined dynamic_lookup
    else
        LDFLAGS := -shared
    endif
endif

# ----------------------------------------------------------------------
# Sources and objects
# ----------------------------------------------------------------------

SRC := lingofuse_nif.c lf_loader.c
OBJ := $(SRC:.c=.o)

.PHONY: all clean rebuild

all: $(TARGET)

$(TARGET): $(OBJ)
	@$(MKDIR_TDIR)
	$(CC) $(LDFLAGS) -o $@ $(OBJ)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# The `-` prefix tells make to ignore the exit code of the command.
# That makes the trailing shell redirection unnecessary, and removing
# it avoids the POSIX quirk where `2>nul` would create a file named
# "nul" in the current directory.
clean:
	-$(CLEAN_OBJ) $(OBJ)
	-$(CLEAN_OBJ) $(TARGET)

rebuild: clean all