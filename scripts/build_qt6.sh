#!/bin/bash

set -euo pipefail


# Enable script debugging if the DEBUG environment variable is set and non-zero.
if [ "${DEBUG:-0}" -ne 0 ]; then
    set -x
fi

CORE_COUNT="$(expr $(nproc) - 2)"

function download_toolchain() {
    mkdir -p cross-tools && cd cross-tools

    BINUTILS_PATH=binutils-2.40.tar.gz
    GLIBC_PATH=glibc-2.36.tar.gz
    GCC_PATH=gcc-12.2.0.tar.gz

    if [ ! -f "$BINUTILS_PATH" ]; then
        wget https://mirror.lyrahosting.com/gnu/binutils/$BINUTILS_PATH
        tar xf $BINUTILS_PATH
    fi

    if [ ! -f "$GLIBC_PATH" ]; then
        wget https://ftp.nluug.nl/pub/gnu/glibc/$GLIBC_PATH
        tar xf $GLIBC_PATH
    fi

    if [ ! -f "$GCC_PATH" ]; then
        wget https://ftp.nluug.nl/pub/gnu/gcc/gcc-12.2.0/$GCC_PATH
        tar xf $GCC_PATH
    fi

    if [ ! -d "./linux" ]; then
        git clone --depth=1 https://github.com/raspberrypi/linux
    fi
}

function compile_toolchain() {
    export PATH=/opt/cross-pi-gcc/bin:$PATH
    mkdir -p /opt/cross-pi-gcc

    cd /build/cross-tools/linux/
    KERNEL=kernel8
    make ARCH=arm64 INSTALL_HDR_PATH=/opt/cross-pi-gcc/aarch64-linux-gnu headers_install

    if [ -d "/opt/cross-pi-gcc/bin" ] && [ "$(ls -A /opt/cross-pi-gcc/bin)" ]; then
        echo "Toolchain already exists."
        return
    fi

    cd ../
    mkdir -p build-binutils && cd build-binutils
    ../binutils-2.40/configure --prefix=/opt/cross-pi-gcc --target=aarch64-linux-gnu --with-arch=armv8 --disable-multilib
    make -j"${CORE_COUNT}"
    make install
    echo "Binutils done"

    cd ../
    sed -i '66a #ifndef PATH_MAX\n#define PATH_MAX 4096\n#endif' /build/cross-tools/gcc-12.2.0/libsanitizer/asan/asan_linux.cpp

    mkdir -p build-gcc && cd build-gcc
    ../gcc-12.2.0/configure --prefix=/opt/cross-pi-gcc --target=aarch64-linux-gnu --enable-languages=c,c++ --disable-multilib
    make -j"${CORE_COUNT}" all-gcc
    make install-gcc
    echo "Compile glibc partly"

    cd ../
    mkdir -p build-glibc && cd build-glibc
    ../glibc-2.36/configure \
        --prefix=/opt/cross-pi-gcc/aarch64-linux-gnu \
        --build=$MACHTYPE \
        --host=aarch64-linux-gnu \
        --target=aarch64-linux-gnu \
        --with-headers=/opt/cross-pi-gcc/aarch64-linux-gnu/include \
        --disable-multilib \
        libc_cv_forced_unwind=yes
    make install-bootstrap-headers=yes install-headers
    make -j"${CORE_COUNT}" csu/subdir_lib
    install csu/crt1.o csu/crti.o csu/crtn.o /opt/cross-pi-gcc/aarch64-linux-gnu/lib
    aarch64-linux-gnu-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o /opt/cross-pi-gcc/aarch64-linux-gnu/lib/libc.so
    touch /opt/cross-pi-gcc/aarch64-linux-gnu/include/gnu/stubs.h
    echo "Build gcc partly"

    cd ../build-gcc/
    make -j"${CORE_COUNT}" all-target-libgcc
    make install-target-libgcc
    echo "build complete glibc"

    cd ../build-glibc/
    make -j"${CORE_COUNT}"
    make install
    echo "build complete gcc"

    cd ../build-gcc/
    make -j"${CORE_COUNT}"
    make install
    echo "Is finished"
}

function setup_sysroot() {
    cd /build
    mkdir -p sysroot sysroot/usr sysroot/opt
    cp /tmp/rasp.tar.gz .
    tar xfz /build/rasp.tar.gz -C /build/sysroot

    if [ ! -d "./firmware" ]; then
        git clone --depth=1 https://github.com/raspberrypi/firmware firmware
    fi

    if [ -d "./firmware/opt" ]; then
        cp -r ./firmware/opt sysroot
    else
        echo "./firmware/opt does not exist. Skipping..."
    fi
}

function copy_toolchain_cmake() {
    cp /src/toolchain.cmake /build
}

function fix_symbolic_links() {
    SYSROOT_RELATIVE_LINKS_SCRIPT="sysroot-relativelinks.py"
    SYSROOT_RELATIVE_LINKS_DOWNLOAD_URL="https://raw.githubusercontent.com/riscv/riscv-poky/master/scripts/${SYSROOT_RELATIVE_LINKS_SCRIPT}"

    echo "Fix symbollic links"

    if [ -f "${SYSROOT_RELATIVE_LINKS_SCRIPT}" ]; then
        echo "Script ${SYSROOT_RELATIVE_LINKS_SCRIPT} already exists. Skipping download..."
        return
    fi

    wget "${SYSROOT_RELATIVE_LINKS_DOWNLOAD_URL}"
    chmod +x sysroot-relativelinks.py
    python3 sysroot-relativelinks.py /build/sysroot
}

