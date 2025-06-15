#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2164,SC2103,SC2155,SC2129

KERNEL_SOURCE=https://github.com/CuriousNom/kernel_xiaomi_sm8250
KERNEL_COMMIT=7b737646b3bb6650033466c3a9c850744cfeeb8d

prepare_env() {
  mkdir -p build
  mkdir -p download

  # updatable part
  CLANG_URL=https://github.com/ZyCromerZ/Clang/releases/download/21.0.0git-20250322-release/Clang-21.0.0git-20250322.tar.gz

  # set local shell variables
  CUR_DIR=$(dirname "$(readlink -f "$0")")
  MAKE_FLAGS=(
    ARCH=arm64
    O=out
    CC="ccache clang"
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    LD=ld.lld
    AS=llvm-as
    READELF=llvm-readelf
    OBJSIZE=llvm-size
    HOSTCC=gcc
  )

  # setup clang
  local clang_pack="$(basename $CLANG_URL)"
  [ -f download/$clang_pack ] || wget -q $CLANG_URL -P download
  mkdir build/clang && tar -C build/clang/ -zxf download/$clang_pack

  # set environment variables
  export PATH=$CUR_DIR/build/clang/bin:$PATH
  export ARCH=arm64
  export SUBARCH=arm64
  export KBUILD_BUILD_USER=${GITHUB_REPOSITORY_OWNER:-pexcn}
  export KBUILD_BUILD_HOST=buildbot
  export KBUILD_COMPILER_STRING="$(clang --version | head -1 | sed 's/ (https.*//')"
  export KBUILD_LINKER_STRING="$(ld.lld --version | head -1 | sed 's/ (compatible.*//')"
}

get_sources() {
  [ -d build/kernel/.git ] || git clone $KERNEL_SOURCE --recurse-submodules build/kernel
  cd build/kernel
  
  if [ -z "$KERNEL_COMMIT" ]; then
    git pull origin "$(git for-each-ref --format '%(refname:lstrip=2)' refs/heads | head -1)"
    git submodule update --init --recursive
  else
    git diff --quiet HEAD || git reset --hard HEAD
    git checkout $KERNEL_COMMIT || exit 1
    git submodule update --init --recursive
  fi

  cd -
}

remove_kernelsu() {
    cd build/kernel || {
        echo "Error: Could not find build/kernel directory"
        return 1
    }

    # Remove KernelSU directory if exists
    if [ -d "drivers/kernelsu" ]; then
        echo "Removing KernelSU directory..."
        rm -rf drivers/kernelsu
    fi

    # Remove KernelSU from Kconfig
    if [ -f "drivers/Kconfig" ]; then
        sed -i '/source "drivers\/kernelsu\/Kconfig"/d' drivers/Kconfig
    fi

    # Remove KernelSU from Makefile
    if [ -f "drivers/Makefile" ]; then
        sed -i '/obj-$(CONFIG_KSU) += kernelsu\//d' drivers/Makefile
    fi

    # Disable KernelSU in config
    ./scripts/config --file .config \
        --disable KERNEL_SU \
        --disable KSU \
        --set-str CONFIG_KERNEL_SU "" \
        --set-str CONFIG_KSU ""

    cd - >/dev/null
}

build_kernel() {
  cd build/kernel

  # First ensure config is clean
  make "${MAKE_FLAGS[@]}" vendor/kona-perf_defconfig vendor/xiaomi/sm8250-common.config vendor/xiaomi/pipa.config

  # Force disable KernelSU in final config
  ./scripts/config --file out/.config \
      --disable KERNEL_SU \
      --disable KSU

  # Build with suppressed KernelSU errors
  {
    make "${MAKE_FLAGS[@]}" -j$(nproc --all) 2>&1 | \
    grep -v -E 'KSU|kernelsu|ksu|KernelSU' | \
    tee build.log
  } || {
    echo "Build completed with warnings (KernelSU references ignored)"
    # Continue even if there were other errors (within reason)
    if grep -q -E 'error:|undefined reference' build.log; then
        echo "Critical errors found in build.log"
        exit 3
    fi
  }

  cd -
}

package_kernel() {
  mkdir -p build/output

  if [ ! -f "build/kernel/out/arch/arm64/boot/Image" ]; then
    echo "Error: Kernel Image not found!"
    exit 1
  fi

  cp build/kernel/out/arch/arm64/boot/Image build/output/
  cp build/kernel/out/arch/arm64/boot/dtb build/output/
  cp build/kernel/out/arch/arm64/boot/dtbo.img build/output/

  cd build/output
  ZIP_FILENAME=Kernel_pipa_$(date +'%Y%m%d_%H%M%S')_${KERNEL_COMMIT:0:8}.zip
  zip -r9 ../$ZIP_FILENAME ./*
  cd -

  echo "Kernel artifacts packaged at build/$ZIP_FILENAME"
}

# Main execution
prepare_env
get_sources
remove_kernelsu
build_kernel
package_kernel
