# Builds icdprobe with the driver's own C compiler (check.sh passes it in). Through CMake rather
# than by calling the compiler directly because, on Windows under Git Bash, cl.exe would otherwise
# pick up Git's unrelated link.exe from PATH.
cmake_minimum_required(VERSION 3.22)
project(icdprobe C)

set(SWIFTSHADER_INCLUDE "" CACHE PATH "SwiftShader's include/ directory, for the Vulkan headers")

add_executable(icdprobe icdprobe.c)
target_include_directories(icdprobe PRIVATE "${SWIFTSHADER_INCLUDE}")
target_compile_features(icdprobe PRIVATE c_std_99)
target_link_libraries(icdprobe PRIVATE ${CMAKE_DL_LIBS})
