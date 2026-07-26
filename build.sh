#!/usr/bin/env bash
#
# Build LineageOS kernel for Xiaomi Poco X3 NFC (surya/karna)
# and package it as an AnyKernel3 ZIP.
#

set -Eeuo pipefail

SECONDS=0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"

TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${ROOT_DIR}/toolchains/clang-17}"

# Official AOSP prebuilt DTC and ufdt_apply_overlay.
DTC_TOOLS_DIR="${DTC_TOOLS_DIR:-${ROOT_DIR}/toolchains/android-prebuilts-misc}"
DTC_TOOLS_REV="${DTC_TOOLS_REV:-android-platform-15.0.0_r17}"
DTC_BIN="${DTC_TOOLS_DIR}/linux-x86/dtc/dtc"
UFDT_APPLY_OVERLAY="${DTC_TOOLS_DIR}/linux-x86/libufdt/ufdt_apply_overlay"
DTC_REVISION_FILE="${DTC_TOOLS_DIR}/.requested-revision"

# Official AOSP mkdtboimg.py.
LIBUFDT_DIR="${LIBUFDT_DIR:-${ROOT_DIR}/toolchains/libufdt}"
LIBUFDT_REV="${LIBUFDT_REV:-android-platform-15.0.0_r17}"
MKDTBOIMG="${LIBUFDT_DIR}/utils/src/mkdtboimg.py"
LIBUFDT_REVISION_FILE="${LIBUFDT_DIR}/.requested-revision"

AK3_CACHE_DIR="${AK3_CACHE_DIR:-${ROOT_DIR}/toolchains/AnyKernel3}"
AK3_WORK_DIR="${ROOT_DIR}/AnyKernel3-build"

DEFCONFIG="${DEFCONFIG:-surya_defconfig}"
JOBS="${JOBS:-$(nproc)}"
ANDROID_VERSION="${ANDROID_VERSION:-15}"
KERNEL_STRING="${KERNEL_STRING:-PocoX3 Lineage22 non-GKI ReSukiSU}"
ZIP_PREFIX="${ZIP_PREFIX:-surya-lineage22-resukisu}"


BOOT_DIR="${OUT_DIR}/arch/arm64/boot"
DTS_DIR="${BOOT_DIR}/dts/qcom"

KERNEL_IMAGE="${BOOT_DIR}/Image.gz"
DTB_SOURCE="${DTS_DIR}/sdmmagpie.dtb"
DTBO_SOURCE="${DTS_DIR}/sdmmagpie-idp-overlay.dtbo"
DTB_IMAGE="${BOOT_DIR}/dtb.img"
DTBO_IMAGE="${BOOT_DIR}/dtbo.img"

BUILD_LOG="${ROOT_DIR}/build.log"

COMMIT_SUFFIX=""
if git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    COMMIT_SUFFIX="-$(git -C "${ROOT_DIR}" rev-parse --short=8 HEAD)"
fi

ZIP_NAME="${ZIP_PREFIX}-$(date '+%Y%m%d-%H%M')${COMMIT_SUFFIX}.zip"
ZIP_PATH="${ROOT_DIR}/${ZIP_NAME}"

MAKE_ARGS=(
    O="${OUT_DIR}"
    ARCH=arm64
    SUBARCH=arm64

    LLVM=1
    LLVM_IAS=1

    CC=clang
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip

    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-

    DTC_EXT="${DTC_BIN}"
    DTC_OVERLAY_TEST_EXT="${UFDT_APPLY_OVERLAY}"
)

download_toolchain() {
    if [[ -x "${TOOLCHAIN_DIR}/bin/clang" ]]; then
        return
    fi

    echo "AOSP Clang not found. Cloning to ${TOOLCHAIN_DIR}..."

    mkdir -p "$(dirname "${TOOLCHAIN_DIR}")"

    git clone \
        --depth=1 \
        --branch 17 \
        https://gitlab.com/ThankYouMario/android_prebuilts_clang-standalone.git \
        "${TOOLCHAIN_DIR}"
}

