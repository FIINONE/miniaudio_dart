cmake_minimum_required(VERSION 3.10)

# Options
option(MP3_USE_SYSTEM "Prefer a system-installed libmp3lame if available" ON)

set(_LAME_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/external/lame")

set(MP3_FOUND FALSE)

# Try system first (real autotools-built libmp3lame, e.g. via brew/apt/vcpkg)
if(MP3_USE_SYSTEM)
    find_path(LAME_INCLUDE_DIR lame/lame.h)
    find_library(LAME_LIBRARY NAMES mp3lame)
    if(LAME_INCLUDE_DIR AND LAME_LIBRARY)
        add_library(mp3::mp3 UNKNOWN IMPORTED)
        set_target_properties(mp3::mp3 PROPERTIES
            IMPORTED_LOCATION "${LAME_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${LAME_INCLUDE_DIR}")
        set(MP3_FOUND TRUE)
        message(STATUS "Found system libmp3lame: ${LAME_LIBRARY}")
    endif()
endif()

# Fallback: compile the vendored LAME sources (src/external/lame, LAME
# 3.100 - see external/lame/VERSION.txt) directly with CMake, bypassing
# LAME's own autotools build. No network access needed at configure time.
#
# LAME's C sources only need a handful of libc headers pulled in and a
# definition for ieee754_float32_t (normally supplied by an
# autotools-generated config.h); neither requires running `configure`,
# which keeps this portable to Windows (MSVC) without needing a POSIX
# shell.
if(NOT MP3_FOUND)
    if(NOT EXISTS "${_LAME_SRC_DIR}/libmp3lame")
        message(FATAL_ERROR "Vendored LAME sources not found under ${_LAME_SRC_DIR} (expected libmp3lame/ and include/lame.h)")
    endif()

    file(GLOB MP3LAME_SRC "${_LAME_SRC_DIR}/libmp3lame/*.c")

    add_library(mp3lame STATIC ${MP3LAME_SRC})

    set_target_properties(mp3lame PROPERTIES POSITION_INDEPENDENT_CODE ON)

    target_include_directories(mp3lame PUBLIC
        "${_LAME_SRC_DIR}/include"
    )
    target_include_directories(mp3lame PRIVATE
        "${_LAME_SRC_DIR}/libmp3lame"
    )

    # No config.h / autotools: supply the couple of things LAME's headers
    # would otherwise pull from a generated config.h.
    target_compile_definitions(mp3lame PRIVATE
        ieee754_float32_t=float
        HAVE_MEMCPY=1
        HAVE_MEMMOVE=1
    )

    if(MSVC)
        # MSVC forced includes.
        target_compile_options(mp3lame PRIVATE
            /FI stdint.h /FI stdlib.h /FI string.h
        )
        target_compile_definitions(mp3lame PRIVATE _CRT_SECURE_NO_WARNINGS HAVE_CONFIG_H=0)
    else()
        # NOTE: each "-include X" must stay atomic (SHELL: prefix) -
        # otherwise CMake's option de-duplication strips the repeated
        # "-include" token and leaves orphaned filenames as bogus extra
        # positional (input file) arguments.
        target_compile_options(mp3lame PRIVATE
            "SHELL:-include stdint.h"
            "SHELL:-include stdlib.h"
            "SHELL:-include string.h"
            -w
        )
    endif()

    add_library(mp3::mp3 ALIAS mp3lame)
    set(MP3_FOUND TRUE)
    set(LAME_INCLUDE_DIR "${_LAME_SRC_DIR}/include" CACHE INTERNAL "")
    message(STATUS "Vendored libmp3lame built (3.100, from ${_LAME_SRC_DIR})")
endif()

# Export helpful vars
set(HAVE_MP3 ${MP3_FOUND} CACHE INTERNAL "Whether MP3 (libmp3lame) is available")
