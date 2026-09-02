cmake_minimum_required(VERSION 3.16)
project(Kinect360RemoldLinux VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(GNUInstallDirs)
find_package(Threads REQUIRED)

option(REMOLD_BUILD_HARDWARE "Build Kinect hardware services" ON)
option(REMOLD_BUILD_IP_CAMERA "Build the native HTTP/MJPEG camera" ON)

add_library(remold_common INTERFACE)
target_include_directories(remold_common INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(remold_common INTERFACE _FILE_OFFSET_BITS=64)

add_executable(kinect360-remoldctl src/remoldctl.cpp)
target_link_libraries(kinect360-remoldctl PRIVATE remold_common Threads::Threads)

if(REMOLD_BUILD_HARDWARE)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0)
  pkg_check_modules(ALSA REQUIRED IMPORTED_TARGET alsa)


  add_executable(kinect360-remold-broker src/broker.cpp)
  target_link_libraries(kinect360-remold-broker PRIVATE remold_common PkgConfig::LIBUSB Threads::Threads)

  add_executable(kinect360-remold-camera src/camera_bridge.cpp src/kinect_usb_camera.cpp)
  target_link_libraries(kinect360-remold-camera PRIVATE remold_common PkgConfig::LIBUSB Threads::Threads)

  add_executable(kinect360-remold-audio src/audio_bridge.cpp)
  target_link_libraries(kinect360-remold-audio PRIVATE remold_common PkgConfig::LIBUSB PkgConfig::ALSA Threads::Threads)

  add_executable(kinect360-remold-v4l2 src/v4l2_bridge.cpp)
  target_link_libraries(kinect360-remold-v4l2 PRIVATE remold_common Threads::Threads)

  if(REMOLD_BUILD_IP_CAMERA)
    find_package(JPEG REQUIRED)
    add_executable(kinect360-remold-camera-ip src/camera_ip.cpp)
    target_link_libraries(kinect360-remold-camera-ip PRIVATE remold_common JPEG::JPEG Threads::Threads)
  endif()
endif()

install(TARGETS kinect360-remoldctl RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
if(REMOLD_BUILD_HARDWARE)
  install(TARGETS kinect360-remold-broker kinect360-remold-camera kinect360-remold-audio kinect360-remold-v4l2
          RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/kinect360-remold)
  if(TARGET kinect360-remold-camera-ip)
    install(TARGETS kinect360-remold-camera-ip RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/kinect360-remold)
  endif()
endif()