prepare_dtc_tools() {
    if [[ -x "${DTC_BIN}" ]] &&
       [[ -x "${UFDT_APPLY_OVERLAY}" ]] &&
       [[ -f "${DTC_REVISION_FILE}" ]] &&
       grep -qxF "${DTC_TOOLS_REV}" "${DTC_REVISION_FILE}"; then
        return
    fi

    echo "Cloning official AOSP prebuilt DTC tools (${DTC_TOOLS_REV})..."

    rm -rf "${DTC_TOOLS_DIR}"
    mkdir -p "$(dirname "${DTC_TOOLS_DIR}")"

    git clone \
        --depth=1 \
        --filter=blob:none \
        --no-checkout \
        --branch "${DTC_TOOLS_REV}" \
        https://android.googlesource.com/platform/prebuilts/misc \
        "${DTC_TOOLS_DIR}"

    git -C "${DTC_TOOLS_DIR}" sparse-checkout init --cone
    git -C "${DTC_TOOLS_DIR}" sparse-checkout set \
        linux-x86/dtc \
        linux-x86/libufdt
    git -C "${DTC_TOOLS_DIR}" checkout "${DTC_TOOLS_REV}"

    chmod +x "${DTC_BIN}" "${UFDT_APPLY_OVERLAY}"
    printf '%s\n' "${DTC_TOOLS_REV}" > "${DTC_REVISION_FILE}"

    if [[ ! -x "${DTC_BIN}" ]]; then
        echo "ERROR: DTC was not downloaded: ${DTC_BIN}"
        exit 1
    fi

    if [[ ! -x "${UFDT_APPLY_OVERLAY}" ]]; then
        echo "ERROR: ufdt_apply_overlay was not downloaded: ${UFDT_APPLY_OVERLAY}"
        exit 1
    fi
}

prepare_libufdt() {
    if [[ -f "${MKDTBOIMG}" ]] &&
       [[ -f "${LIBUFDT_REVISION_FILE}" ]] &&
       grep -qxF "${LIBUFDT_REV}" "${LIBUFDT_REVISION_FILE}"; then
        return
    fi

    echo "Cloning official AOSP libufdt (${LIBUFDT_REV})..."

    rm -rf "${LIBUFDT_DIR}"
    mkdir -p "$(dirname "${LIBUFDT_DIR}")"

    git clone \
        --depth=1 \
        --branch "${LIBUFDT_REV}" \
        https://android.googlesource.com/platform/system/libufdt \
        "${LIBUFDT_DIR}"

    chmod +x "${MKDTBOIMG}"
    printf '%s\n' "${LIBUFDT_REV}" > "${LIBUFDT_REVISION_FILE}"

    if [[ ! -f "${MKDTBOIMG}" ]]; then
        echo "ERROR: mkdtboimg.py was not downloaded: ${MKDTBOIMG}"
        exit 1
    fi
}

prepare_anykernel() {
    if [[ ! -d "${AK3_CACHE_DIR}/.git" ]]; then
        echo "Cloning AnyKernel3 template..."

        mkdir -p "$(dirname "${AK3_CACHE_DIR}")"

        git clone \
            --depth=1 \
            --branch FSociety \
            https://github.com/rd-stuffs/AnyKernel3.git \
            "${AK3_CACHE_DIR}"
    else
        echo "Updating AnyKernel3 template..."

        git -C "${AK3_CACHE_DIR}" fetch --depth=1 origin FSociety
        git -C "${AK3_CACHE_DIR}" reset --hard origin/FSociety
        git -C "${AK3_CACHE_DIR}" clean -fdx
    fi

    rm -rf "${AK3_WORK_DIR}"
    cp -a "${AK3_CACHE_DIR}" "${AK3_WORK_DIR}"
    rm -rf "${AK3_WORK_DIR}/.git"
}

generate_config() {
    echo "Generating configuration..."

    make "${MAKE_ARGS[@]}" "${DEFCONFIG}"
}

