#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2164,SC2103,SC2155,SC2129

# Configuration
KERNEL_SOURCE="https://github.com/CuriousNom/kernel_xiaomi_sm8250"
KERNEL_COMMIT="7b737646b3bb6650033466c3a9c850744cfeeb8d"
CLANG_URL="https://github.com/ZyCromerZ/Clang/releases/download/21.0.0git-20250322-release/Clang-21.0.0git-20250322.tar.gz"

# Initialize environment
prepare_env() {
  # Create required directories
  mkdir -p {build/kernel,download,output} || {
    echo "Failed to create directories"
    exit 1
  }

  # Setup toolchain
  local clang_pack="$(basename "$CLANG_URL")"
  if [ ! -f "download/$clang_pack" ]; then
    echo "Downloading toolchain..."
    wget -q "$CLANG_URL" -P download || {
      echo "Failed to download toolchain"
      exit 1
    }
  fi

  echo "Extracting toolchain..."
  mkdir -p build/clang && tar -C build/clang/ -zxf "download/$clang_pack" || {
    echo "Failed to extract toolchain"
    exit 1
  }

  # Build flags
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

  # Environment variables
  export PATH="$PWD/build/clang/bin:$PATH"
  export ARCH=arm64
  export SUBARCH=arm64
  export KBUILD_BUILD_USER="${GITHUB_REPOSITORY_OWNER:-pexcn}"
  export KBUILD_BUILD_HOST="buildbot"
  export KBUILD_COMPILER_STRING="$(clang --version | head -1 | sed 's/ (https.*//')"
  export KBUILD_LINKER_STRING="$(ld.lld --version | head -1 | sed 's/ (compatible.*//')"
}

# Get kernel sources
get_sources() {
  if [ ! -d "build/kernel/.git" ]; then
    echo "Cloning kernel source..."
    git clone "$KERNEL_SOURCE" --recurse-submodules build/kernel || {
      echo "Failed to clone kernel source"
      exit 1
    }
  fi

  cd build/kernel || exit 1

  if [ -n "$KERNEL_COMMIT" ]; then
    echo "Checking out commit: $KERNEL_COMMIT"
    git checkout "$KERNEL_COMMIT" || {
      echo "Failed to checkout commit"
      exit 1
    }
    git submodule update --init --recursive || {
      echo "Failed to update submodules"
      exit 1
    }
  else
    echo "Pulling latest changes..."
    git pull origin "$(git for-each-ref --format '%(refname:lstrip=2)' refs/heads | head -1)" || {
      echo "Failed to pull latest changes"
      exit 1
    }
    git submodule update --init --recursive || {
      echo "Failed to update submodules"
      exit 1
    }
  fi

  cd - >/dev/null || exit 1
}

# Remove KernelSU
remove_kernelsu() {
  cd build/kernel || {
    echo "Error: Kernel directory not found"
    exit 1
  }

  # Remove KernelSU drivers
  if [ -d "drivers/kernelsu" ]; then
    echo "Removing KernelSU drivers..."
    rm -rf drivers/kernelsu || {
      echo "Failed to remove KernelSU drivers"
      exit 1
    }
  fi

  # Clean Makefile references
  if [ -f "drivers/Makefile" ]; then
    sed -i '/obj-$(CONFIG_KSU) += kernelsu\//d' drivers/Makefile
  fi

  # Clean Kconfig references
  if [ -f "drivers/Kconfig" ]; then
    sed -i '/source "drivers\/kernelsu\/Kconfig"/d' drivers/Kconfig
  fi

  # Clean devpts references
  if [ -f "fs/devpts/inode.c" ]; then
    sed -i '/extern int ksu_handle_devpts(struct inode\*);/d' fs/devpts/inode.c
    sed -i '/ksu_handle_devpts(dentry->d_inode);/d' fs/devpts/inode.c
  fi

  echo "KernelSU removal completed successfully"
  cd - >/dev/null || exit 1
}

# Build kernel
build_kernel() {
  cd build/kernel || {
    echo "Error: Kernel directory not found"
    exit 1
  }

  echo "Configuring kernel..."
  make "${MAKE_FLAGS[@]}" vendor/kona-perf_defconfig vendor/xiaomi/sm8250-common.config vendor/xiaomi/pipa.config || {
    echo "Failed to configure kernel"
    exit 1
  }

  echo "Building kernel..."
  make "${MAKE_FLAGS[@]}" -j"$(nproc --all)" 2> >(tee -a error.log >&2) || {
    echo "Kernel build failed"
    exit 1
  }

  cd - >/dev/null || exit 1
}

# Package kernel
package_kernel() {
  echo "Packaging kernel..."
  mkdir -p build/output || {
    echo "Failed to create output directory"
    exit 1
  }

  # Verify and copy artifacts
  local artifacts=(
    "out/arch/arm64/boot/Image"
    "out/arch/arm64/boot/dtb"
    "out/arch/arm64/boot/dtbo.img"
  )

  for artifact in "${artifacts[@]}"; do
    if [ ! -f "build/kernel/$artifact" ]; then
      echo "Error: Missing artifact $artifact"
      exit 1
    fi
    cp "build/kernel/$artifact" build/output/ || {
      echo "Failed to copy $artifact"
      exit 1
    }
  done

  # Create zip package
  cd build/output || exit 1
  local zip_name="Kernel_pipa_$(date +'%Y%m%d_%H%M%S')_${KERNEL_COMMIT:0:8}.zip"
  zip -r9 "../$zip_name" ./* || {
    echo "Failed to create zip package"
    exit 1
  }
  cd - >/dev/null || exit 1

  echo "Kernel packaged successfully: build/$zip_name"
}

# Main execution flow
main() {
  prepare_env
  get_sources
  remove_kernelsu
  build_kernel
  package_kernel
}

main "$@"
