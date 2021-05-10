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

# The golang package that we are building.
readonly KUBE_GO_PACKAGE=k8s.io/kubernetes
readonly KUBE_GOPATH="${KUBE_OUTPUT}/go"

# The server platform we are building on.
readonly KUBE_SUPPORTED_SERVER_PLATFORMS=(
  linux/amd64
  linux/arm
  linux/arm64
  linux/s390x
  linux/ppc64le
)

# The node platforms we build for
readonly KUBE_SUPPORTED_NODE_PLATFORMS=(
  linux/amd64
  linux/arm
  linux/arm64
  linux/s390x
  linux/ppc64le
  windows/amd64
)

# If we update this we should also update the set of platforms whose standard
# library is precompiled for in build/build-image/cross/Dockerfile
readonly KUBE_SUPPORTED_CLIENT_PLATFORMS=(
  linux/amd64
  linux/386
  linux/arm
  linux/arm64
  linux/s390x
  linux/ppc64le
  darwin/amd64
  darwin/arm64
  windows/amd64
  windows/386
)

# Which platforms we should compile test targets for.
# Not all client platforms need these tests
readonly KUBE_SUPPORTED_TEST_PLATFORMS=(
  linux/amd64
  linux/arm
  linux/arm64
  linux/s390x
  linux/ppc64le
  darwin/amd64
  darwin/arm64
  windows/amd64
)

# The set of server targets that we are only building for Linux
# If you update this list, please also update build/BUILD.
# server 端所有的 targets，最后按空格为分隔符，打印出所有的targets
kube::golang::server_targets() {
  local targets=(
    cmd/kube-proxy
    cmd/kube-apiserver
    cmd/kube-controller-manager
    cmd/kubelet
    cmd/kubeadm
    cmd/kube-scheduler
    vendor/k8s.io/kube-aggregator
    vendor/k8s.io/apiextensions-apiserver
    cluster/gce/gci/mounter
  )
  echo "${targets[@]}"
}
# IFS 指定分隔符，read 指定 变量类型列表，<<< 直接传字符串 按空格解构成列表
# <<< 一般传递字符串，<< 一般用于追加文件，< 用于写入新文件
IFS=" " read -ra KUBE_SERVER_TARGETS <<< "$(kube::golang::server_targets)"
readonly KUBE_SERVER_TARGETS
# ${KUBE_SERVER_TARGETS[@]##*/} 将 KUBE_SERVER_TARGETS 列表的所有元素进行匹配，将所有满足 末尾是 / 的元素删除
# ${变量名##匹配规则} 从变量开头进行规则匹配，将符合数据最长的数据删除（贪婪匹配）
# KUBE_SERVER_BINARIES 表示 server 端需要编译的所有 二进制文件
# Server 端不支持 windows 操作系统
readonly KUBE_SERVER_BINARIES=("${KUBE_SERVER_TARGETS[@]##*/}")

# The set of server targets we build docker images for
kube::golang::server_image_targets() {
  # NOTE: this contains cmd targets for kube::build::get_docker_wrapped_binaries
  local targets=(
    cmd/kube-apiserver
    cmd/kube-controller-manager
    cmd/kube-scheduler
    cmd/kube-proxy
  )
  echo "${targets[@]}"
}

IFS=" " read -ra KUBE_SERVER_IMAGE_TARGETS <<< "$(kube::golang::server_image_targets)"
readonly KUBE_SERVER_IMAGE_TARGETS
readonly KUBE_SERVER_IMAGE_BINARIES=("${KUBE_SERVER_IMAGE_TARGETS[@]##*/}")

# The set of conformance targets we build docker image for
kube::golang::conformance_image_targets() {
  # NOTE: this contains cmd targets for kube::release::build_conformance_image
  local targets=(
    vendor/github.com/onsi/ginkgo/ginkgo
    test/e2e/e2e.test
    cluster/images/conformance/go-runner
    cmd/kubectl
  )
  echo "${targets[@]}"
}

IFS=" " read -ra KUBE_CONFORMANCE_IMAGE_TARGETS <<< "$(kube::golang::conformance_image_targets)"
readonly KUBE_CONFORMANCE_IMAGE_TARGETS

# The set of server targets that we are only building for Kubernetes nodes
# If you update this list, please also update build/BUILD.
kube::golang::node_targets() {
  local targets=(
    cmd/kube-proxy
    cmd/kubeadm
    cmd/kubelet
  )
  echo "${targets[@]}"
}

IFS=" " read -ra KUBE_NODE_TARGETS <<< "$(kube::golang::node_targets)"
readonly KUBE_NODE_TARGETS
readonly KUBE_NODE_BINARIES=("${KUBE_NODE_TARGETS[@]##*/}")
readonly KUBE_NODE_BINARIES_WIN=("${KUBE_NODE_BINARIES[@]/%/.exe}")

# ------------
# NOTE: All functions that return lists should use newlines.
# bash functions can't return arrays, and spaces are tricky, so newline
# separators are the preferred pattern.
# To transform a string of newline-separated items to an array, use kube::util::read-array:
# kube::util::read-array FOO < <(kube::golang::dups a b c a)
#
# ALWAYS remember to quote your subshells. Not doing so will break in
# bash 4.3, and potentially cause other issues.
# ------------

