#!/bin/bash

# Copyright (C) 2019 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Usage:
#   build/build.sh <make options>*
# or:
#   OUT_DIR=<out dir> DIST_DIR=<dist dir> build/build.sh <make options>*
#
# Example:
#   OUT_DIR=output DIST_DIR=dist build/build.sh -j24 V=1
#
#
# The following environment variables are considered during execution:
#
#   BUILD_CONFIG
#     Build config file to initialize the build environment from. The location
#     is to be defined relative to the repo root directory.
#     Defaults to 'build.config'.
#
#   OUT_DIR
#     Base output directory for the kernel build.
#     Defaults to <REPO_ROOT>/out/<BRANCH>.
#
#   DIST_DIR
#     Base output directory for the kernel distribution.
#     Defaults to <OUT_DIR>/dist
#
#   EXT_MODULES
#     Space separated list of external kernel modules to be build.
#
#   UNSTRIPPED_MODULES
#     Space separated list of modules to be copied to <DIST_DIR>/unstripped
#     for debugging purposes.
#
#   CC
#     Override compiler to be used. (e.g. CC=clang) Specifying CC=gcc
#     effectively unsets CC to fall back to the default gcc detected by kbuild
#     (including any target triplet). To use a custom 'gcc' from PATH, use an
#     absolute path, e.g.  CC=/usr/local/bin/gcc
#
#   LD
#     Override linker (flags) to be used.
#
#   ABI_DEFINITION
#     Location of the abi definition file relative to <REPO_ROOT>/KERNEL_DIR
#     If defined (usually in build.config), also copy that abi definition to
#     <OUT_DIR>/dist/abi.xml when creating the distribution.
#
# Environment variables to influence the stages of the kernel build.
#
#   SKIP_MRPROPER
#     if defined, skip `make mrproper`
#
#   SKIP_DEFCONFIG
#     if defined, skip `make defconfig`
#
#   PRE_DEFCONFIG_CMDS
#     Command evaluated before `make defconfig`
#
#   POST_DEFCONFIG_CMDS
#     Command evaluated after `make defconfig` and before `make`.
#
#   POST_KERNEL_BUILD_CMDS
#     Command evaluated after `make`.
#
#   IN_KERNEL_MODULES
#     if defined, install kernel modules
#
#   SKIP_EXT_MODULES
#     if defined, skip building and installing of external modules
#
#   EXTRA_CMDS
#     Command evaluated after building and installing kernel and modules.
#
#   SKIP_CP_KERNEL_HDR
#     if defined, skip installing kernel headers.
#
#   BUILD_BOOT_IMG
#     if defined, build a boot.img binary that can be flashed into the 'boot'
#     partition of an Android device. The boot image contains a header as per the
#     format defined by https://source.android.com/devices/bootloader/boot-image-header
#     followed by several components like kernel, ramdisk, DTB etc. The ramdisk
#     component comprises of a GKI ramdisk cpio archive concatenated with a
#     vendor ramdisk cpio archive which is then gzipped. It is expected that
#     all components are present in ${DIST_DIR}.
#
#     When the BUILD_BOOT_IMG flag is defined, the following flags that point to the
#     various components needed to build a boot.img also need to be defined.
#     - MKBOOTIMG_PATH=<path to the mkbootimg.py script which builds boot.img>
#     - GKI_RAMDISK_PREBUILT_BINARY=<Name of the GKI ramdisk prebuilt which includes
#       the generic ramdisk components like init and the non-device-specific rc files>
#     - VENDOR_RAMDISK_BINARY=<Name of the vendor ramdisk binary which includes the
#       device-specific components of ramdisk like the fstab file and the
#       device-specific rc files.>
#     - KERNEL_BINARY=<name of kernel binary, eg. Image.lz4, Image.gz etc>
#     - BOOT_IMAGE_HEADER_VERSION=<version of the boot image header>
#
#   BUILD_INITRAMFS
#     if defined, build a ramdisk containing all .ko files and resulting depmod artifacts
#
# Note: For historic reasons, internally, OUT_DIR will be copied into
# COMMON_OUT_DIR, and OUT_DIR will be then set to
# ${COMMON_OUT_DIR}/${KERNEL_DIR}. This has been done to accommodate existing
# build.config files that expect ${OUT_DIR} to point to the output directory of
# the kernel build.
#
# The kernel is built in ${COMMON_OUT_DIR}/${KERNEL_DIR}.
# Out-of-tree modules are built in ${COMMON_OUT_DIR}/${EXT_MOD} where
# ${EXT_MOD} is the path to the module source code.

