#!/bin/sh
#
#  build_engine.sh
#
#  Auxiliary code to build native code (engine)
#
#  Copyright (C) 2015 Jose F. Morales, Ciao Developer team
#
# ===========================================================================
#
# Input (environment variables):
#   BLD_ENGDIR
#   ENG_CFG
#   (optional) BOOTENG_CDIR
#
# ---------------------------------------------------------------------------

# Exit immediately if a simple command exits with a non-zero status
set -e

# Physical directory where the script is located
_base=$(e=$0;while test -L "$e";do d=$(dirname "$e");e=$(readlink "$e");\
        cd "$d";done;cd "$(dirname "$e")";pwd -P)

# ---------------------------------------------------------------------------

# Safety check (clean operations are dangerous)
if [ x"$BLD_ENGDIR" = x"" -o x"$ENG_CFG" = x"" ]; then
    cat >&2 <<EOF
INTERNAL ERROR: missing BLD_ENGDIR or ENG_CFG in build_engine.sh
EOF
    exit 1
fi

bld_engdir=$BLD_ENGDIR
eng_cfg=$ENG_CFG

if [ -x "$bld_engdir" -a '(' ! -x "$bld_engdir/cfg" ')' ]; then
    for i in "$bld_engdir/*"; do
	cat >&2 <<EOF
INTERNAL ERROR: suspicuous BLD_ENGDIR in build_engine.sh:

The directory "$bld_engdir" is not empty and does not look like a
valid engine build directory. For safety, this script is aborted.

If correct, please clean manually the contents of the specified BLD_ENGDIR.
EOF
	exit 1
    done
fi

bld_hdir="$bld_engdir/include"
bld_cdir="$bld_engdir/src"
bld_objdir="$bld_engdir/objs/$eng_cfg"
bld_cfgdir="$bld_engdir/cfg/$eng_cfg"

# ---------------------------------------------------------------------------

no_eng_config() {
    [ ! -f "$bld_cfgdir/config_sh" ] || [ ! -f "$bld_cfgdir/meta_sh" ]
}

# Load config_sh and meta_sh
eng_config_loaded_p=""
ensure_eng_config_loaded() {
    if [ x"$eng_config_loaded_p" != x"" ]; then return; fi
    if no_eng_config; then
	echo "ERROR: no $eng_cfg configuration found for $bld_engdir" >&2
        exit 1
    fi
    . "$bld_cfgdir/meta_sh"
    . "$bld_cfgdir/config_sh"
    eng_config_loaded_p=yes # Mark as loaded
}

# ---------------------------------------------------------------------------

# Is there a compiled engine?
engine_is_ok() {
    if no_eng_config; then return 1; fi
    ensure_eng_config_loaded
    [ -f "$bld_objdir/$eng_name""$EXECSUFFIX" ]
}

# ---------------------------------------------------------------------------
# Prepare the directory for building the engine:
#  - if BOOTENG_CDIR is specified (first argument) move files to $bld_cdir and $bld_hdir
#  - prepare $bld_cdir (for .c source files, including autogenerated)
#  - prepare $bld_hdir (for .h headers using eng_h_alias layout)
#  - source files are taken from the eng_srcpath (the first occurrence has preference)

