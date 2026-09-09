# Use the same pinned compiler arguments for upstream CMake and archive probes.
file(READ "${CMAKE_CURRENT_LIST_DIR}/../freetype.json" recipe)
string(JSON argument_count LENGTH "${recipe}" cc_args)
math(EXPR last_argument "${argument_count} - 1")
set(compiler_arguments "")
foreach(index RANGE ${last_argument})
  string(JSON argument GET "${recipe}" cc_args ${index})
  list(APPEND compiler_arguments "${argument}")
endforeach()
list(JOIN compiler_arguments " " compiler_arguments)
set(CMAKE_C_COMPILER /opt/zig/zig)
set(CMAKE_C_COMPILER_ARG1 "${compiler_arguments}")
# Zig's bundled libc search paths do not identify Ubuntu's multiarch directory
# to CMake. These additional dependencies come from the pinned builder image.
set(CMAKE_LIBRARY_PATH /usr/lib/x86_64-linux-gnu)