# Returns a sorted newline-separated list containing only duplicated items.
kube::golang::dups() {
  # We use printf to insert newlines, which are required by sort.
  printf "%s\n" "$@" | sort | uniq -d
}

# Returns a sorted newline-separated list with duplicated items removed.
kube::golang::dedup() {
  # We use printf to insert newlines, which are required by sort.
  printf "%s\n" "$@" | sort -u
}

# Depends on values of user-facing KUBE_BUILD_PLATFORMS, KUBE_FASTBUILD,
# and KUBE_BUILDER_OS.
# Configures KUBE_SERVER_PLATFORMS, KUBE_NODE_PLATFOMRS,
# KUBE_TEST_PLATFORMS, and KUBE_CLIENT_PLATFORMS, then sets them
# to readonly.
# The configured vars will only contain platforms allowed by the
# KUBE_SUPPORTED* vars at the top of this file.
declare -a KUBE_SERVER_PLATFORMS
declare -a KUBE_CLIENT_PLATFORMS
declare -a KUBE_NODE_PLATFORMS
declare -a KUBE_TEST_PLATFORMS
kube::golang::setup_platforms() {
  if [[ -n "${KUBE_BUILD_PLATFORMS:-}" ]]; then
    # KUBE_BUILD_PLATFORMS needs to be read into an array before the next
    # step, or quoting treats it all as one element.
    local -a platforms
    IFS=" " read -ra platforms <<< "${KUBE_BUILD_PLATFORMS}"

    # Deduplicate to ensure the intersection trick with kube::golang::dups
    # is not defeated by duplicates in user input.
    kube::util::read-array platforms < <(kube::golang::dedup "${platforms[@]}")

    # Use kube::golang::dups to restrict the builds to the platforms in
    # KUBE_SUPPORTED_*_PLATFORMS. Items should only appear at most once in each
    # set, so if they appear twice after the merge they are in the intersection.
    kube::util::read-array KUBE_SERVER_PLATFORMS < <(kube::golang::dups \
        "${platforms[@]}" \
        "${KUBE_SUPPORTED_SERVER_PLATFORMS[@]}" \
      )
    readonly KUBE_SERVER_PLATFORMS

    kube::util::read-array KUBE_NODE_PLATFORMS < <(kube::golang::dups \
        "${platforms[@]}" \
        "${KUBE_SUPPORTED_NODE_PLATFORMS[@]}" \
      )
    readonly KUBE_NODE_PLATFORMS

    kube::util::read-array KUBE_TEST_PLATFORMS < <(kube::golang::dups \
        "${platforms[@]}" \
        "${KUBE_SUPPORTED_TEST_PLATFORMS[@]}" \
      )
    readonly KUBE_TEST_PLATFORMS

    kube::util::read-array KUBE_CLIENT_PLATFORMS < <(kube::golang::dups \
        "${platforms[@]}" \
        "${KUBE_SUPPORTED_CLIENT_PLATFORMS[@]}" \
      )
    readonly KUBE_CLIENT_PLATFORMS

  elif [[ "${KUBE_FASTBUILD:-}" == "true" ]]; then
    host_arch=$(kube::util::host_arch)
    if [[ "${host_arch}" != "amd64" && "${host_arch}" != "arm64" ]]; then
      # on any platform other than amd64 and arm64, we just default to amd64
      host_arch="amd64"
    fi
    KUBE_SERVER_PLATFORMS=("linux/${host_arch}")
    readonly KUBE_SERVER_PLATFORMS
    KUBE_NODE_PLATFORMS=("linux/${host_arch}")
    readonly KUBE_NODE_PLATFORMS
    if [[ "${KUBE_BUILDER_OS:-}" == "darwin"* ]]; then
      KUBE_TEST_PLATFORMS=(
        "darwin/${host_arch}"
        "linux/${host_arch}"
      )
      readonly KUBE_TEST_PLATFORMS
      KUBE_CLIENT_PLATFORMS=(
        "darwin/${host_arch}"
        "linux/${host_arch}"
      )
      readonly KUBE_CLIENT_PLATFORMS
    else
      KUBE_TEST_PLATFORMS=("linux/${host_arch}")
      readonly KUBE_TEST_PLATFORMS
      KUBE_CLIENT_PLATFORMS=("linux/${host_arch}")
      readonly KUBE_CLIENT_PLATFORMS
    fi
  else
    KUBE_SERVER_PLATFORMS=("${KUBE_SUPPORTED_SERVER_PLATFORMS[@]}")
    readonly KUBE_SERVER_PLATFORMS

    KUBE_NODE_PLATFORMS=("${KUBE_SUPPORTED_NODE_PLATFORMS[@]}")
    readonly KUBE_NODE_PLATFORMS

    KUBE_CLIENT_PLATFORMS=("${KUBE_SUPPORTED_CLIENT_PLATFORMS[@]}")
    readonly KUBE_CLIENT_PLATFORMS

    KUBE_TEST_PLATFORMS=("${KUBE_SUPPORTED_TEST_PLATFORMS[@]}")
    readonly KUBE_TEST_PLATFORMS
  fi
}