# TODO: A bit slow (0.2s); reimplement in C? or generate a file list
prepare_engdir() { # (env: optional BOOTENG_CDIR)
    # Do not use symlinks in Windows
    case $CIAOOS in
	Win32) use_symlinks=no ;;
	*) use_symlinks=yes ;;
    esac

    # Load engine info
    # TODO: add $eng_srcpath to VPATH? I can avoid many linkhere and reuse BOOTENG_CDIR as bld_cdir
    if [ -d "$BOOTENG_CDIR" ]; then # (saved)
	. "$BOOTENG_CDIR/eng_info_sh"
    else # (generated by emugen)
	. "$bld_cdir/eng_info_sh"
    fi

    mkdir -p "$bld_cdir"
    mkdir -p "$bld_hdir"
    mkdir -p "$bld_hdir/$eng_h_alias"

    # Link all .c files
    local oldpwd=`pwd`
    cd "$bld_cdir"
    # TODO: use ENG_CFILES avoid autogenerated files?
    local src
    for src in $eng_srcpath; do
	linkhere "$src"/*.c
    done
    if [ -d "$BOOTENG_CDIR" ]; then
	# Getting files generated by emugen
	linkhere "$BOOTENG_CDIR"/*.c
	linkhere "$BOOTENG_CDIR"/"eng_info_mk"
	linkhere "$BOOTENG_CDIR"/"eng_info_sh"
    else
	true # (otherwise trust emugen)
    fi
    cd "$oldpwd"

    # Link all .h files
    oldpwd=`pwd`
    cd "$bld_hdir/$eng_h_alias"
    # TODO: use ENG_CFILES avoid autogenerated files?
    for src in $eng_srcpath; do
	linkhere "$src"/*.h
    done
    if [ -d "$BOOTENG_CDIR" ]; then
	# Getting files generated by emugen
	linkhere "$BOOTENG_CDIR"/*.h
    else
	true # (otherwise trust emugen)
    fi
    cd "$oldpwd"

    # Link special .h files (without eng_h_alias)
    oldpwd=`pwd`
    cd "$bld_hdir"
    for f in $ENG_HFILES_NOALIAS; do
	for src in $eng_srcpath; do
	    linkhere "$src"/"$f"
	done
    done
    cd "$oldpwd"
}

# Link or copy if newer (if $use_symlinks==no)
# (Do nothing if file does not exist)
linkhere() {
    local i b
    if [ x"$use_symlinks" = x"no" ]; then
	for i in "$@"; do
	    b=`basename "$i"`
	    if [ ! -r "$i" ]; then
		true
	    elif [ -e "$b" -a '(' ! "$i" -nt "$b" ')' ]; then
		true
	    else
		cp "$i" "$b"
	    fi
	done
    else
	for i in "$@"; do
	    b=`basename "$i"`
	    if [ ! -r "$i" ]; then
		true
	    elif [ -e "$b" ]; then
		true
	    else
		ln -s "$i" "$b"
	    fi
	done
    fi
}

# Writes the input to FILE, only if contents are different (preserves timestamps)
# TODO: Use 'update_file' in other parts of the build process (for some _auto.pl files and configuration options)
update_file() { # FILE
    local t="$1""-tmp"
    cat > "$t"
    if cmp -s "$1" "$t"; then # same, keep original
	rm "$t"
    else # different or new
	rm -f "$1"
	mv "$t" "$1"
    fi
}

# ---------------------------------------------------------------------------
# Prepare and build the engine from .c sources:
#  - create installation-dependent eng_build_info.c file
#  - determine platform configuration (use preconfigured if exists in source)
#  - build executable, and static and shared libraries
#  - patch binaries (if needed)

eng_build() { # (env: optional BOOTENG_CDIR)
    local eng_deplibs eng_addobj
    ensure_eng_config_loaded
    #
    prepare_engdir
    mkdir -p "$bld_objdir"
    # Generate build info
    create_eng_build_info
    # Generate engine configuration
    create_eng_config
    # Build exec and lib
    eng_deplibs="$LIBS"
    if [ x"$eng_use_stat_libs" = x"yes" ]; then
	eng_deplibs="$eng_deplibs $STAT_LIBS"
    fi
    eng_make engexec ENG_DEPLIBS="$eng_deplibs" ENG_ADDOBJ="$eng_addobj" # TODO: make it optional, depending on ENG_STUBMAIN (which is not visible here)
    if [ x"$ENG_DYNLIB" = x"1" ]; then
	eng_make englib ENG_DEPLIBS="$eng_deplibs" ENG_ADDOBJ="$eng_addobj"
    fi
    # Patch exec
    if [ x"$ENG_FIXSIZE" = x"1" ]; then
	eng_make fix_size_exec
	"$bld_objdir/fix_size""$EXECSUFFIX" "$bld_objdir/$eng_name""$EXECSUFFIX"
    fi
}

# Use an existing preconfiguration or run configure
create_eng_config() {
    local preconf=""
    local f src
    for src in $eng_srcpath; do
	f="$src/configure.$eng_cross_os$eng_cross_arch.h"
	if [ -r "$f" ]; then
	    preconf="$f"
	    break
	fi
    done
    if [ x"$preconf" = x"" ]; then eng_make configexec; fi
    if [ x"$preconf" != x"" ]; then
	dump_cflags; cat "$preconf"
    else
	dump_cflags; "$bld_objdir/configure""$EXECSUFFIX"
    fi | update_file "$bld_hdir/$eng_h_alias/configure.h"
}
# TODO: create together with config_sh instead
# TODO: goes to platform-independent directories! add osach as suffix and do conditional include?
dump_cflags() {
    local flag name
    for flag in $CFLAGS; do
	if ! expr x$flag : x'-D\(..*\)' >/dev/null; then
	    continue
	fi
	name=`expr x$flag : x'-D\(..*\)'`
	cat <<EOF
#if !defined($name)
#define $name
#endif
EOF
    done
}

# Invoke the engine.mk
eng_make() {
    local make="make -s"
    # Use gmake if available, otherwise expect make to be gmake
    if command -v gmake > /dev/null 2>&1; then make="gmake -s"; fi
    $make --no-print-directory -j$PROCESSORS \
	  -C "$bld_objdir" \
	  -f "$_base/engine.mk" \
	  "$@" \
	  BLD_CDIR="$bld_cdir" \
	  BLD_OBJDIR="$bld_objdir" \
	  ENG_NAME="$eng_name" \
	  ENG_CFG_MK="$bld_cfgdir/config_mk"
}

# Generate the build info for the engine:
#   - versions, gcc options, OS suffixes, etc.
create_eng_build_info() {
    # Load configuration flags (e.g., core__DEBUG_LEVEL, etc.)
    . "$eng_core_config"

    local showdbg=
    if [ x"$core__DEBUG_LEVEL" != x"nodebug" ]; then
	showdbg=" [$core__DEBUG_LEVEL]"
    fi

    # eng_build_info.c: (in $bld_objdir since it depends on $eng_cfg)
    local ciaosuffix=
    case "$CIAOOS" in # (loaded from ensure_eng_config_loaded)
	Win32) ciaosuffix=".cpx" ;;
    esac
    update_file "$bld_objdir/eng_build_info.c" <<EOF
#include <ciao/version.h>

char *eng_architecture = "$CIAOARCH";
char *eng_os = "$CIAOOS";
char *exec_suffix = "$EXECSUFFIX";
char *so_suffix = "$SOSUFFIX";

char *eng_debug_level = "$core__DEBUG_LEVEL";
char *eng_version = CIAO_VERSION_STRING " [$CIAOOS$CIAOARCH]$showdbg";

int eng_is_sharedlib = $ENG_STUBMAIN_DYNAMIC;
char *ciao_suffix = "$ciaosuffix";

char *default_ciaoroot = "$eng_default_ciaoroot";
char *default_c_headers_dir = "$bld_hdir";

char *foreign_opts_cc = "$CC";
char *foreign_opts_ld = "$LD";
char *foreign_opts_ccshared = "$CCSHARED";
char *foreign_opts_ldshared = "$LDSHARED";
EOF
}

# ---------------------------------------------------------------------------

eng_clean() {
    rm -rf "$bld_engdir"
}

# ---------------------------------------------------------------------------

case "$1" in
    build) eng_build ;;
    clean) eng_clean ;;
    engine_is_ok) engine_is_ok ;;
    *)
	echo "Unknown target '$1' in build_engine.sh" >&2
	exit 1
	;;
esac
