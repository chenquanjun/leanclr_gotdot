cmake_minimum_required(VERSION 3.20)
project(leanclr_godot LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Linux/macOS 下 leanclr 静态库需以 PIC 编译才能链接进 shared library
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(GODOTCPP_TARGET "template_debug" CACHE STRING "Godot build target")
add_subdirectory(native/thirdparty/godot-cpp godot-cpp)

set(BUILD_SHARED_LEANCLR OFF CACHE BOOL "" FORCE)
add_subdirectory(native/thirdparty/leanclr/src/runtime leanclr_runtime)

# leanclr 内置的 3rd/zlib 由上游 ./configure 定义 HAVE_UNISTD_H；这里直接 GLOB 编译
# 其 .c 文件，构建系统不会自动定义。缺失时 zlib 的 gzguts.h/zconf.h 不会包含
# <unistd.h>，gzlib.c/gzread.c/gzwrite.c 里的 read/write/close/lseek 变成隐式声明
# （GCC 14+ 默认 -Werror=implicit-function-declaration，Linux CI 直接编译失败）。
# Windows 走 <io.h> 分支，所以只在 UNIX（Linux/macOS/iOS/Android）上补这个特性宏。
if(UNIX)
    target_compile_definitions(leanclr PRIVATE HAVE_UNISTD_H=1)
endif()

add_library(leanclr_godot SHARED
    native/src/register_types.cpp
    native/src/leanclr_runtime.cpp
    native/src/leanclr_node.cpp
)
target_include_directories(leanclr_godot PRIVATE native/src)
target_link_libraries(leanclr_godot PRIVATE godot::cpp leanclr)
set_target_properties(leanclr_godot PROPERTIES
    PREFIX ""
    OUTPUT_NAME "leanclr_godot"
)

add_executable(leanclr_smoke native/src/smoke_main.cpp)
target_include_directories(leanclr_smoke PRIVATE native/src)
target_link_libraries(leanclr_smoke PRIVATE leanclr)