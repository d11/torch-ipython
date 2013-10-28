CMAKE_MINIMUM_REQUIRED(VERSION 2.6 FATAL_ERROR)
CMAKE_POLICY(VERSION 2.6)
FIND_PACKAGE(Torch REQUIRED)

SET(INSTALL_DOCUMENTATION OFF CACHE BOOL "Install the description in Torch tree")

# install the lua code for the ipython package
FILE(GLOB luasrc "*.lua")
ADD_TORCH_PACKAGE(ipython "${src}" "${luasrc}")

IF (INSTALL_DOCUMENTATION)
    SUBDIRS(doc)
ENDIF()
SUBDIRS(tests)