build_kernel() {
    echo
    echo "Building kernel with ${JOBS} jobs..."
    echo "External DTC: ${DTC_BIN}"
    echo "Overlay test: ${UFDT_APPLY_OVERLAY}"
    echo

    make \
        -j"${JOBS}" \
        "${MAKE_ARGS[@]}" \
        Image.gz \
        dtbs \
        2>&1 | tee "${BUILD_LOG}"
}

create_device_tree_images() {
    for file in \
        "${KERNEL_IMAGE}" \
        "${DTB_SOURCE}" \
        "${DTBO_SOURCE}"
    do
        if [[ ! -s "${file}" ]]; then
            echo "ERROR: Missing build result: ${file}"

            echo
            echo "Available DTB/DTBO files:"

            find "${DTS_DIR}" \
                -maxdepth 1 \
                -type f \
                \( -name '*.dtb' -o -name '*.dtbo' \) \
                -printf '%f\n' \
                2>/dev/null | sort

            exit 1
        fi
    done

    echo
    echo "Creating dtb.img..."

    cp -f "${DTB_SOURCE}" "${DTB_IMAGE}"

    echo "Creating dtbo.img..."

    rm -f "${DTBO_IMAGE}"

    python3 "${MKDTBOIMG}" create \
        "${DTBO_IMAGE}" \
        --page_size=4096 \
        "${DTBO_SOURCE}"

    for file in \
        "${DTB_IMAGE}" \
        "${DTBO_IMAGE}"
    do
        if [[ ! -s "${file}" ]]; then
            echo "ERROR: Failed to create ${file}"
            exit 1
        fi
    done
}

validate_and_customize_anykernel() {
    local anykernel_sh="${AK3_WORK_DIR}/anykernel.sh"

    if [[ ! -f "${anykernel_sh}" ]]; then
        echo "ERROR: AnyKernel3 anykernel.sh is missing"
        exit 1
    fi

    # This build intentionally uses the surya/karna-specific Richard fork.
    # Abort if upstream parameters change instead of creating a potentially
    # unsafe flashable ZIP.
    local required_lines=(
        "do.devicecheck=1"
        "do.modules=0"
        "do.systemless=0"
        "device.name1=surya"
        "device.name2=karna"
        "supported.versions=11-16"
        "BLOCK=/dev/block/bootdevice/by-name/boot;"
        "IS_SLOT_DEVICE=0;"
        "RAMDISK_COMPRESSION=auto;"
        "PATCH_VBMETA_FLAG=auto;"
    )

    local required
    for required in "${required_lines[@]}"; do
        if ! grep -qxF "${required}" "${anykernel_sh}"; then
            echo "ERROR: Unexpected AnyKernel3 configuration."
            echo "Missing required line: ${required}"
            exit 1
        fi
    done

    if ! grep -qF 'patch_legacy_bootargs;' "${anykernel_sh}"; then
        echo "ERROR: Richard AnyKernel3 legacy bootargs handling is missing"
        exit 1
    fi

    if ! grep -qF 'write_boot;' "${anykernel_sh}"; then
        echo "ERROR: AnyKernel3 write_boot call is missing"
        exit 1
    fi

    if grep -qE 'init\.tuna|fstab\.tuna|omap_hsmmc' "${anykernel_sh}"; then
        echo "ERROR: Incompatible tuna/OMAP ramdisk patches detected"
        exit 1
    fi

    sed -i \
        "s|^kernel\.string=.*$|kernel.string=${KERNEL_STRING}|" \
        "${anykernel_sh}"

    if ! grep -qxF "kernel.string=${KERNEL_STRING}" "${anykernel_sh}"; then
        echo "ERROR: Failed to set AnyKernel3 kernel.string"
        exit 1
    fi

    # Richard's anykernel.sh reads this file to select Android-version-specific
    # legacy eBPF and timestamp boot arguments.
    printf '%s\n' "${ANDROID_VERSION}" > "${AK3_WORK_DIR}/android_ver"

    echo
    echo "AnyKernel3 configuration:"
    grep -E \
        '^(kernel\.string|do\.devicecheck|do\.modules|do\.systemless|device\.name|supported\.versions|BLOCK=|IS_SLOT_DEVICE=|RAMDISK_COMPRESSION=|PATCH_VBMETA_FLAG=)' \
        "${anykernel_sh}"
    echo "android_ver=${ANDROID_VERSION}"
}

