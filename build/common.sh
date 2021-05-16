#!/usr/bin/env bash

# Copyright 2014 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# shellcheck disable=SC2034 # Variables sourced in other scripts.

# Common utilities, variables and checks for all build scripts.
set -o errexit
set -o nounset
set -o pipefail

# Unset CDPATH, having it set messes up with script import paths
unset CDPATH

USER_ID=$(id -u)
GROUP_ID=$(id -g)

DOCKER_OPTS=${DOCKER_OPTS:-""}
IFS=" " read -r -a DOCKER <<<"docker ${DOCKER_OPTS}"
DOCKER_HOST=${DOCKER_HOST:-""}

# This will canonicalize the path
KUBE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd -P)

source "${KUBE_ROOT}/hack/lib/init.sh"

# Constants

readonly KUBE_BUILD_IMAGE_REPO=kube-build

# KUBE_BUILD_IMAGE_CROSS_TAG 表示 要拉取 的基本镜像的 tag 名： v1.16.1-1
readonly KUBE_BUILD_IMAGE_CROSS_TAG="$(cat "${KUBE_ROOT}/build/build-image/cross/VERSION")"

readonly KUBE_DOCKER_REGISTRY="${KUBE_DOCKER_REGISTRY:-k8s.gcr.io}"
readonly KUBE_BASE_IMAGE_REGISTRY="${KUBE_BASE_IMAGE_REGISTRY:-k8s.gcr.io/build-image}"

# This version number is used to cause everyone to rebuild their data containers
# and build image.  This is especially useful for automated build systems like
# Jenkins.
#
# Increment/change this number if you change the build image (anything under
# build/build-image) or change the set of volumes in the data container.
# image 的版本号，我这里是 5 ，KUBE_BUILD_IMAGE_VERSION 为 5-v1.16.1-1
readonly KUBE_BUILD_IMAGE_VERSION_BASE="$(cat "${KUBE_ROOT}/build/build-image/VERSION")"
readonly KUBE_BUILD_IMAGE_VERSION="${KUBE_BUILD_IMAGE_VERSION_BASE}-${KUBE_BUILD_IMAGE_CROSS_TAG}"

# Here we map the output directories across both the local and remote _output
# directories:
#
# *_OUTPUT_ROOT    - the base of all output in that environment.
# *_OUTPUT_SUBPATH - location where golang stuff is built/cached.  Also
#                    persisted across docker runs with a volume mount.
# *_OUTPUT_BINPATH - location where final binaries are placed.  If the remote
#                    is really remote, this is the stuff that has to be copied
#                    back.
# OUT_DIR can come in from the Makefile, so honor it.
readonly LOCAL_OUTPUT_ROOT="${KUBE_ROOT}/${OUT_DIR:-_output}"
readonly LOCAL_OUTPUT_SUBPATH="${LOCAL_OUTPUT_ROOT}/dockerized"
readonly LOCAL_OUTPUT_BINPATH="${LOCAL_OUTPUT_SUBPATH}/bin"
readonly LOCAL_OUTPUT_GOPATH="${LOCAL_OUTPUT_SUBPATH}/go"
readonly LOCAL_OUTPUT_IMAGE_STAGING="${LOCAL_OUTPUT_ROOT}/images"

# This is a symlink to binaries for "this platform" (e.g. build tools).
readonly THIS_PLATFORM_BIN="${LOCAL_OUTPUT_ROOT}/bin"

readonly REMOTE_ROOT="/go/src/${KUBE_GO_PACKAGE}"
readonly REMOTE_OUTPUT_ROOT="${REMOTE_ROOT}/_output"
readonly REMOTE_OUTPUT_SUBPATH="${REMOTE_OUTPUT_ROOT}/dockerized"
readonly REMOTE_OUTPUT_BINPATH="${REMOTE_OUTPUT_SUBPATH}/bin"
readonly REMOTE_OUTPUT_GOPATH="${REMOTE_OUTPUT_SUBPATH}/go"

# This is the port on the workstation host to expose RSYNC on.  Set this if you
# are doing something fancy with ssh tunneling.
readonly KUBE_RSYNC_PORT="${KUBE_RSYNC_PORT:-}"

# This is the port that rsync is running on *inside* the container. This may be
# mapped to KUBE_RSYNC_PORT via docker networking.
readonly KUBE_CONTAINER_RSYNC_PORT=8730

# These are the default versions (image tags) for their respective base images.
readonly __default_debian_iptables_version=buster-v1.5.0
readonly __default_go_runner_version=v2.3.1-go1.16.1-buster.0

