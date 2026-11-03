cmake_minimum_required(VERSION 3.22)
project(unison_android LANGUAGES CXX)
add_library(unison SHARED receiver_android.cpp)
target_compile_features(unison PRIVATE cxx_std_17)
