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

deep_clean_kernelsu() {
    cd build/kernel || {
        echo "Error: Could not find build/kernel directory"
        return 1
    }

    # 1. Remove all KernelSU directories
    local su_dirs=($(find . -type d -name "*kernelsu*" -o -name "*ksu*"))
    for dir in "${su_dirs[@]}"; do
        echo "Removing directory: $dir"
        rm -rf "$dir"
    done

    # 2. Clean source files from KernelSU references
    local su_patterns=(
        "kernelsu"
        "ksu"
        "KERNEL_SU"
        "KSU_"
        "KernelSU"
        "kernel_su"
    )

    for pattern in "${su_patterns[@]}"; do
        echo "Removing $pattern references..."
        find . -type f \( -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "Kconfig*" \) \
            -exec sed -i "/$pattern/d" {} +
    done

    # 3. Clean config files
    echo "Purging KernelSU from configs..."
    find . -name "*config*" -type f -exec sed -i \
        '/CONFIG_KERNEL_SU/d; /CONFIG_KSU/d; /kernelsu/d; /ksu/d' {} +

    # 4. Ensure KernelSU is disabled in all configs
    echo "Disabling KernelSU in all configs..."
    find . -name "*defconfig" -type f -exec sh -c \
        "echo 'CONFIG_KERNEL_SU=n' >> {}; echo 'CONFIG_KSU=n' >> {}" \;

    # 5. Remove git history if requested (alternative approach)
    if [ "$PURGE_GIT_HISTORY" = "true" ]; then
        echo "Purging git history..."
        rm -rf .git
        find . -name ".git*" -exec rm -rf {} +
    fi

    cd - >/dev/null
}

build_kernel() {
  cd build/kernel

  # First try with original defconfig
  if ! make "${MAKE_FLAGS[@]}" vendor/kona-perf_defconfig vendor/xiaomi/sm8250-common.config vendor/xiaomi/pipa.config; then
      echo "First config attempt failed, trying alternative approach..."
      
      # Backup original configs
      mkdir -p config_backup
      cp arch/arm64/configs/vendor/* config_backup/ || true
      
      # Clean config directory
      rm -f arch/arm64/configs/vendor/*
      
      # Restore only essential configs
      cp config_backup/kona-perf_defconfig arch/arm64/configs/vendor/
      cp config_backup/xiaomi/sm8250-common.config arch/arm64/configs/vendor/
      cp config_backup/xiaomi/pipa.config arch/arm64/configs/vendor/
      
      # Retry build
      make "${MAKE_FLAGS[@]}" vendor/kona-perf_defconfig vendor/xiaomi/sm8250-common.config vendor/xiaomi/pipa.config || {
          echo "Failed to configure kernel after cleanup"
          exit 3
      }
  fi

  # compile kernel with error logging
  make "${MAKE_FLAGS[@]}" -j$(nproc --all) 2> >(tee -a error.log >&2) || exit 3

  cd -
}

package_kernel() {
  mkdir -p build/output

  if [ -f "build/kernel/out/arch/arm64/boot/Image" ]; then
    echo "Kernel Image exists. Packaging..."
  else
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
deep_clean_kernelsu

#Optionally purge git history if needed (uncomment to enable)
PURGE_GIT_HISTORY=true
deep_clean_kernelsu

build_kernel
package_kernel
