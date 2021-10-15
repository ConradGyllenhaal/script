#!/bin/bash

set -o pipefail

source "$(dirname ${BASH_SOURCE[0]})/common.sh"

[[ $# -eq 1 ]] || user_error "expected a single argument (device type)"
[[ -n $BUILD_NUMBER ]] || user_error "expected BUILD_NUMBER in the environment"

chrt -b -p 0 $$

PERSISTENT_KEY_DIR=keys/$1
RELEASE_OUT=out/release-$1-$BUILD_NUMBER

# decrypt keys in advance for improved performance and modern algorithm support
KEY_DIR=$(mktemp -d /dev/shm/release_keys.XXXXXXXXXX) || exit 1
trap "rm -rf \"$KEY_DIR\"" EXIT
cp "$PERSISTENT_KEY_DIR"/* "$KEY_DIR" || exit 1
script/decrypt_keys.sh "$KEY_DIR" || exit 1

OLD_PATH="$PATH"
export PATH="$PWD/prebuilts/build-tools/linux-x86/bin:$PATH"
export PATH="$PWD/prebuilts/build-tools/path/linux-x86:$PATH"

rm -rf $RELEASE_OUT || exit 1
mkdir -p $RELEASE_OUT || exit 1
unzip $OUT/otatools.zip -d $RELEASE_OUT/otatools || exit 1

export PATH="$RELEASE_OUT/otatools/bin:$PATH"

source $RELEASE_OUT/otatools/device/common/clear-factory-images-variables.sh || exit 1

get_radio_image() {
    grep "require version-$1" vendor/$2/vendor-board-info.txt | cut -d '=' -f 2 | tr '[:upper:]' '[:lower:]' || exit 1
}

if [[ $1 == crosshatch || $1 == blueline || $1 == bonito || $1 == sargo || $1 == coral || $1 == flame || $1 == sunfish || $1 == bramble || $1 == redfin || $1 == barbet ]]; then
    BOOTLOADER=$(get_radio_image bootloader google_devices/$1)
    RADIO=$(get_radio_image baseband google_devices/$1)
    DISABLE_UART=true
else
    user_error "$1 is not supported by the release script"
fi

BUILD=$BUILD_NUMBER
VERSION=$BUILD_NUMBER
DEVICE=$1
PRODUCT=$1

TARGET_FILES=$DEVICE-target_files-$BUILD.zip

AVB_PKMD="$KEY_DIR/avb_pkmd.bin"
AVB_ALGORITHM=SHA256_RSA4096
[[ $(stat -c %s "$KEY_DIR/avb_pkmd.bin") -eq 520 ]] && AVB_ALGORITHM=SHA256_RSA2048

if [[ $DEVICE == blueline || $DEVICE == crosshatch || $1 == bonito || $1 == sargo ]]; then
    EXTRA_OTA=(--retrofit_dynamic_partitions)
fi

sign_target_files_apks -o -d "$KEY_DIR" --avb_vbmeta_key "$KEY_DIR/avb.pem" --avb_vbmeta_algorithm $AVB_ALGORITHM \
    --extra_apks OsuLogin.apk,ServiceConnectivityResources.apk,ServiceWifiResources.apk="$KEY_DIR/releasekey" \
    "$OUT/obj/PACKAGING/target_files_intermediates/$TARGET_FILES" \
    $RELEASE_OUT/$TARGET_FILES || exit 1

ota_from_target_files -k "$KEY_DIR/releasekey" \
    "${EXTRA_OTA[@]}" $RELEASE_OUT/$TARGET_FILES \
    $RELEASE_OUT/$DEVICE-ota_update-$BUILD.zip || exit 1
script/generate_metadata.py $RELEASE_OUT/$DEVICE-ota_update-$BUILD.zip || exit 1

img_from_target_files $RELEASE_OUT/$TARGET_FILES \
    $RELEASE_OUT/$DEVICE-img-$BUILD.zip || exit 1

cd $RELEASE_OUT || exit 1

source otatools/device/common/generate-factory-images-common.sh || exit 1

if [[ -f "$KEY_DIR/factory.sec" ]]; then
    export PATH="$OLD_PATH"
    ../../script/signify_prehash.sh "$KEY_DIR/factory.sec" $DEVICE-factory-$BUILD_NUMBER.zip || exit 1
fi
