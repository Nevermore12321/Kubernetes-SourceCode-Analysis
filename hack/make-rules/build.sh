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

set -o errexit
set -o nounset
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
#
kube::golang::build_binaries "$@"
kube::golang::place_bins