set -e

# rel_path <to> <from>
# Generate relative directory path to reach directory <to> from <from>
function rel_path() {
	local to=$1
	local from=$2
	local path=
	local stem=
	local prevstem=
	[ -n "$to" ] || return 1
	[ -n "$from" ] || return 1
	to=$(readlink -e "$to")
	from=$(readlink -e "$from")
	[ -n "$to" ] || return 1
	[ -n "$from" ] || return 1
	stem=${from}/
	while [ "${to#$stem}" == "${to}" -a "${stem}" != "${prevstem}" ]; do
		prevstem=$stem
		stem=$(readlink -e "${stem}/..")
		[ "${stem%/}" == "${stem}" ] && stem=${stem}/
		path=${path}../
	done
	echo ${path}${to#$stem}
}

export ROOT_DIR=$(readlink -f $(dirname $0)/..)

# For module file Signing with the kernel (if needed)
FILE_SIGN_BIN=scripts/sign-file
SIGN_SEC=certs/signing_key.pem
SIGN_CERT=certs/signing_key.x509
SIGN_ALGO=sha512

# Save environment parameters before being overwritten by sourcing
# BUILD_CONFIG.
CC_ARG=${CC}

source "${ROOT_DIR}/build/_setup_env.sh"

export MAKE_ARGS=$*
export MAKEFLAGS="-j$(nproc) ${MAKEFLAGS}"
export MODULES_STAGING_DIR=$(readlink -m ${COMMON_OUT_DIR}/staging)
export MODULES_PRIVATE_DIR=$(readlink -m ${COMMON_OUT_DIR}/private)
export UNSTRIPPED_DIR=${DIST_DIR}/unstripped
export KERNEL_UAPI_HEADERS_DIR=$(readlink -m ${COMMON_OUT_DIR}/kernel_uapi_headers)
export INITRAMFS_STAGING_DIR=${MODULES_STAGING_DIR}/initramfs_staging

cd ${ROOT_DIR}

export CROSS_COMPILE CROSS_COMPILE_ARM32 CROSS_COMPILE_COMPAT ARCH SUBARCH

# Restore the previously saved CC argument that might have been overridden by
# the BUILD_CONFIG.
[ -n "${CC_ARG}" ] && CC=${CC_ARG}

# CC=gcc is effectively a fallback to the default gcc including any target
# triplets. An absolute path (e.g., CC=/usr/bin/gcc) must be specified to use a
# custom compiler.
[ "${CC}" == "gcc" ] && unset CC && unset CC_ARG

if [ -n "${CC}" ]; then
  CC_ARG="CC=${CC} HOSTCC=${CC}"
fi

if [ -n "${LD}" ]; then
  LD_ARG="LD=${LD}"
fi

CC_LD_ARG="${CC_ARG} ${LD_ARG}"

mkdir -p ${OUT_DIR}
echo "========================================================"
echo " Setting up for build"
if [ -z "${SKIP_MRPROPER}" ] ; then
  set -x
  (cd ${KERNEL_DIR} && make ${CC_LD_ARG} O=${OUT_DIR} ${MAKE_ARGS} mrproper)
  set +x
fi

if [ "${PRE_DEFCONFIG_CMDS}" != "" ]; then
  echo "========================================================"
  echo " Running pre-defconfig command(s):"
  set -x
  eval ${PRE_DEFCONFIG_CMDS}
  set +x
fi

if [ -z "${SKIP_DEFCONFIG}" ] ; then
set -x
(cd ${KERNEL_DIR} && make ${CC_LD_ARG} O=${OUT_DIR} ${MAKE_ARGS} ${DEFCONFIG})
set +x

if [ "${POST_DEFCONFIG_CMDS}" != "" ]; then
  echo "========================================================"
  echo " Running pre-make command(s):"
  set -x
  eval ${POST_DEFCONFIG_CMDS}
  set +x
fi
fi

echo "========================================================"
echo " Building kernel"

set -x
(cd ${OUT_DIR} && make O=${OUT_DIR} ${CC_LD_ARG} ${MAKE_ARGS})
set +x

if [ "${POST_KERNEL_BUILD_CMDS}" != "" ]; then
  echo "========================================================"
  echo " Running post-kernel-build command(s):"
  set -x
  eval ${POST_KERNEL_BUILD_CMDS}
  set +x
fi

rm -rf ${MODULES_STAGING_DIR}
mkdir -p ${MODULES_STAGING_DIR}

if [ -n "${BUILD_INITRAMFS}" -o  -n "${IN_KERNEL_MODULES}" ]; then
  echo "========================================================"
  echo " Installing kernel modules into staging directory"

  (cd ${OUT_DIR} &&                                                           \
   make O=${OUT_DIR} ${CC_LD_ARG} INSTALL_MOD_STRIP=1                         \
        INSTALL_MOD_PATH=${MODULES_STAGING_DIR} ${MAKE_ARGS} modules_install)
fi

if [[ -z "${SKIP_EXT_MODULES}" ]] && [[ "${EXT_MODULES}" != "" ]]; then
  echo "========================================================"
  echo " Building external modules and installing them into staging directory"

  for EXT_MOD in ${EXT_MODULES}; do
    # The path that we pass in via the variable M needs to be a relative path
    # relative to the kernel source directory. The source files will then be
    # looked for in ${KERNEL_DIR}/${EXT_MOD_REL} and the object files (i.e. .o
    # and .ko) files will be stored in ${OUT_DIR}/${EXT_MOD_REL}. If we
    # instead set M to an absolute path, then object (i.e. .o and .ko) files
    # are stored in the module source directory which is not what we want.
    EXT_MOD_REL=$(rel_path ${ROOT_DIR}/${EXT_MOD} ${KERNEL_DIR})
    # The output directory must exist before we invoke make. Otherwise, the
    # build system behaves horribly wrong.
    mkdir -p ${OUT_DIR}/${EXT_MOD_REL}
    set -x
    make -C ${EXT_MOD} M=${EXT_MOD_REL} KERNEL_SRC=${ROOT_DIR}/${KERNEL_DIR}  \
                       O=${OUT_DIR} ${CC_LD_ARG} ${MAKE_ARGS}
    make -C ${EXT_MOD} M=${EXT_MOD_REL} KERNEL_SRC=${ROOT_DIR}/${KERNEL_DIR}  \
                       O=${OUT_DIR} ${CC_LD_ARG} INSTALL_MOD_STRIP=1          \
                       INSTALL_MOD_PATH=${MODULES_STAGING_DIR}                \
                       ${MAKE_ARGS} modules_install
    set +x
  done

fi

if [ "${EXTRA_CMDS}" != "" ]; then
  echo "========================================================"
  echo " Running extra build command(s):"
  set -x
  eval ${EXTRA_CMDS}
  set +x
fi

OVERLAYS_OUT=""
for ODM_DIR in ${ODM_DIRS}; do
  OVERLAY_DIR=${ROOT_DIR}/device/${ODM_DIR}/overlays

  if [ -d ${OVERLAY_DIR} ]; then
    OVERLAY_OUT_DIR=${OUT_DIR}/overlays/${ODM_DIR}
    mkdir -p ${OVERLAY_OUT_DIR}
    make -C ${OVERLAY_DIR} DTC=${OUT_DIR}/scripts/dtc/dtc                     \
                           OUT_DIR=${OVERLAY_OUT_DIR} ${MAKE_ARGS}
    OVERLAYS=$(find ${OVERLAY_OUT_DIR} -name "*.dtbo")
    OVERLAYS_OUT="$OVERLAYS_OUT $OVERLAYS"
  fi
done

mkdir -p ${DIST_DIR}
echo "========================================================"
echo " Copying files"
for FILE in $(cd ${OUT_DIR} && ls -1 ${FILES}); do
  if [ -f ${OUT_DIR}/${FILE} ]; then
    echo "  $FILE"
    cp -p ${OUT_DIR}/${FILE} ${DIST_DIR}/
  else
    echo "  $FILE is not a file, skipping"
  fi
done

for FILE in ${OVERLAYS_OUT}; do
  OVERLAY_DIST_DIR=${DIST_DIR}/$(dirname ${FILE#${OUT_DIR}/overlays/})
  echo "  ${FILE#${OUT_DIR}/}"
  mkdir -p ${OVERLAY_DIST_DIR}
  cp ${FILE} ${OVERLAY_DIST_DIR}/
done

MODULES=$(find ${MODULES_STAGING_DIR} -type f -name "*.ko")
if [ -n "${MODULES}" ]; then
  if [ -n "${IN_KERNEL_MODULES}" -o "${EXT_MODULES}" != "" ]; then
    echo "========================================================"
    echo " Copying modules files"
    for FILE in ${MODULES}; do
      echo "  ${FILE#${MODULES_STAGING_DIR}/}"
      cp -p ${FILE} ${DIST_DIR}
    done
  fi
  if [ -n "${BUILD_INITRAMFS}" ]; then
    echo "========================================================"
    echo " Creating initramfs"
    set -x
    rm -rf ${INITRAMFS_STAGING_DIR}
    mkdir -p ${INITRAMFS_STAGING_DIR}/lib/modules/kernel/
    cp -r ${MODULES_STAGING_DIR}/lib/modules/*/kernel/* ${INITRAMFS_STAGING_DIR}/lib/modules/kernel/
    cp ${MODULES_STAGING_DIR}/lib/modules/*/modules.* ${INITRAMFS_STAGING_DIR}/lib/modules/
    cp ${MODULES_STAGING_DIR}/lib/modules/*/modules.order ${INITRAMFS_STAGING_DIR}/lib/modules/modules.load

    (cd ${INITRAMFS_STAGING_DIR} && find . | cpio -H newc -o > ${MODULES_STAGING_DIR}/initramfs.cpio)
    gzip -f ${MODULES_STAGING_DIR}/initramfs.cpio
    mv ${MODULES_STAGING_DIR}/initramfs.cpio.gz ${DIST_DIR}/initramfs.img
    set +x
  fi
fi

if [ "${UNSTRIPPED_MODULES}" != "" ]; then
  echo "========================================================"
  echo " Copying unstripped module files for debugging purposes (not loaded on device)"
  mkdir -p ${UNSTRIPPED_DIR}
  for MODULE in ${UNSTRIPPED_MODULES}; do
    find ${MODULES_PRIVATE_DIR} -name ${MODULE} -exec cp {} ${UNSTRIPPED_DIR} \;
  done
fi

if [ -z "${SKIP_CP_KERNEL_HDR}" ]; then
  echo "========================================================"
  echo " Installing UAPI kernel headers:"
  mkdir -p "${KERNEL_UAPI_HEADERS_DIR}/usr"
  make -C ${OUT_DIR} O=${OUT_DIR} ${CC_LD_ARG}                                \
          INSTALL_HDR_PATH="${KERNEL_UAPI_HEADERS_DIR}/usr" ${MAKE_ARGS}      \
          headers_install
  # The kernel makefiles create files named ..install.cmd and .install which
  # are only side products. We don't want those. Let's delete them.
  find ${KERNEL_UAPI_HEADERS_DIR} \( -name ..install.cmd -o -name .install \) -exec rm '{}' +
  KERNEL_UAPI_HEADERS_TAR=${DIST_DIR}/kernel-uapi-headers.tar.gz
  echo " Copying kernel UAPI headers to ${KERNEL_UAPI_HEADERS_TAR}"
  tar -czf ${KERNEL_UAPI_HEADERS_TAR} --directory=${KERNEL_UAPI_HEADERS_DIR} usr/
fi

if [ -z "${SKIP_CP_KERNEL_HDR}" ] ; then
  echo "========================================================"
  KERNEL_HEADERS_TAR=${DIST_DIR}/kernel-headers.tar.gz
  echo " Copying kernel headers to ${KERNEL_HEADERS_TAR}"
  pushd $ROOT_DIR/$KERNEL_DIR
    find arch include $OUT_DIR -name *.h -print0               \
            | tar -czf $KERNEL_HEADERS_TAR                     \
              --absolute-names                                 \
              --dereference                                    \
              --transform "s,.*$OUT_DIR,,"                     \
              --transform "s,^,kernel-headers/,"               \
              --null -T -
  popd
fi

# Copy the abi_${arch}.xml file from the sources into the dist dir
if [ -n "${ABI_DEFINITION}" ]; then
  echo "========================================================"
  echo " Copying abi definition to ${DIST_DIR}/abi.xml"
  pushd $ROOT_DIR/$KERNEL_DIR
    cp "${ABI_DEFINITION}" ${DIST_DIR}/abi.xml
  popd
fi

echo "========================================================"
echo " Files copied to ${DIST_DIR}"

if [ ! -z "${BUILD_BOOT_IMG}" ] ; then

	DTB_FILE_LIST=$(find ${DIST_DIR} -name "*.dtb")
	if [ -z "${DTB_FILE_LIST}" ]; then
		echo "No *.dtb files found in ${DIST_DIR}"
		exit 1
	fi
	cat $DTB_FILE_LIST > ${DIST_DIR}/dtb.img

	if [ ! -f "${DIST_DIR}/$GKI_RAMDISK_PREBUILT_BINARY" ]; then
		echo "GKI ramdisk prebuilt binary" \
			"(GKI_RAMDISK_PREBUILT_BINARY = $GKI_RAMDISK_PREBUILT_BINARY)" \
			"not present in ${DIST_DIR}"
		exit 1
	fi
	if [ ! -f "${DIST_DIR}/$VENDOR_RAMDISK_BINARY" ]; then
		echo "vendor ramdisk binary(VENDOR_RAMDISK_BINARY = $VENDOR_RAMDISK_BINARY)" \
			"not present in ${DIST_DIR}"
		exit 1
	fi

	cat ${DIST_DIR}/$GKI_RAMDISK_PREBUILT_BINARY ${DIST_DIR}/$VENDOR_RAMDISK_BINARY \
		> ${DIST_DIR}/ramdisk.cpio
	gzip -f ${DIST_DIR}/ramdisk.cpio > ${DIST_DIR}/ramdisk

	if [ ! -x "$MKBOOTIMG_PATH" ]; then
		echo "mkbootimg.py script not found or not executable. MKBOOTIMG_PATH = $MKBOOTIMG_PATH"
		exit 1
	fi

	if [ ! -f "${DIST_DIR}/$KERNEL_BINARY" ]; then
		echo "kernel binary(KERNEL_BINARY = $KERNEL_BINARY) not present in ${DIST_DIR}"
		exit 1
	fi

	if [ -z "${BOOT_IMAGE_HEADER_VERSION}" ]; then
		echo "BOOT_IMAGE_HEADER_VERSION must specify the boot image header version"
		exit 1
	fi

	(set -x; $MKBOOTIMG_PATH --kernel ${DIST_DIR}/$KERNEL_BINARY \
		--ramdisk ${DIST_DIR}/ramdisk \
		--dtb ${DIST_DIR}/dtb.img --header_version $BOOT_IMAGE_HEADER_VERSION \
		-o ${DIST_DIR}/boot.img
	)
	set +x
	echo "boot image created at ${DIST_DIR}/boot.img"
fi


# No trace_printk use on build server build
if readelf -a ${DIST_DIR}/vmlinux 2>&1 | grep -q trace_printk_fmt; then
  echo "========================================================"
  echo "WARN: Found trace_printk usage in vmlinux."
  echo ""
  echo "trace_printk will cause trace_printk_init_buffers executed in kernel"
  echo "start, which will increase memory and lead warning shown during boot."
  echo "We should not carry trace_printk in production kernel."
  echo ""
  if [ ! -z "${STOP_SHIP_TRACEPRINTK}" ]; then
    echo "ERROR: stop ship on trace_printk usage." 1>&2
    exit 1
  fi
fi
