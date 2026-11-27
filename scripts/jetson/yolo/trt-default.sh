# shellcheck shell=bash disable=SC2034  # sets variables for the scripts that source it
# Sourced by setup-yolo.sh and profile-yolo.sh: the TensorRT programs get by
# default, and what building for it takes. With nano-trt82 installed
# (package-trt82.sh, install-trt82.sh) that is JetPack 4's TensorRT 8.2, whose
# libraries come first in the library path; otherwise JetPack 5's 8.5.
#
# trt_default sets TRT_VERSION (8201 or 8502, as getInferLibVersion gives it),
# TRT_NAME (8.2.1 or 8.5.2), TRTEXEC, CUDART (the CUDA runtime's SONAME),
# TRT_URL and HEADERS (TensorRT's headers that NvInferRuntime.h reads, at that
# release, from github.com/NVIDIA/TensorRT, Apache-2.0, with their SHA-256),
# or prints why not and returns 1.
# workspace_flag MIB prints trtexec's option for its workspace (8.2 has
# --workspace, 8.5 --memPoolSize).

trt_default() {
    # The library path as programs get it, whatever this shell's LD_LIBRARY_PATH.
    TRT_VERSION=$(env -u LD_LIBRARY_PATH python3 -I -c \
        'import ctypes; print(ctypes.CDLL("libnvinfer.so.8").getInferLibVersion())' 2> /dev/null)
    case $TRT_VERSION in
        8201)
            TRT_NAME=8.2.1
            TRTEXEC=/usr/lib/aarch64-linux-gnu/nano-trt82/bin/trtexec
            CUDART=libcudart.so.10.2
            TRT_URL=https://raw.githubusercontent.com/NVIDIA/TensorRT/6f38570b74066ef464744bc789f8512191f1cbc0/include
            HEADERS=(
                8882e5224424a336b546d3d53d192c4f9bb3d1cd297a07014fa77e16002c4383:NvInferRuntime.h
                9bce40c59b3236fe44ec10d2152e95f4d88dcc7c51f46bb646515901fb58a2d7:NvInferImpl.h
                d5415ce5902eb657cdd17ec1dbe707ede333e0829942ccf6e4ed82968d760ccf:NvInferRuntimeCommon.h
                3ec3cd66689a74d34049456976c270f0e4d86a319f8d682201ce454cc910ede8:NvInferVersion.h
                856cd6fa36bc855dfda61a06bc0fca82dc16d54b49bc844fee244f731aadf6f6:NvInferLegacyDims.h
            )
            ;;
        8502)
            TRT_NAME=8.5.2
            TRTEXEC=/usr/src/tensorrt/bin/trtexec
            CUDART=libcudart.so.11.0
            TRT_URL=https://raw.githubusercontent.com/NVIDIA/TensorRT/ad932f72126f875392a4336d9ee45b2756d934a0/include
            HEADERS=(
                2cb5db33c4e101a342a58ee018f65e63a35c910fe9bee4d7de5c2653ef42e8cc:NvInferRuntime.h
                a9b22093ddadfc9e32696b5ad54285d3deb8186a170961cfea762cf7d221f1c4:NvInferImpl.h
                b8547e885379905b965bc1859d6b1e16504c9bca68daa1a79cc6053a4fc93b9d:NvInferRuntimeCommon.h
                f828e8cb5bd80a99637c67c6145b385632392b8797a7ce7f3beab600c895d306:NvInferVersion.h
                608531417b5d1e652f61449a9116c69c7d66399987615b37d4614738ef9df865:NvInferLegacyDims.h
            )
            ;;
        *)
            printf 'no TensorRT 8.2.1 or 8.5.2 by default (libnvinfer.so.8 reports %s)\n' "${TRT_VERSION:-nothing}"
            return 1
            ;;
    esac
}

workspace_flag() {
    if "$TRTEXEC" --help 2>&1 | grep -q -- --memPoolSize; then
        printf -- '--memPoolSize=workspace:%s\n' "$1"
    else
        printf -- '--workspace=%s\n' "$1"
    fi
}