kube::golang::setup_platforms

# The set of client targets that we are building for all platforms
# If you update this list, please also update build/BUILD.
# client 端所有的 targets
readonly KUBE_CLIENT_TARGETS=(
  cmd/kubectl
  cmd/kubectl-convert
)
# 同样 KUBE_CLIENT_BINARIES 表示 所有 client 端的 需要编译的二进制文件
# KUBE_CLIENT_BINARIES_WIN 表示 windows 版的 exe 文件
readonly KUBE_CLIENT_BINARIES=("${KUBE_CLIENT_TARGETS[@]##*/}")
readonly KUBE_CLIENT_BINARIES_WIN=("${KUBE_CLIENT_BINARIES[@]/%/.exe}")

# The set of test targets that we are building for all platforms
# If you update this list, please also update build/BUILD.
# 客户端 有关测试 test 的所有 targets，最后按空格为分隔符，打印出所有的targets
kube::golang::test_targets() {
  local targets=(
    cmd/gendocs
    cmd/genkubedocs
    cmd/genman
    cmd/genyaml
    cmd/genswaggertypedocs
    cmd/linkcheck
    vendor/github.com/onsi/ginkgo/ginkgo
    test/e2e/e2e.test
    cluster/images/conformance/go-runner
  )
  echo "${targets[@]}"
}
# 同样 将所有的 测试 targets 传入 列表 KUBE_TEST_TARGETS
# 拿到 linux 版 KUBE_TEST_BINARIES 二进制文件，和 windows 版 KUBE_TEST_BINARIES_WIN exe 文件
IFS=" " read -ra KUBE_TEST_TARGETS <<< "$(kube::golang::test_targets)"
readonly KUBE_TEST_TARGETS
readonly KUBE_TEST_BINARIES=("${KUBE_TEST_TARGETS[@]##*/}")
readonly KUBE_TEST_BINARIES_WIN=("${KUBE_TEST_BINARIES[@]/%/.exe}")
# If you update this list, please also update build/BUILD.
readonly KUBE_TEST_PORTABLE=(
  test/e2e/testing-manifests
  test/kubemark
  hack/e2e-internal
  hack/get-build.sh
  hack/ginkgo-e2e.sh
  hack/lib
)

# Test targets which run on the Kubernetes clusters directly, so we only
# need to target server platforms.
# These binaries will be distributed in the kubernetes-test tarball.
# If you update this list, please also update build/BUILD.
# 服务端，可以直接跑在 k8s 上的 二进制测试工具
kube::golang::server_test_targets() {
  local targets=(
    cmd/kubemark
    vendor/github.com/onsi/ginkgo/ginkgo
  )

  if [[ "${OSTYPE:-}" == "linux"* ]]; then
    targets+=( test/e2e_node/e2e_node.test )
  fi

  echo "${targets[@]}"
}
# 操作同上
IFS=" " read -ra KUBE_TEST_SERVER_TARGETS <<< "$(kube::golang::server_test_targets)"
readonly KUBE_TEST_SERVER_TARGETS
readonly KUBE_TEST_SERVER_BINARIES=("${KUBE_TEST_SERVER_TARGETS[@]##*/}")
readonly KUBE_TEST_SERVER_PLATFORMS=("${KUBE_SERVER_PLATFORMS[@]:+"${KUBE_SERVER_PLATFORMS[@]}"}")

# Gigabytes necessary for parallel platform builds.
# As of March 2021 (go 1.16/amd64), the RSS usage is 2GiB by using cached
# memory of 15GiB.
# This variable can be overwritten at your own risk.
# It's defaulting to 20G to provide some headroom.
# 如果需要开启 并行模式编译，就需要 内存大于 20G
readonly KUBE_PARALLEL_BUILD_MEMORY=${KUBE_PARALLEL_BUILD_MEMORY:-20}

readonly KUBE_ALL_TARGETS=(
  "${KUBE_SERVER_TARGETS[@]}"
  "${KUBE_CLIENT_TARGETS[@]}"
  "${KUBE_TEST_TARGETS[@]}"
  "${KUBE_TEST_SERVER_TARGETS[@]}"
)
readonly KUBE_ALL_BINARIES=("${KUBE_ALL_TARGETS[@]##*/}")

readonly KUBE_STATIC_LIBRARIES=(
  kube-apiserver
  kube-controller-manager
  kube-scheduler
  kube-proxy
  kubeadm
  kubectl
)

# Fully-qualified package names that we want to instrument for coverage information.
readonly KUBE_COVERAGE_INSTRUMENTED_PACKAGES=(
  k8s.io/kubernetes/cmd/kube-apiserver
  k8s.io/kubernetes/cmd/kube-controller-manager
  k8s.io/kubernetes/cmd/kube-scheduler
  k8s.io/kubernetes/cmd/kube-proxy
  k8s.io/kubernetes/cmd/kubelet
)

