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

# Build a Kubernetes release.  This will build the binaries, create the Docker
# images and other build artifacts.
#
# For pushing these artifacts publicly to Google Cloud Storage or to a registry
# please refer to the kubernetes/release repo at
# https://github.com/kubernetes/release.

set -o errexit
set -o nounset
set -o pipefail

# 源码的 根目录
KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

# build/common.sh 会加载很多 环境变量，并且加载一些常用的公用方法
source "${KUBE_ROOT}/build/common.sh"
# lib/release.sh 加载一些与 容器环境构建相关的 方法
source "${KUBE_ROOT}/build/lib/release.sh"

# 是否开启 单元测试，默认开启
KUBE_RELEASE_RUN_TESTS=${KUBE_RELEASE_RUN_TESTS-y}

# 构建步骤：
# 1. 容器构建环境的配置和验证
kube::build::verify_prereqs
# 2. build image 构建镜像
kube::build::build_image
# 3. 构建方法
kube::build::run_build_command make cross
#    3.1 是否开启单元测试
if [[ $KUBE_RELEASE_RUN_TESTS =~ ^[yY]$ ]]; then
  kube::build::run_build_command make test
  kube::build::run_build_command make test-integration
fi

# 4. 将文件从容器中拷贝到主机
kube::build::copy_output

# 5. 打包
kube::release::package_tarballs
