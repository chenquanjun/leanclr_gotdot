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