# These are the base images for the Docker-wrapped binaries.
readonly KUBE_GORUNNER_IMAGE="${KUBE_GORUNNER_IMAGE:-$KUBE_BASE_IMAGE_REGISTRY/go-runner:$__default_go_runner_version}"
readonly KUBE_APISERVER_BASE_IMAGE="${KUBE_APISERVER_BASE_IMAGE:-$KUBE_GORUNNER_IMAGE}"
readonly KUBE_CONTROLLER_MANAGER_BASE_IMAGE="${KUBE_CONTROLLER_MANAGER_BASE_IMAGE:-$KUBE_GORUNNER_IMAGE}"
readonly KUBE_SCHEDULER_BASE_IMAGE="${KUBE_SCHEDULER_BASE_IMAGE:-$KUBE_GORUNNER_IMAGE}"
readonly KUBE_PROXY_BASE_IMAGE="${KUBE_PROXY_BASE_IMAGE:-$KUBE_BASE_IMAGE_REGISTRY/debian-iptables:$__default_debian_iptables_version}"

# This is the image used in a multi-stage build to apply capabilities to Docker-wrapped binaries.
readonly KUBE_BUILD_SETCAP_IMAGE="${KUBE_BUILD_SETCAP_IMAGE:-$KUBE_BASE_IMAGE_REGISTRY/setcap:buster-v1.4.0}"

# Get the set of master binaries that run in Docker (on Linux)
# Entry format is "<binary-name>,<base-image>".
# Binaries are placed in /usr/local/bin inside the image.
# `make` users can override any or all of the base images using the associated
# environment variables.
#
# $1 - server architecture
kube::build::get_docker_wrapped_binaries() {
  ### If you change any of these lists, please also update DOCKERIZED_BINARIES
  ### in build/BUILD. And kube::golang::server_image_targets
  local targets=(
    "kube-apiserver,${KUBE_APISERVER_BASE_IMAGE}"
    "kube-controller-manager,${KUBE_CONTROLLER_MANAGER_BASE_IMAGE}"
    "kube-scheduler,${KUBE_SCHEDULER_BASE_IMAGE}"
    "kube-proxy,${KUBE_PROXY_BASE_IMAGE}"
  )

  echo "${targets[@]}"
}

# ---------------------------------------------------------------------------
# Basic setup functions

# Verify that the right utilities and such are installed for building Kube. Set
# up some dynamic constants.
# Args:
#   $1 - boolean of whether to require functioning docker (default true)
#
# Vars set:
#   KUBE_ROOT_HASH
#   KUBE_BUILD_IMAGE_TAG_BASE
#   KUBE_BUILD_IMAGE_TAG
#   KUBE_BUILD_IMAGE
#   KUBE_BUILD_CONTAINER_NAME_BASE
#   KUBE_BUILD_CONTAINER_NAME
#   KUBE_DATA_CONTAINER_NAME_BASE
#   KUBE_DATA_CONTAINER_NAME
#   KUBE_RSYNC_CONTAINER_NAME_BASE
#   KUBE_RSYNC_CONTAINER_NAME
#   DOCKER_MOUNT_ARGS
#   LOCAL_OUTPUT_BUILD_CONTEXT