# KUBE_CGO_OVERRIDES is a space-separated list of binaries which should be built
# with CGO enabled, assuming CGO is supported on the target platform.
# This overrides any entry in KUBE_STATIC_LIBRARIES.
#  使用 cgo
IFS=" " read -ra KUBE_CGO_OVERRIDES_LIST <<< "${KUBE_CGO_OVERRIDES:-}"
readonly KUBE_CGO_OVERRIDES_LIST
# KUBE_STATIC_OVERRIDES is a space-separated list of binaries which should be
# built with CGO disabled. This is in addition to the list in
# KUBE_STATIC_LIBRARIES.
IFS=" " read -ra KUBE_STATIC_OVERRIDES_LIST <<< "${KUBE_STATIC_OVERRIDES:-}"
readonly KUBE_STATIC_OVERRIDES_LIST

# 判断是否是 静态链接库
kube::golang::is_statically_linked_library() {
  local e
  # Explicitly enable cgo when building kubectl for darwin from darwin.
  # 如果是 darwin 系统，并且 target 是 kubectl 那么就是 静态链接库，返回1
  [[ "$(go env GOHOSTOS)" == "darwin" && "$(go env GOOS)" == "darwin" &&
    "$1" == *"/kubectl" ]] && return 1
  # 后面代码段是判断，如果 target 有在 cgo 的列表中的，就是 静态链接库，返回1
  if [[ -n "${KUBE_CGO_OVERRIDES_LIST:+x}" ]]; then
    for e in "${KUBE_CGO_OVERRIDES_LIST[@]}"; do [[ "${1}" == *"/${e}" ]] && return 1; done;
  fi
  for e in "${KUBE_STATIC_LIBRARIES[@]}"; do [[ "${1}" == *"/${e}" ]] && return 0; done;
  if [[ -n "${KUBE_STATIC_OVERRIDES_LIST:+x}" ]]; then
    for e in "${KUBE_STATIC_OVERRIDES_LIST[@]}"; do [[ "${1}" == *"/${e}" ]] && return 0; done;
  fi
  return 1;
}

# kube::binaries_from_targets take a list of build targets and return the
# full go package to be built
#  根据之前设置的 targets 列表，返回 完整的 带有域名的 package 名称
kube::golang::binaries_from_targets() {
  local target
  for target; do
    # If the target starts with what looks like a domain name, assume it has a
    # fully-qualified package name rather than one that needs the Kubernetes
    # package prepended.
    # 如果 是以 域名 开头，那就不需要在添加 kubernetes 域名
    # [[:alnum:]]		匹配任意字母数字字符0-9，A-Z，a-z
    # 也就是 匹配到 xxx.xxx/ 这种域名格式，就不需要添加
    if [[ "${target}" =~ ^([[:alnum:]]+".")+[[:alnum:]]+"/" ]]; then
      echo "${target}"
    else
      # KUBE_GO_PACKAGE=k8s.io/kubernetes 也就是添加 k8s 的域名
      echo "${KUBE_GO_PACKAGE}/${target}"
    fi
  done
}

# Asks golang what it thinks the host platform is. The go tool chain does some
# slightly different things when the target platform matches the host platform.
kube::golang::host_platform() {
  echo "$(go env GOHOSTOS)/$(go env GOHOSTARCH)"
}

# Takes the platform name ($1) and sets the appropriate golang env variables
# for that platform.
# 获取平台名称 ($1)，并为该平台设置适当的 golang env变量。
kube::golang::set_platform_envs() {
  # 如果传入的参数 平台名称 为空，直接报错
  [[ -n ${1-} ]] || {
    kube::log::error_exit "!!! Internal error. No platform set in kube::golang::set_platform_envs"
  }

  export GOOS=${platform%/*}
  export GOARCH=${platform##*/}

  # Do not set CC when building natively on a platform, only if cross-compiling
  # 如果 传入的 platform 不是 本机的系统，设置交叉编译 CC 的变量，本机不设置
  if [[ $(kube::golang::host_platform) != "$platform" ]]; then
    # Dynamic CGO linking for other server architectures than host architecture goes here
    # If you want to include support for more server platforms than these, add arch-specific gcc names here
    case "${platform}" in
      "linux/amd64")
        export CGO_ENABLED=1
        export CC=${KUBE_LINUX_AMD64_CC:-x86_64-linux-gnu-gcc}
        ;;
      "linux/arm")
        export CGO_ENABLED=1
        export CC=${KUBE_LINUX_ARM_CC:-arm-linux-gnueabihf-gcc}
        ;;
      "linux/arm64")
        export CGO_ENABLED=1
        export CC=${KUBE_LINUX_ARM64_CC:-aarch64-linux-gnu-gcc}
        ;;
      "linux/ppc64le")
        export CGO_ENABLED=1
        export CC=${KUBE_LINUX_PPC64LE_CC:-powerpc64le-linux-gnu-gcc}
        ;;
      "linux/s390x")
        export CGO_ENABLED=1
        export CC=${KUBE_LINUX_S390X_CC:-s390x-linux-gnu-gcc}
        ;;
    esac
  fi

  # if CC is defined for platform then always enable it
  # 如果交叉编译 允许，那么就开启
  ccenv=$(echo "$platform" | awk -F/ '{print "KUBE_" toupper($1) "_" toupper($2) "_CC"}')
  if [ -n "${!ccenv-}" ]; then 
    export CGO_ENABLED=1
    export CC="${!ccenv}"
  fi
}

