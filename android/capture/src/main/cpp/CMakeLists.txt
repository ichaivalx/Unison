cmake_minimum_required(VERSION 3.22)
project(unison_capture LANGUAGES C)
add_library(unison_capture SHARED capture_signals.c)
target_compile_options(unison_capture PRIVATE -Wall -Wextra -Werror)