# 验证是否安装了 docker 环境
# 传入参数：是否 要求 有docker环境，默认 true
function kube::build::verify_prereqs() {
  local -r require_docker=${1:-true}
  kube::log::status "Verifying Prerequisites...."

  # 确认 tar 命令
  kube::build::ensure_tar || return 1
  # 确认 rsync 命令
  kube::build::ensure_rsync || return 1
  # 如果必须要有 docker 运行环境
  if ${require_docker}; then
    # 确认 docker 环境
    kube::build::ensure_docker_in_path || return 1
    # 如果是 Darwin 系统
    if kube::build::is_osx; then
      # 检查 docker.sock
      kube::build::docker_available_on_osx || return 1
    fi
    # 检查 是否可以运行 docker 命令
    kube::util::ensure_docker_daemon_connectivity || return 1
    # 打印 docker Version 信息
    if ((KUBE_VERBOSE > 6)); then
      kube::log::status "Docker Version:"
      "${DOCKER[@]}" version | kube::log::info_from_stdin
    fi
  fi

  # 当前的 git 分支
  KUBE_GIT_BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
  # 用 md5 命令 求 hash 值
  KUBE_ROOT_HASH=$(kube::build::short_hash "${HOSTNAME:-}:${KUBE_ROOT}:${KUBE_GIT_BRANCH}")
  # build 出 image 的 tag前缀 为 build-Hash值
  KUBE_BUILD_IMAGE_TAG_BASE="build-${KUBE_ROOT_HASH}"
  # KUBE_BUILD_IMAGE_VERSION 为 5-v1.16.1-1
  # build 出 image 的 整个 tag
  KUBE_BUILD_IMAGE_TAG="${KUBE_BUILD_IMAGE_TAG_BASE}-${KUBE_BUILD_IMAGE_VERSION}"
  # 需要拉取的镜像名称：kube-build:build-HASH-5-v1.16.1-1
  KUBE_BUILD_IMAGE="${KUBE_BUILD_IMAGE_REPO}:${KUBE_BUILD_IMAGE_TAG}"
  # 这里一共需要 三个容器来进行构建工作：
  # 1. BUILD 容器，构建容器
  # 2. RSYNC 容器，同步数据容器
  # 3. DATA 容器，存储容器
  # build container Name : kube-build-HASH-5-v1.16.1-1
  KUBE_BUILD_CONTAINER_NAME_BASE="kube-build-${KUBE_ROOT_HASH}"
  KUBE_BUILD_CONTAINER_NAME="${KUBE_BUILD_CONTAINER_NAME_BASE}-${KUBE_BUILD_IMAGE_VERSION}"
  # RSYNC container NAME: kube-rsync-build-HASH-5-v1.16.1-1
  KUBE_RSYNC_CONTAINER_NAME_BASE="kube-rsync-${KUBE_ROOT_HASH}"
  KUBE_RSYNC_CONTAINER_NAME="${KUBE_RSYNC_CONTAINER_NAME_BASE}-${KUBE_BUILD_IMAGE_VERSION}"
  # DATA container Name: kube-build-data-build-HASH-5-v1.16.1-1
  KUBE_DATA_CONTAINER_NAME_BASE="kube-build-data-${KUBE_ROOT_HASH}"
  KUBE_DATA_CONTAINER_NAME="${KUBE_DATA_CONTAINER_NAME_BASE}-${KUBE_BUILD_IMAGE_VERSION}"
  # DATA 容器挂载目录的路径
  DOCKER_MOUNT_ARGS=(--volumes-from "${KUBE_DATA_CONTAINER_NAME}")
  # 这个是 编译 image 的路径，也就是 Dockerfile 的所在的目录，目录为：_output/images/kube-build:build-HASH-5-v1.16.1-1/
  LOCAL_OUTPUT_BUILD_CONTEXT="${LOCAL_OUTPUT_IMAGE_STAGING}/${KUBE_BUILD_IMAGE}"

  # 设置 git 相关的环境变量
  kube::version::get_version_vars
  # 将环境变量 保存在 指定的文件中
  kube::version::save_version_vars "${KUBE_ROOT}/.dockerized-kube-version-defs"

  # Without this, the user's umask can leak through.
  umask 0022
}

# ---------------------------------------------------------------------------
# Utility functions

function kube::build::docker_available_on_osx() {
  if [[ -z "${DOCKER_HOST}" ]]; then
    if [[ -S "/var/run/docker.sock" ]]; then
      kube::log::status "Using Docker for MacOS"
      return 0
    fi

    kube::log::status "No docker host is set."
    kube::log::status "It looks like you're running Mac OS X, but Docker for Mac cannot be found."
    kube::log::status "See: https://docs.docker.com/engine/installation/mac/ for installation instructions."
    return 1
  fi
}

function kube::build::is_osx() {
  [[ "$(uname)" == "Darwin" ]]
}

function kube::build::is_gnu_sed() {
  [[ $(sed --version 2>&1) == *GNU* ]]
}

function kube::build::ensure_rsync() {
  if [[ -z "$(which rsync)" ]]; then
    kube::log::error "Can't find 'rsync' in PATH, please fix and retry."
    return 1
  fi
}

function kube::build::ensure_docker_in_path() {
  if [[ -z "$(which docker)" ]]; then
    kube::log::error "Can't find 'docker' in PATH, please fix and retry."
    kube::log::error "See https://docs.docker.com/installation/#installation for installation instructions."
    return 1
  fi
}

function kube::build::ensure_tar() {
  if [[ -n "${TAR:-}" ]]; then
    return
  fi

  # Find gnu tar if it is available, bomb out if not.
  TAR=tar
  if which gtar &>/dev/null; then
    TAR=gtar
  else
    if which gnutar &>/dev/null; then
      TAR=gnutar
    fi
  fi
  if ! "${TAR}" --version | grep -q GNU; then
    echo "  !!! Cannot find GNU tar. Build on Linux or install GNU tar"
    echo "      on Mac OS X (brew install gnu-tar)."
    return 1
  fi
}