kube::golang::unset_platform_envs() {
  unset GOOS
  unset GOARCH
  unset GOROOT
  unset CGO_ENABLED
  unset CC
}

# Create the GOPATH tree under $KUBE_OUTPUT
kube::golang::create_gopath_tree() {
  local go_pkg_dir="${KUBE_GOPATH}/src/${KUBE_GO_PACKAGE}"
  local go_pkg_basedir
  go_pkg_basedir=$(dirname "${go_pkg_dir}")

  mkdir -p "${go_pkg_basedir}"

  # TODO: This symlink should be relative.
  if [[ ! -e "${go_pkg_dir}" || "$(readlink "${go_pkg_dir}")" != "${KUBE_ROOT}" ]]; then
    ln -snf "${KUBE_ROOT}" "${go_pkg_dir}"
  fi
}

# Ensure the go tool exists and is a viable version.
kube::golang::verify_go_version() {
  if [[ -z "$(command -v go)" ]]; then
    kube::log::usage_from_stdin <<EOF
Can't find 'go' in PATH, please fix and retry.
See http://golang.org/doc/install for installation instructions.
EOF
    return 2
  fi

  local go_version
  IFS=" " read -ra go_version <<< "$(GOFLAGS='' go version)"
  local minimum_go_version
  minimum_go_version=go1.16.0
  if [[ "${minimum_go_version}" != $(echo -e "${minimum_go_version}\n${go_version[2]}" | sort -s -t. -k 1,1 -k 2,2n -k 3,3n | head -n1) && "${go_version[2]}" != "devel" ]]; then
    kube::log::usage_from_stdin <<EOF
Detected go version: ${go_version[*]}.
Kubernetes requires ${minimum_go_version} or greater.
Please install ${minimum_go_version} or later.
EOF
    return 2
  fi
}

# kube::golang::setup_env will check that the `go` commands is available in
# ${PATH}. It will also check that the Go version is good enough for the
# Kubernetes build.
#
# Inputs:
#   KUBE_EXTRA_GOPATH - If set, this is included in created GOPATH
#
# Outputs:
#   env-var GOPATH points to our local output dir
#   env-var GOBIN is unset (we want binaries in a predictable place)
#   env-var GO15VENDOREXPERIMENT=1
#   current directory is within GOPATH
kube::golang::setup_env() {
  kube::golang::verify_go_version

  kube::golang::create_gopath_tree

  export GOPATH="${KUBE_GOPATH}"
  export GOCACHE="${KUBE_GOPATH}/cache"

  # Append KUBE_EXTRA_GOPATH to the GOPATH if it is defined.
  if [[ -n ${KUBE_EXTRA_GOPATH:-} ]]; then
    GOPATH="${GOPATH}:${KUBE_EXTRA_GOPATH}"
  fi

  # Make sure our own Go binaries are in PATH.
  export PATH="${KUBE_GOPATH}/bin:${PATH}"

  # Change directories so that we are within the GOPATH.  Some tools get really
  # upset if this is not true.  We use a whole fake GOPATH here to collect the
  # resultant binaries.  Go will not let us use GOBIN with `go install` and
  # cross-compiling, and `go install -o <file>` only works for a single pkg.
  local subdir
  subdir=$(kube::realpath . | sed "s|${KUBE_ROOT}||")
  cd "${KUBE_GOPATH}/src/${KUBE_GO_PACKAGE}/${subdir}" || return 1

  # Set GOROOT so binaries that parse code can work properly.
  GOROOT=$(go env GOROOT)
  export GOROOT

  # Unset GOBIN in case it already exists in the current session.
  unset GOBIN

  # This seems to matter to some tools
  export GO15VENDOREXPERIMENT=1
}

# This will take binaries from $GOPATH/bin and copy them to the appropriate
# place in ${KUBE_OUTPUT_BINDIR}
#
# Ideally this wouldn't be necessary and we could just set GOBIN to
# KUBE_OUTPUT_BINDIR but that won't work in the face of cross compilation.  'go
# install' will place binaries that match the host platform directly in $GOBIN
# while placing cross compiled binaries into `platform_arch` subdirs.  This
# complicates pretty much everything else we do around packaging and such.
kube::golang::place_bins() {
  local host_platform
  host_platform=$(kube::golang::host_platform)

  V=2 kube::log::status "Placing binaries"

  local platform
  for platform in "${KUBE_CLIENT_PLATFORMS[@]}"; do
    # The substitution on platform_src below will replace all slashes with
    # underscores.  It'll transform darwin/amd64 -> darwin_amd64.
    local platform_src="/${platform//\//_}"
    if [[ "${platform}" == "${host_platform}" ]]; then
      platform_src=""
      rm -f "${THIS_PLATFORM_BIN}"
      ln -s "${KUBE_OUTPUT_BINPATH}/${platform}" "${THIS_PLATFORM_BIN}"
    fi

    local full_binpath_src="${KUBE_GOPATH}/bin${platform_src}"
    if [[ -d "${full_binpath_src}" ]]; then
      mkdir -p "${KUBE_OUTPUT_BINPATH}/${platform}"
      find "${full_binpath_src}" -maxdepth 1 -type f -exec \
        rsync -pc {} "${KUBE_OUTPUT_BINPATH}/${platform}" \;
    fi
  done
}

