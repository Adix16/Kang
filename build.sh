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
    # If no commit specified, pull latest changes
    git pull origin "$(git for-each-ref --format '%(refname:lstrip=2)' refs/heads | head -1)"
    git submodule update --init --recursive
  else
    # If commit specified, reset to that commit
    git diff --quiet HEAD || git reset --hard HEAD
    git checkout $KERNEL_COMMIT || exit 1
    git submodule update --init --recursive
  fi

  cd -
}


remove_kernelsu() {
    # Navigate to kernel source root first
    cd build/kernel || {
        echo "Error: Could not find build/kernel directory"
        return 1
    }

    # --- Remove KernelSU from drivers ---
    echo "Processing drivers directory..."
    cd drivers || {
        echo "Error: Could not find drivers directory"
        return 1
    }

    # Show files before deletion (for debugging)
    if [ -d "kernelsu" ]; then
        echo "Found KernelSU with these files:"
        ls -l kernelsu/
    fi

    # Remove KernelSU directory if it exists
    if [ -d "kernelsu" ]; then
        echo "Removing KernelSU directory..."
        rm -rf kernelsu
    fi

    # Remove KernelSU from Kconfig
    if [ -f "Kconfig" ]; then
        if grep -q 'source "drivers/kernelsu/Kconfig"' Kconfig; then
            echo "Removing KernelSU from drivers/Kconfig..."
            sed -i '/source "drivers\/kernelsu\/Kconfig"/d' Kconfig
        fi
    fi

    # Remove KernelSU from Makefile
    if [ -f "Makefile" ]; then
        if grep -q 'obj-$(CONFIG_KSU) += kernelsu/' Makefile; then
            echo "Removing KernelSU from drivers/Makefile..."
            sed -i '/obj-$(CONFIG_KSU) += kernelsu\//d' Makefile
        fi
    fi

    # Verify drivers deletion
    if [ ! -d "kernelsu" ]; then
        echo "KernelSU drivers removal successful"
    else
        echo "Warning: KernelSU drivers directory still exists!"
        return 1
    fi

    cd ..

    # --- Remove KernelSU references from devpts ---
    echo "Processing devpts files..."
    if [ -f "fs/devpts/inode.c" ]; then
        echo "Removing KernelSU references from fs/devpts/inode.c"
        sed -i '/extern int ksu_handle_devpts(struct inode\*);/d' fs/devpts/inode.c
        sed -i '/ksu_handle_devpts(dentry->d_inode);/d' fs/devpts/inode.c
        
        # Verify removal
        if grep -qE 'ksu_handle_devpts|extern int ksu_handle_devpts' fs/devpts/inode.c; then
            echo "Warning: Failed to remove all KernelSU references from fs/devpts/inode.c"
            return 1
        fi
    else
        echo "Warning: fs/devpts/inode.c not found"
    fi

    cd - >/dev/null
}

build_kernel() {
  cd build/kernel

  make "${MAKE_FLAGS[@]}" vendor/kona-perf_defconfig vendor/xiaomi/sm8250-common.config vendor/debugfs.config vendor/xiaomi/pipa.config
  
  # compile kernel with error logging
  make "${MAKE_FLAGS[@]}" -j$(nproc --all) 2> >(tee -a error.log >&2) || exit 3

  cd -
}

package_kernel() {
  # Create output directory
  mkdir -p build/output

  # Verify Image exists
  if [ -f "build/kernel/out/arch/arm64/boot/Image" ]; then
    echo "Kernel Image exists. Packaging..."
  else
    echo "Error: Kernel Image not found!"
    exit 1
  fi

  # Copy kernel artifacts
  cp build/kernel/out/arch/arm64/boot/Image build/output/
  cp build/kernel/out/arch/arm64/boot/dtb build/output/
  cp build/kernel/out/arch/arm64/boot/dtbo.img build/output/

  # Create zip file with timestamp and commit ID
  cd build/output
  ZIP_FILENAME=Kernel_pipa_$(date +'%Y%m%d_%H%M%S')_${KERNEL_COMMIT:0:8}.zip
  zip -r9 ../$ZIP_FILENAME ./*
  cd -

  echo "Kernel artifacts packaged at build/$ZIP_FILENAME"
}

prepare_env
get_sources
remove_kernelsu
build_kernel
package_kernel