function kube::build::has_docker() {
  which docker &>/dev/null
}

function kube::build::has_ip() {
  which ip &>/dev/null && ip -Version | grep 'iproute2' &>/dev/null
}

# Detect if a specific image exists
#
# $1 - image repo name
# $2 - image tag
function kube::build::docker_image_exists() {
  [[ -n $1 && -n $2 ]] || {
    kube::log::error "Internal error. Image not specified in docker_image_exists."
    exit 2
  }

  [[ $("${DOCKER[@]}" images -q "${1}:${2}") ]]
}

# Delete all images that match a tag prefix except for the "current" version
#
# $1: The image repo/name
# $2: The tag base. We consider any image that matches $2*
# $3: The current image not to delete if provided
function kube::build::docker_delete_old_images() {
  # In Docker 1.12, we can replace this with
  #    docker images "$1" --format "{{.Tag}}"
  for tag in $("${DOCKER[@]}" images "${1}" | tail -n +2 | awk '{print $2}'); do
    if [[ "${tag}" != "${2}"* ]]; then
      V=3 kube::log::status "Keeping image ${1}:${tag}"
      continue
    fi

    if [[ -z "${3:-}" || "${tag}" != "${3}" ]]; then
      V=2 kube::log::status "Deleting image ${1}:${tag}"
      "${DOCKER[@]}" rmi "${1}:${tag}" >/dev/null
    else
      V=3 kube::log::status "Keeping image ${1}:${tag}"
    fi
  done
}

# Stop and delete all containers that match a pattern
#
# $1: The base container prefix
# $2: The current container to keep, if provided
function kube::build::docker_delete_old_containers() {
  # In Docker 1.12 we can replace this line with
  #   docker ps -a --format="{{.Names}}"
  for container in $("${DOCKER[@]}" ps -a | tail -n +2 | awk '{print $NF}'); do
    if [[ "${container}" != "${1}"* ]]; then
      V=3 kube::log::status "Keeping container ${container}"
      continue
    fi
    if [[ -z "${2:-}" || "${container}" != "${2}" ]]; then
      V=2 kube::log::status "Deleting container ${container}"
      kube::build::destroy_container "${container}"
    else
      V=3 kube::log::status "Keeping container ${container}"
    fi
  done
}