# Try and replicate the native binary placement of go install without
# calling go install.
# 返回 output 的输出目录
kube::golang::outfile_for_binary() {
  local binary=$1
  local platform=$2
  # output_path = _output/local/bin
  local output_path="${KUBE_GOPATH}/bin"
  local bin
  bin=$(basename "${binary}")
  if [[ "${platform}" != "${host_platform}" ]]; then
    output_path="${output_path}/${platform//\//_}"
  fi
  if [[ ${GOOS} == "windows" ]]; then
    bin="${bin}.exe"
  fi
  # 最终返回的就是 _output/local/bin/platform/path
  # 例如 我本机的就是 _output/local/bin/linux/amd64
  echo "${output_path}/${bin}"
}

# Argument: the name of a Kubernetes package.
# Returns 0 if the binary can be built with coverage, 1 otherwise.
# NB: this ignores whether coverage is globally enabled or not.
kube::golang::is_instrumented_package() {
  kube::util::array_contains "$1" "${KUBE_COVERAGE_INSTRUMENTED_PACKAGES[@]}"
  return $?
}

# Argument: the name of a Kubernetes package (e.g. k8s.io/kubernetes/cmd/kube-scheduler)
# Echos the path to a dummy test used for coverage information.
kube::golang::path_for_coverage_dummy_test() {
  local package="$1"
  local path="${KUBE_GOPATH}/src/${package}"
  local name
  name=$(basename "${package}")
  echo "${path}/zz_generated_${name}_test.go"
}

# Argument: the name of a Kubernetes package (e.g. k8s.io/kubernetes/cmd/kube-scheduler).
# Creates a dummy unit test on disk in the source directory for the given package.
# This unit test will invoke the package's standard entry point when run.
kube::golang::create_coverage_dummy_test() {
  local package="$1"
  local name
  name="$(basename "${package}")"
  cat <<EOF > "$(kube::golang::path_for_coverage_dummy_test "${package}")"
package main
import (
  "testing"
  "k8s.io/kubernetes/pkg/util/coverage"
)

func TestMain(m *testing.M) {
  // Get coverage running
  coverage.InitCoverage("${name}")

  // Go!
  main()

  // Make sure we actually write the profiling information to disk, if we make it here.
  // On long-running services, or anything that calls os.Exit(), this is insufficient,
  // so we also flush periodically with a default period of five seconds (configurable by
  // the KUBE_COVERAGE_FLUSH_INTERVAL environment variable).
  coverage.FlushCoverage()
}
EOF
}

# Argument: the name of a Kubernetes package (e.g. k8s.io/kubernetes/cmd/kube-scheduler).
# Deletes a test generated by kube::golang::create_coverage_dummy_test.
# It is not an error to call this for a nonexistent test.
kube::golang::delete_coverage_dummy_test() {
  local package="$1"
  rm -f "$(kube::golang::path_for_coverage_dummy_test "${package}")"
}

# Arguments: a list of kubernetes packages to build.
# Expected variables: ${build_args} should be set to an array of Go build arguments.
# In addition, ${package} and ${platform} should have been set earlier, and if
# ${KUBE_BUILD_WITH_COVERAGE} is set, coverage instrumentation will be enabled.
#
# Invokes Go to actually build some packages. If coverage is disabled, simply invokes
# go install. If coverage is enabled, builds covered binaries using go test, temporarily
# producing the required unit test files and then cleaning up after itself.
# Non-covered binaries are then built using go install as usual.
kube::golang::build_some_binaries() {
  if [[ -n "${KUBE_BUILD_WITH_COVERAGE:-}" ]]; then
    local -a uncovered=()
    for package in "$@"; do
      if kube::golang::is_instrumented_package "${package}"; then
        V=2 kube::log::info "Building ${package} with coverage..."

        kube::golang::create_coverage_dummy_test "${package}"
        kube::util::trap_add "kube::golang::delete_coverage_dummy_test \"${package}\"" EXIT

        go test -c -o "$(kube::golang::outfile_for_binary "${package}" "${platform}")" \
          -covermode count \
          -coverpkg k8s.io/...,k8s.io/kubernetes/vendor/k8s.io/... \
          "${build_args[@]}" \
          -tags coverage \
          "${package}"
      else
        uncovered+=("${package}")
      fi
    done
    if [[ "${#uncovered[@]}" != 0 ]]; then
      V=2 kube::log::info "Building ${uncovered[*]} without coverage..."
      go install "${build_args[@]}" "${uncovered[@]}"
    else
      V=2 kube::log::info "Nothing to build without coverage."
     fi
   else
    V=2 kube::log::info "Coverage is disabled."
    go install "${build_args[@]}" "$@"
   fi
}