package_anykernel() {
    echo
    echo "Packaging AnyKernel3 ZIP..."

    prepare_anykernel
    validate_and_customize_anykernel

    cp -f "${KERNEL_IMAGE}" "${AK3_WORK_DIR}/Image.gz"
    cp -f "${DTB_IMAGE}" "${AK3_WORK_DIR}/dtb.img"
    cp -f "${DTBO_IMAGE}" "${AK3_WORK_DIR}/dtbo.img"

    rm -f "${ZIP_PATH}"

    (
        cd "${AK3_WORK_DIR}"

        zip -r9 "${ZIP_PATH}" . \
            -x '*.git*' \
            -x 'README.md' \
            -x '*placeholder*'
    )

    rm -rf "${AK3_WORK_DIR}"
}

case "${1:-}" in
    -c|--clean)
        rm -rf "${OUT_DIR}" "${AK3_WORK_DIR}"
        rm -f "${BUILD_LOG}"
        echo "Cleaned output directory"
        exit 0
        ;;

    -r|--regen)
        download_toolchain
        prepare_dtc_tools

        export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
        mkdir -p "${OUT_DIR}"

        make "${MAKE_ARGS[@]}" "${DEFCONFIG}"
        make "${MAKE_ARGS[@]}" savedefconfig
        cp "${OUT_DIR}/defconfig" \
            "${ROOT_DIR}/arch/arm64/configs/${DEFCONFIG}"

        echo "Regenerated arch/arm64/configs/${DEFCONFIG}"
        exit 0
        ;;

    -rf|--regen-full)
        download_toolchain
        prepare_dtc_tools

        export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
        mkdir -p "${OUT_DIR}"

        make "${MAKE_ARGS[@]}" "${DEFCONFIG}"
        cp "${OUT_DIR}/.config" \
            "${ROOT_DIR}/arch/arm64/configs/${DEFCONFIG}"

        echo "Regenerated full arch/arm64/configs/${DEFCONFIG}"
        exit 0
        ;;
esac

if [[ "${CLEAN:-0}" == "1" ]]; then
    rm -rf "${OUT_DIR}" "${AK3_WORK_DIR}"
    rm -f "${BUILD_LOG}"
fi

download_toolchain
prepare_dtc_tools
prepare_libufdt

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-surya}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-debian}"
export DTC_EXT="${DTC_BIN}"
export DTC_OVERLAY_TEST_EXT="${UFDT_APPLY_OVERLAY}"

echo "Kernel source: ${ROOT_DIR}"
echo "Output:        ${OUT_DIR}"
echo "Toolchain:     ${TOOLCHAIN_DIR}"
echo "DTC tools:     ${DTC_TOOLS_DIR}"
echo "DTC revision:  ${DTC_TOOLS_REV}"
echo "libufdt:       ${LIBUFDT_DIR}"
echo "Defconfig:     ${DEFCONFIG}"
echo "Kernel string: ${KERNEL_STRING}"
echo "Android:       ${ANDROID_VERSION}"
echo
echo "Compiler:"
clang --version
echo
echo "DTC:"
"${DTC_BIN}" --version

mkdir -p "${OUT_DIR}"

generate_config
build_kernel
create_device_tree_images
package_anykernel

echo
echo "Build outputs:"

ls -lh \
    "${KERNEL_IMAGE}" \
    "${DTB_IMAGE}" \
    "${DTBO_IMAGE}" \
    "${ZIP_PATH}"

echo
echo "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)"
echo "${ZIP_PATH}"