# Takes $1 and computes a short has for it. Useful for unique tag generation
function kube::build::short_hash() {
  [[ $# -eq 1 ]] || {
    kube::log::error "Internal error.  No data based to short_hash."
    exit 2
  }

  local short_hash
  if which md5 >/dev/null 2>&1; then
    short_hash=$(md5 -q -s "$1")
  else
    short_hash=$(echo -n "$1" | md5sum)
  fi
  echo "${short_hash:0:10}"
}

# Pedantically kill, wait-on and remove a container. The -f -v options
# to rm don't actually seem to get the job done, so force kill the
# container, wait to ensure it's stopped, then try the remove. This is
# a workaround for bug https://github.com/docker/docker/issues/3968.
function kube::build::destroy_container() {
  "${DOCKER[@]}" kill "$1" >/dev/null 2>&1 || true
  if [[ $("${DOCKER[@]}" version --format '{{.Server.Version}}') == 17.06.0* ]]; then
    # Workaround https://github.com/moby/moby/issues/33948.
    # TODO: remove when 17.06.0 is not relevant anymore
    DOCKER_API_VERSION=v1.29 "${DOCKER[@]}" wait "$1" >/dev/null 2>&1 || true
  else
    "${DOCKER[@]}" wait "$1" >/dev/null 2>&1 || true
  fi
  "${DOCKER[@]}" rm -f -v "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Building

function kube::build::clean() {
  if kube::build::has_docker; then
    kube::build::docker_delete_old_containers "${KUBE_BUILD_CONTAINER_NAME_BASE}"
    kube::build::docker_delete_old_containers "${KUBE_RSYNC_CONTAINER_NAME_BASE}"
    kube::build::docker_delete_old_containers "${KUBE_DATA_CONTAINER_NAME_BASE}"
    kube::build::docker_delete_old_images "${KUBE_BUILD_IMAGE_REPO}" "${KUBE_BUILD_IMAGE_TAG_BASE}"

    V=2 kube::log::status "Cleaning all untagged docker images"
    "${DOCKER[@]}" rmi "$("${DOCKER[@]}" images -q --filter 'dangling=true')" 2>/dev/null || true
  fi

  if [[ -d "${LOCAL_OUTPUT_ROOT}" ]]; then
    kube::log::status "Removing _output directory"
    rm -rf "${LOCAL_OUTPUT_ROOT}"
  fi
}

# Set up the context directory for the kube-build image and build it.
function kube::build::build_image() {
  # 创建 编译容器 的 Dockerfile 的目录, 目录为： _output/images/kube-build:build-HASH-5-v1.16.1-1
  mkdir -p "${LOCAL_OUTPUT_BUILD_CONTEXT}"
  # Make sure the context directory owned by the right user for syncing sources to container.
  # 修改 Dockerfile 所在的目录 的 属主和属组
  chown -R "${USER_ID}":"${GROUP_ID}" "${LOCAL_OUTPUT_BUILD_CONTEXT}"

  # 将 时区文件 拷贝到 该目录中
  cp /etc/localtime "${LOCAL_OUTPUT_BUILD_CONTEXT}/"
  chmod u+w "${LOCAL_OUTPUT_BUILD_CONTEXT}/localtime"

  # 拷贝 build/build-image/Dockerfile 文件 和 build/build-image/rsyncd.sh 脚本
  cp "${KUBE_ROOT}/build/build-image/Dockerfile" "${LOCAL_OUTPUT_BUILD_CONTEXT}/Dockerfile"
  cp "${KUBE_ROOT}/build/build-image/rsyncd.sh" "${LOCAL_OUTPUT_BUILD_CONTEXT}/"
  # dd 可从标准输入或文件中读取数据，根据指定的格式来转换数据，再输出到文件、设备或标准输出。
  # 参数：if=文件名：输入文件名； of=文件名：输出文件名 ；bs=bytes：同时设置读入/输出的块大小为bytes个字节 ； count=blocks：仅拷贝blocks个块，块大小等于ibs指定的字节数。
  # 生成随机的密码
  dd if=/dev/urandom bs=512 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | dd bs=32 count=1 2>/dev/null >"${LOCAL_OUTPUT_BUILD_CONTEXT}/rsyncd.password"
  chmod go= "${LOCAL_OUTPUT_BUILD_CONTEXT}/rsyncd.password"

  # 使用 docker 命令 build image
  # 第一个参数：需要 build 的 image 名称
  # 第二个参数：Dockerfile 所在的目录
  # 第三个参数：-pull 参数，默认 true，表示是否下载最新的版本
  # 第四个参数：--build-args 参数，表示build时的环境变量
  # kube::build::docker_build 这个函数就是执行一个 docker build 命令
  # 完整的 docker build 命令为：docker build -t "${image}" "--pull=${pull}" "${build_args[@]}" "${context_dir}"
  kube::build::docker_build "${KUBE_BUILD_IMAGE}" "${LOCAL_OUTPUT_BUILD_CONTEXT}" 'false' "--build-arg=KUBE_BUILD_IMAGE_CROSS_TAG=${KUBE_BUILD_IMAGE_CROSS_TAG} --build-arg=KUBE_BASE_IMAGE_REGISTRY=${KUBE_BASE_IMAGE_REGISTRY}"

  # Clean up old versions of everything
  # 清除  所有满足正则 的 container
  # 第一个参数，要清除的 container 名称的前缀
  # 第二个参数，要保留的 container 名称
  # 这里主要是清除 之前 编译构建的 BUILD、RSYNC、DATA cantainer
  kube::build::docker_delete_old_containers "${KUBE_BUILD_CONTAINER_NAME_BASE}" "${KUBE_BUILD_CONTAINER_NAME}"
  kube::build::docker_delete_old_containers "${KUBE_RSYNC_CONTAINER_NAME_BASE}" "${KUBE_RSYNC_CONTAINER_NAME}"
  kube::build::docker_delete_old_containers "${KUBE_DATA_CONTAINER_NAME_BASE}" "${KUBE_DATA_CONTAINER_NAME}"

  # 删除所有与标签前缀匹配的 image（“当前”版本除外）
  kube::build::docker_delete_old_images "${KUBE_BUILD_IMAGE_REPO}" "${KUBE_BUILD_IMAGE_TAG_BASE}" "${KUBE_BUILD_IMAGE_TAG}"
  # 确保 DATA 容器运行
  kube::build::ensure_data_container
  # 将 本机的数据 拷贝到 容器中
  kube::build::sync_to_container
}

# Build a docker image from a Dockerfile.
# $1 is the name of the image to build
# $2 is the location of the "context" directory, with the Dockerfile at the root.
# $3 is the value to set the --pull flag for docker build; true by default
# $4 is the set of --build-args for docker.
function kube::build::docker_build() {
  local -r image=$1
  local -r context_dir=$2
  local -r pull="${3:-true}"
  local build_args
  IFS=" " read -r -a build_args <<<"$4"
  readonly build_args
  # 完整的 docker build 命令
  local -ra build_cmd=("${DOCKER[@]}" build -t "${image}" "--pull=${pull}" "${build_args[@]}" "${context_dir}")

  kube::log::status "Building Docker image ${image}"
  local docker_output
  docker_output=$("${build_cmd[@]}" 2>&1) || {
    cat <<EOF >&2
+++ Docker build command failed for ${image}

${docker_output}

To retry manually, run:

${build_cmd[*]}

EOF
    return 1
  }
}

function kube::build::ensure_data_container() {
  # If the data container exists AND exited successfully, we can use it.
  # Otherwise nuke it and start over.
  local ret=0
  local code=0

  code=$(docker inspect \
    -f '{{.State.ExitCode}}' \
    "${KUBE_DATA_CONTAINER_NAME}" 2>/dev/null) || ret=$?
  if [[ "${ret}" == 0 && "${code}" != 0 ]]; then
    kube::build::destroy_container "${KUBE_DATA_CONTAINER_NAME}"
    ret=1
  fi
  if [[ "${ret}" != 0 ]]; then
    kube::log::status "Creating data container ${KUBE_DATA_CONTAINER_NAME}"
    # We have to ensure the directory exists, or else the docker run will
    # create it as root.
    mkdir -p "${LOCAL_OUTPUT_GOPATH}"
    # We want this to run as root to be able to chown, so non-root users can
    # later use the result as a data container.  This run both creates the data
    # container and chowns the GOPATH.
    #
    # The data container creates volumes for all of the directories that store
    # intermediates for the Go build. This enables incremental builds across
    # Docker sessions. The *_cgo paths are re-compiled versions of the go std
    # libraries for true static building.
    local -ra docker_cmd=(
      "${DOCKER[@]}" run
      --volume "${REMOTE_ROOT}" # white-out the whole output dir
      --volume /usr/local/go/pkg/linux_386_cgo
      --volume /usr/local/go/pkg/linux_amd64_cgo
      --volume /usr/local/go/pkg/linux_arm_cgo
      --volume /usr/local/go/pkg/linux_arm64_cgo
      --volume /usr/local/go/pkg/linux_ppc64le_cgo
      --volume /usr/local/go/pkg/darwin_amd64_cgo
      --volume /usr/local/go/pkg/darwin_386_cgo
      --volume /usr/local/go/pkg/windows_amd64_cgo
      --volume /usr/local/go/pkg/windows_386_cgo
      --name "${KUBE_DATA_CONTAINER_NAME}"
      --hostname "${HOSTNAME}"
      "${KUBE_BUILD_IMAGE}"
      chown -R "${USER_ID}":"${GROUP_ID}"
      "${REMOTE_ROOT}"
      /usr/local/go/pkg/
    )
    "${docker_cmd[@]}"
  fi
}

# Run a command in the kube-build image.  This assumes that the image has
# already been built.
function kube::build::run_build_command() {
  kube::log::status "Running build command..."
  # 执行 编译命令
  kube::build::run_build_command_ex "${KUBE_BUILD_CONTAINER_NAME}" -- "$@"
}

# Run a command in the kube-build image.  This assumes that the image has
# already been built.
#
# Arguments are in the form of
#  <container name> <extra docker args> -- <command>
# 传入参数格式为：<container name> <extra docker args> -- <command>
function kube::build::run_build_command_ex() {
  # $# 表示参数的个数
  # 如果参数 == 0 报错
  [[ $# != 0 ]] || {
    echo "Invalid input - please specify a container name." >&2
    return 4
  }
  # 第一个参数为 容器的名称
  local container_name="${1}"
  shift

  # 运行运行时的 选项
  # --name 容器的名称
  # --user 以哪个用户运行容器
  # --hostname 容器的hostname
  # --volumes-from 挂载目录
  local -a docker_run_opts=(
    "--name=${container_name}"
    "--user=$(id -u):$(id -g)"
    "--hostname=${HOSTNAME}"
    "${DOCKER_MOUNT_ARGS[@]}"
  )

  local detach=false

  # 此时已经取出了第一个参数 $1 ，并且 shift 后，$1 就为第二个桉树
  # $# 就为 总参数个数-1
  [[ $# != 0 ]] || {
    echo "Invalid input - please specify docker arguments followed by --." >&2
    return 4
  }
  # Everything before "--" is an arg to docker
  # until 循环执行一系列命令直至条件为 true 时停止。
  # 此时 $1 为 第二个参数 extra docker args，也就是循环遍历所有的 选项
  until [ -z "${1-}" ]; do
    # 如果是  --  标识符，直接跳出
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    # 否则，将选项添加进  docker_run_opts
    docker_run_opts+=("$1")
    if [[ "$1" == "-d" || "$1" == "--detach" ]]; then
      detach=true
    fi
    shift
  done

  # Everything after "--" is the command to run
  # 在 -- 标识符后，是编译的命令，如果没有 则报错
  [[ $# != 0 ]] || {
    echo "Invalid input - please specify a command to run." >&2
    return 4
  }

  local -a cmd=()
  # 标准的 参数循环方法
  until [ -z "${1-}" ]; do
    cmd+=("$1")
    shift
  done

  # 添加环境变量：
  docker_run_opts+=(
    --env "KUBE_FASTBUILD=${KUBE_FASTBUILD:-false}"
    --env "KUBE_BUILDER_OS=${OSTYPE:-notdetected}"
    --env "KUBE_VERBOSE=${KUBE_VERBOSE}"
    --env "KUBE_BUILD_WITH_COVERAGE=${KUBE_BUILD_WITH_COVERAGE:-}"
    --env "KUBE_BUILD_PLATFORMS=${KUBE_BUILD_PLATFORMS:-}"
    --env "GOFLAGS=${GOFLAGS:-}"
    --env "GOGCFLAGS=${GOGCFLAGS:-}"
    --env "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-}"
  )

  # use GOLDFLAGS only if it is set explicitly.
  if [[ -v GOLDFLAGS ]]; then
    docker_run_opts+=(
      --env "GOLDFLAGS=${GOLDFLAGS:-}"
    )
  fi

  if [[ -n "${DOCKER_CGROUP_PARENT:-}" ]]; then
    kube::log::status "Using ${DOCKER_CGROUP_PARENT} as container cgroup parent"
    docker_run_opts+=(--cgroup-parent "${DOCKER_CGROUP_PARENT}")
  fi

  # If we have stdin we can run interactive.  This allows things like 'shell.sh'
  # to work.  However, if we run this way and don't have stdin, then it ends up
  # running in a daemon-ish mode.  So if we don't have a stdin, we explicitly
  # attach stderr/stdout but don't bother asking for a tty.
  if [[ -t 0 ]]; then
    docker_run_opts+=(--interactive --tty)
  elif [[ "${detach}" == false ]]; then
    docker_run_opts+=("--attach=stdout" "--attach=stderr")
  fi

  # docker_cmd 是一个列表，里面包含了 docker run 的完整命令
  local -ra docker_cmd=(
    "${DOCKER[@]}" run "${docker_run_opts[@]}" "${KUBE_BUILD_IMAGE}")

  # Clean up container from any previous run
  # 删掉之前构建时的同名 container
  kube::build::destroy_container "${container_name}"

  # 执行构建操作的 具体命令
  # docekr_cmd 是 docker run 的完整命令，而 cmd 是 构建的命令，也就是 make cross
  "${docker_cmd[@]}" "${cmd[@]}"

  # 判断是否保留容器
  if [[ "${detach}" == false ]]; then
    kube::build::destroy_container "${container_name}"
  fi
}

function kube::build::rsync_probe() {
  # Wait unil rsync is up and running.
  local tries=20
  while ((tries > 0)); do
    if rsync "rsync://k8s@${1}:${2}/" \
      --password-file="${LOCAL_OUTPUT_BUILD_CONTEXT}/rsyncd.password" \
      &>/dev/null; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.1
  done

  return 1
}

# Start up the rsync container in the background. This should be explicitly
# stopped with kube::build::stop_rsyncd_container.
#
# This will set the global var KUBE_RSYNC_ADDR to the effective port that the
# rsync daemon can be reached out.
function kube::build::start_rsyncd_container() {
  IPTOOL=ifconfig
  if kube::build::has_ip; then
    IPTOOL="ip address"
  fi
  kube::build::stop_rsyncd_container
  V=3 kube::log::status "Starting rsyncd container"
  kube::build::run_build_command_ex \
    "${KUBE_RSYNC_CONTAINER_NAME}" -p 127.0.0.1:"${KUBE_RSYNC_PORT}":"${KUBE_CONTAINER_RSYNC_PORT}" -d \
    -e ALLOW_HOST="$(${IPTOOL} | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')" \
    -- /rsyncd.sh >/dev/null

  local mapped_port
  if ! mapped_port=$("${DOCKER[@]}" port "${KUBE_RSYNC_CONTAINER_NAME}" ${KUBE_CONTAINER_RSYNC_PORT} 2>/dev/null | cut -d: -f 2); then
    kube::log::error "Could not get effective rsync port"
    return 1
  fi

  local container_ip
  container_ip=$("${DOCKER[@]}" inspect --format '{{ .NetworkSettings.IPAddress }}' "${KUBE_RSYNC_CONTAINER_NAME}")

  # Sometimes we can reach rsync through localhost and a NAT'd port.  Other
  # times (when we are running in another docker container on the Jenkins
  # machines) we have to talk directly to the container IP.  There is no one
  # strategy that works in all cases so we test to figure out which situation we
  # are in.
  if kube::build::rsync_probe 127.0.0.1 "${mapped_port}"; then
    KUBE_RSYNC_ADDR="127.0.0.1:${mapped_port}"
    return 0
  elif kube::build::rsync_probe "${container_ip}" ${KUBE_CONTAINER_RSYNC_PORT}; then
    KUBE_RSYNC_ADDR="${container_ip}:${KUBE_CONTAINER_RSYNC_PORT}"
    return 0
  fi

  kube::log::error "Could not connect to rsync container."
  return 1
}

function kube::build::stop_rsyncd_container() {
  V=3 kube::log::status "Stopping any currently running rsyncd container"
  unset KUBE_RSYNC_ADDR
  kube::build::destroy_container "${KUBE_RSYNC_CONTAINER_NAME}"
}

function kube::build::rsync() {
  local -a rsync_opts=(
    --archive
    "--password-file=${LOCAL_OUTPUT_BUILD_CONTEXT}/rsyncd.password"
  )
  if ((KUBE_VERBOSE >= 6)); then
    rsync_opts+=("-iv")
  fi
  if ((KUBE_RSYNC_COMPRESS > 0)); then
    rsync_opts+=("--compress-level=${KUBE_RSYNC_COMPRESS}")
  fi
  V=3 kube::log::status "Running rsync"
  rsync "${rsync_opts[@]}" "$@"
}

# This will launch rsyncd in a container and then sync the source tree to the
# container over the local network.
function kube::build::sync_to_container() {
  kube::log::status "Syncing sources to container"
  # 启动 RSYNCD 容器
  kube::build::start_rsyncd_container

  # rsync filters are a bit confusing.  Here we are syncing everything except
  # output only directories and things that are not necessary like the git
  # directory and generated files. The '- /' filter prevents rsync
  # from trying to set the uid/gid/perms on the root of the sync tree.
  # As an exception, we need to sync generated files in staging/, because
  # they will not be re-generated by 'make'. Note that the 'H' filtered files
  # are hidden from rsync so they will be deleted in the target container if
  # they exist. This will allow them to be re-created in the container if
  # necessary.
  kube::build::rsync \
    --delete \
    --filter='H /.git' \
    --filter='- /.make/' \
    --filter='- /_tmp/' \
    --filter='- /_output/' \
    --filter='- /' \
    --filter='H zz_generated.*' \
    --filter='H generated.proto' \
    "${KUBE_ROOT}/" "rsync://k8s@${KUBE_RSYNC_ADDR}/k8s/"

  # 关闭 RSYNCD 容器
  kube::build::stop_rsyncd_container
}

# Copy all build results back out.
# 将 编译后的所有文件 从容器中 拷贝到 主机
function kube::build::copy_output() {
  kube::log::status "Syncing out of container"

  # 开启 RSYNCD 容器，并且会设置 该容器的 ip 地址 到 KUBE_RSYNC_ADDR 环境变量
  kube::build::start_rsyncd_container

  # The filter syntax for rsync is a little obscure. It filters on files and
  # directories.  If you don't go in to a directory you won't find any files
  # there.  Rules are evaluated in order.  The last two rules are a little
  # magic. '+ */' says to go in to every directory and '- /**' says to ignore
  # any file or directory that isn't already specifically allowed.
  #
  # We are looking to copy out all of the built binaries along with various
  # generated files.
  # 使用 rsync 命令过滤 目录 进行有选择的拷贝
  kube::build::rsync \
    --prune-empty-dirs \
    --filter='- /_temp/' \
    --filter='+ /vendor/' \
    --filter='+ /staging/***/Godeps/**' \
    --filter='+ /_output/dockerized/bin/**' \
    --filter='+ zz_generated.*' \
    --filter='+ generated.proto' \
    --filter='+ *.pb.go' \
    --filter='+ types.go' \
    --filter='+ */' \
    --filter='- /**' \
    "rsync://k8s@${KUBE_RSYNC_ADDR}/k8s/" "${KUBE_ROOT}"

  # 关闭 RSYNCD 容器
  kube::build::stop_rsyncd_container
}