# 根据不同的 platform 来编译二进制文件
kube::golang::build_binaries_for_platform() {
  # This is for sanity.  Without it, user umasks can leak through.
  # umask 0022 表示默认创建新文件权限为755 也就是 rxwr-xr-x
  umask 0022

  local platform=$1

  local -a statics=()
  local -a nonstatics=()
  local -a tests=()

  V=2 kube::log::info "Env for ${platform}: GOOS=${GOOS-} GOARCH=${GOARCH-} GOROOT=${GOROOT-} CGO_ENABLED=${CGO_ENABLED-} CC=${CC-}"

  # 遍历每一个 target 进行编译
  # 下面这个遍历时进行归类：
  # 1. .test 结尾：放入 tests 列表
  # 2. 静态链接库：放入 statics 列表
  # 3. 非静态链接库：放入 nonstatics 列表
  for binary in "${binaries[@]}"; do
    # 如果是以.test 结尾，只有两个 ： e2e.test 和  e2e_node.test
    # =~ 表示允许使用正则
    if [[ "${binary}" =~ ".test"$ ]]; then
      tests+=("${binary}")
    elif kube::golang::is_statically_linked_library "${binary}"; then
      statics+=("${binary}")
    else
      nonstatics+=("${binary}")
    fi
  done

  local -a build_args
  # 编译 静态链接库
  if [[ "${#statics[@]}" != 0 ]]; then
    # 编译的参数，这里的参数，在 build_binaries 前面都已经设置过了
    build_args=(
      -installsuffix static
      ${goflags:+"${goflags[@]}"}
      -gcflags "${gogcflags:-}"
      -asmflags "${goasmflags:-}"
      -ldflags "${goldflags:-}"
      -tags "${gotags:-}"
    )
    # 开始执行编译函数 build_some_binaries
    CGO_ENABLED=0 kube::golang::build_some_binaries "${statics[@]}"
  fi

  # 编译 非静态链接库 ，与静态链接库编译的区别就是，是否启用 cgo
  if [[ "${#nonstatics[@]}" != 0 ]]; then
    build_args=(
      ${goflags:+"${goflags[@]}"}
      -gcflags "${gogcflags:-}"
      -asmflags "${goasmflags:-}"
      -ldflags "${goldflags:-}"
      -tags "${gotags:-}"
    )
    kube::golang::build_some_binaries "${nonstatics[@]}"
  fi

  # 编译.test ，直接用 go test 编译，并且执行测试文件
  for test in "${tests[@]:+${tests[@]}}"; do
    local outfile testpkg
    # 输出目录
    outfile=$(kube::golang::outfile_for_binary "${test}" "${platform}")
    testpkg=$(dirname "${test}")

    mkdir -p "$(dirname "${outfile}")"
    go test -c \
      ${goflags:+"${goflags[@]}"} \
      -gcflags "${gogcflags:-}" \
      -asmflags "${goasmflags:-}" \
      -ldflags "${goldflags:-}" \
      -tags "${gotags:-}" \
      -o "${outfile}" \
      "${testpkg}"
  done
}

# Return approximate physical memory available in gigabytes.
# 返回可以用的 物理内存
# 有三种方式：
# 1. /proc/meminfo 文件中的 MemAvailable 字段
# 2. /proc/meminfo 文件中的 MemTotal 字段
# 3. 如果是 docker 容器， sysctl -n hw.memsize 2>/dev/null
kube::golang::get_physmem() {
  local mem

  # Linux kernel version >=3.14, in kb
  # 查看 /proc/meminfo 文件中的 MemAvailable 字段，查看还有多少可用的内存
  if mem=$(grep MemAvailable /proc/meminfo | awk '{ print $2 }'); then
    echo $(( mem / 1048576 ))
    return
  fi

  # Linux, in kb
  if mem=$(grep MemTotal /proc/meminfo | awk '{ print $2 }'); then
    echo $(( mem / 1048576 ))
    return
  fi

  # OS X, in bytes. Note that get_physmem, as used, should only ever
  # run in a Linux container (because it's only used in the multiple
  # platform case, which is a Dockerized build), but this is provided
  # for completeness.
  # 如果是 docker 容器，执行此命令查看
  if mem=$(sysctl -n hw.memsize 2>/dev/null); then
    echo $(( mem / 1073741824 ))
    return
  fi

  # If we can't infer it, just give up and assume a low memory system
  # 如果都没有，那么 返回1，假设内存不足
  echo 1
}

