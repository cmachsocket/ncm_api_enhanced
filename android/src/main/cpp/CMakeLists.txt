# CMakeLists.txt for the JNI wrapper that drives libnode.so.
#
# libnode.so is downloaded by hook/build.dart at build time and copied
# into android/src/main/jniLibs/<abi>/libnode.so by the same hook. The
# Android Gradle Plugin then packages that directory into the AAR's
# jniLibs/, so libnode.so ends up in the app's lib/<abi>/ at runtime.
#
# Our JNI library (libncm_node_bridge.so) links against libnode.so via
# CMake's IMPORTED target. native-lib.cpp exposes a thin JNI wrapper
# around node::Start + pipe redirections for stdin/stdout/stderr.
#
# libnode's C++ headers (node.h, etc.) are NOT needed at our level —
# we use the C-callable `node_start` export. If a future change needs
# the C++ API, extract node-mobile's `include/` into
# android/libnode/include/.

cmake_minimum_required(VERSION 3.22.1)
project(ncm_node_bridge)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(ncm_node_bridge SHARED
        native-lib.cpp)

# libnode (imported). Path comes from hook/build.dart, which copies the
# downloaded .so here before CMake runs.
add_library(node SHARED IMPORTED)
set_target_properties(node PROPERTIES
        IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/jniLibs/${ANDROID_ABI}/libnode.so")

include_directories(${CMAKE_SOURCE_DIR}/libnode/include/)

# libnode requires the LLVM libc++ STL (not gnustl).
target_compile_options(ncm_node_bridge PRIVATE
        -DANDROID_STL=c++_shared)

find_library(log-lib log)

target_link_libraries(ncm_node_bridge
        ${log-lib}
        android
        node)