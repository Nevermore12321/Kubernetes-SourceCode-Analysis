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

# This script sets up a go workspace locally and builds all go components.

# set -o errexit 等同于 set -e
# 表示 如果命令以非零状态退出，则立即退出。
set -o errexit
# set -o nounset 等同于 set -u
# 表示 替换时，将未设置的变量视为错误。
set -o nounset
# 表示 管道的返回值是最后一个以非零状态退出的命令的状态，如果没有命令以非零状态退出，则返回零。
set -o pipefail

#  KUBE_ROOT 变量为：hack/make-rules/../.. 找到 根目录
KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/../..
KUBE_VERBOSE="${KUBE_VERBOSE:-1}"
# 载入 init.sh 脚本，功能：
# 1. 初始化一些常量，并将其 export 到环境变量中
# 2. 加载了一些 工具函数
# 3. 捕捉 ERR 信号，并且 确保 bash 的版本大于4
source "${KUBE_ROOT}/hack/lib/init.sh"

# 调用函数 kube::golang::build_binaries 并且传入 ./vendor/k8s.io/code-generator/cmd/prerelease-lifecycle-gen 参数
# build_binaries 函数进行 编译构建
kube::golang::build_binaries "$@"
# place_bins 就是将二进制文件拷贝到 ${KUBE_OUTPUT_BINDIR}/${platform} 目录中 ，也就是 ${KUBE_ROOT}/_output/local/bin
kube::golang::place_bins