# Build binaries targets specified
#
# Input:
#   $@ - targets and go flags.  If no targets are set then all binaries targets
#     are built.
#   KUBE_BUILD_PLATFORMS - Incoming variable of targets to build for.  If unset
#     then just the host architecture is built.
# build_binaries 函数用于编译出 二进制文件
# 输入：targets and go flags 如果targets为空，表示编译所有
# KUBE_BUILD_PLATFORMS 环境变量：使用什么平台进行构建，默认是主机模式
kube::golang::build_binaries() {
  # Create a sub-shell so that we don't pollute the outer environment
  # 这里使用 () 来启动一个 sub-shell 来执行下面代码，以至于不会污染外部的环境变量
  (
    # Check for `go` binary and set ${GOPATH}.
    # setup_env 函数用于构建一个 可以使用的 Go 执行环境
    kube::golang::setup_env
    # 打印 info 消息
    V=2 kube::log::info "Go version: $(GOFLAGS='' go version)"

    # 拿到 机器 的版本信息 linux/amd64
    local host_platform
    host_platform=$(kube::golang::host_platform)

    # 设置 局部变量
    local goflags goldflags goasmflags gogcflags gotags
    # If GOLDFLAGS is unset, then set it to the a default of "-s -w".
    # Disable SC2153 for this, as it will throw a warning that the local
    # variable goldflags will exist, and it suggest changing it to this.
    # shellcheck disable=SC2153

    # 设置 编译时的标记选项
    # goldflags -s -w 选项来禁用符号表以及debug信息
    # kube::version::ldflags 函数 打印需要传递给 go build 的 -ldflags 参数的值
    goldflags="${GOLDFLAGS=-s -w -buildid=} $(kube::version::ldflags)"
    goasmflags="-trimpath=${KUBE_ROOT}"
    gogcflags="${GOGCFLAGS:-} -trimpath=${KUBE_ROOT}"

    # extract tags if any specified in GOFLAGS
    # shellcheck disable=SC2001
    # 提取 在 GOFLAGS 中设置的 tag
    gotags="selinux,notest,$(echo "${GOFLAGS:-}" | sed -e 's|.*-tags=\([^-]*\).*|\1|')"

    # targets 是一个列表
    local -a targets=()
    local arg

    # 将传入的参数做判断，如果 以 - 开头，表示是 go flags，其他为 targets
    for arg; do
      if [[ "${arg}" == -* ]]; then
        # Assume arguments starting with a dash are flags to pass to go.
        goflags+=("${arg}")
      else
        targets+=("${arg}")
      fi
    done

    # ${#targets[@]} 表示数组的元素个数
    # 如果传入的 targets 为空，则直接使用所有的 targets
    if [[ ${#targets[@]} -eq 0 ]]; then
      targets=("${KUBE_ALL_TARGETS[@]}")
    fi


    local -a platforms
    # 读取 KUBE_BUILD_PLATFORMS  本机的系统版本信息
    IFS=" " read -ra platforms <<< "${KUBE_BUILD_PLATFORMS:-}"
    # 如果 没有 配置 KUBE_BUILD_PLATFORMS ，则直接 获取 本机的 系统信息
    if [[ ${#platforms[@]} -eq 0 ]]; then
      platforms=("${host_platform}")
    fi

    local -a binaries
    # read -r 屏蔽转义字符\
    # kube::golang::binaries_from_targets 传入了 所有 targets 的元素
    # binaries 就是 包括域名的完整的 package 名称
    while IFS="" read -r binary; do binaries+=("$binary"); done < <(kube::golang::binaries_from_targets "${targets[@]}")

    local parallel=false
    # 如果需要编译的平台 platforms 只有一个
    if [[ ${#platforms[@]} -gt 1 ]]; then
      local gigs
      # 获取 物理机的可用内存
      gigs=$(kube::golang::get_physmem)

      # 这里判断是否可以开启 并行模式 编译，要求：可用内存大于等于20G
      # KUBE_PARALLEL_BUILD_MEMORY 默认是 20
      if [[ ${gigs} -ge ${KUBE_PARALLEL_BUILD_MEMORY} ]]; then
        kube::log::status "Multiple platforms requested and available ${gigs}G >= threshold ${KUBE_PARALLEL_BUILD_MEMORY}G, building platforms in parallel"
        parallel=true
      else
        kube::log::status "Multiple platforms requested, but available ${gigs}G < threshold ${KUBE_PARALLEL_BUILD_MEMORY}G, building platforms in serial"
        parallel=false
      fi
    fi

    # 如果开启 并行模式
    if [[ "${parallel}" == "true" ]]; then
      kube::log::status "Building go targets for {${platforms[*]}} in parallel (output will appear in a burst when complete):" "${targets[@]}"
      local platform
      # 如果有多个 编译的平台，我这里就只有一个本机
      for platform in "${platforms[@]}"; do (
          # set_platform_envs 函数 根据不同的 platform 设置不同的 golang 环境
          kube::golang::set_platform_envs "${platform}"
          kube::log::status "${platform}: build started"

          kube::golang::build_binaries_for_platform "${platform}"
          kube::log::status "${platform}: build finished"
        ) &> "/tmp//${platform//\//_}.build" &
      done

      local fails=0
      for job in $(jobs -p); do
        wait "${job}" || (( fails+=1 ))
      done

      for platform in "${platforms[@]}"; do
        cat "/tmp//${platform//\//_}.build"
      done

      exit "${fails}"
    # 如果不开启 并行模式
    else
      for platform in "${platforms[@]}"; do
        kube::log::status "Building go targets for ${platform}:" "${targets[@]}"
        (
          kube::golang::set_platform_envs "${platform}"
          kube::golang::build_binaries_for_platform "${platform}"
        )
      done
    fi
  )
}