function install_qt() {
    QT_MAJOR='6'
    QT_MINOR='6'
    QT_PATCH='3'
    QT_VERSION="${QT_MAJOR}.${QT_MINOR}.${QT_PATCH}"
    QT_DOWNLOAD_BASE_URL="https://download.qt.io/official_releases/qt/${QT_MAJOR}.${QT_MINOR}/${QT_VERSION}/submodules"
    QT_ARCHIVE_FILES=(
        "qtbase-everywhere-src-${QT_VERSION}.tar.xz"
        "qtshadertools-everywhere-src-${QT_VERSION}.tar.xz"
        "qtdeclarative-everywhere-src-${QT_VERSION}.tar.xz"
    )
    QT6_DIR="/build/qt6"
    QT6_SRC_PATH="${QT6_DIR}/src"
    QT6_HOST_BUILD_PATH="${QT6_DIR}/host-build"
    QT6_HOST_STAGING_PATH="${QT6_DIR}/host"
    QT6_PI_BUILD_PATH="${QT6_DIR}/pi-build"
    QT6_PI_STAGING_PATH="${QT6_DIR}/pi"

    cd /build
    mkdir -p qt6 qt6/host qt6/pi qt6/host-build qt6/pi-build qt6/src

    cd ${QT6_SRC_PATH}

    for QT_ARCHIVE_FILE in "${QT_ARCHIVE_FILES[@]}"; do
        if [ ! -f "${QT_ARCHIVE_FILE}" ]; then
            wget "${QT_DOWNLOAD_BASE_URL}/${QT_ARCHIVE_FILE}"
        else
            echo "File ${QT_ARCHIVE_FILE} already exists. Skipping download..."
        fi
    done

    cd ${QT6_HOST_BUILD_PATH}

    for QT_ARCHIVE_FILE in "${QT_ARCHIVE_FILES[@]}"; do
        tar xf ${QT6_SRC_PATH}/${QT_ARCHIVE_FILE}
    done

    echo "Compile qtbase for host"
    cd ${QT6_HOST_BUILD_PATH}/qtbase-everywhere-src-${QT_VERSION}
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release \
        -DQT_BUILD_EXAMPLES=OFF \
        -DQT_BUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX=${QT6_HOST_STAGING_PATH}
    cmake --build . --parallel "${CORE_COUNT}"
    cmake --install .

    echo "Compile shader for host"
    cd ${QT6_HOST_BUILD_PATH}/qtshadertools-everywhere-src-${QT_VERSION}
    /build/qt6/host/bin/qt-configure-module .
    cmake --build . --parallel "${CORE_COUNT}"
    cmake --install .

    echo "Compile declerative for host"
    cd ${QT6_HOST_BUILD_PATH}/qtdeclarative-everywhere-src-${QT_VERSION}
    /build/qt6/host/bin/qt-configure-module .
    cmake --build . --parallel "${CORE_COUNT}"
    cmake --install .

    cd ${QT6_PI_BUILD_PATH}

    for QT_ARCHIVE_FILE in "${QT_ARCHIVE_FILES[@]}"; do
        tar xf ${QT6_SRC_PATH}/${QT_ARCHIVE_FILE}
    done

    echo "Compile qtbase for rasp"
    cd ${QT6_PI_BUILD_PATH}/qtbase-everywhere-src-${QT_VERSION}
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DINPUT_opengl=es2 \
        -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF \
        -DQT_HOST_PATH=${QT6_HOST_STAGING_PATH} \
        -DCMAKE_STAGING_PREFIX=${QT6_PI_STAGING_PATH} \
        -DCMAKE_INSTALL_PREFIX=/usr/local/qt6 \
        -DCMAKE_TOOLCHAIN_FILE=/build/toolchain.cmake \
        -DQT_FEATURE_xcb=ON -DFEATURE_xcb_xlib=ON \
        -DQT_FEATURE_xlib=ON
    cmake --build . --parallel "${CORE_COUNT}"
    cmake --install .

    echo "Compile shader for rasp"
    cd ${QT6_PI_BUILD_PATH}/qtshadertools-everywhere-src-${QT_VERSION}
    ${QT6_PI_STAGING_PATH}/bin/qt-configure-module .
    cmake --build . --parallel "${CORE_COUNT}"
    cmake --install .

    echo "Compile declerative for rasp"
    cd ${QT6_PI_BUILD_PATH}/qtdeclarative-everywhere-src-${QT_VERSION}
    ${QT6_PI_STAGING_PATH}/bin/qt-configure-module .
    cmake --build . --parallel "${CORE_COUNT}"
    cmake --install .

    echo "Compilation is finished"
}

function create_qt_archive() {
    cd /build
    mkdir -p release && cd release
    tar -czvf qt-host-binaries.tar.gz -C /build/qt6/host .
    tar -czvf cross-pi-gcc.tar.gz -C /opt/cross-pi-gcc .
    tar -czvf qt-pi-binaries.tar.gz -C /build/qt6/pi .
}

function main() {
    download_toolchain
    compile_toolchain
    setup_sysroot
    copy_toolchain_cmake

    fix_symbolic_links
    install_qt
    # create_qt_archive # TODO: Uncomment this line to create the archive.
}

main
