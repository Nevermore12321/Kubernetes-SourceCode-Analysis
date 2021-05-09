#!/usr/bin/env bash

# Copyright 2016 The Kubernetes Authors.
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

# This script sets up a temporary Kubernetes GOPATH and runs an arbitrary
# command under it. Go tooling requires that the current directory be under
# GOPATH or else it fails to find some things, such as the vendor directory for
# the project.
# Usage: `hack/run-in-gopath.sh <command>`.

# set -o errexit 等同于 set -e
# 表示 如果命令以非零状态退出，则立即退出。
set -o errexit
# set -o nounset 等同于 set -u
# 表示 替换时，将未设置的变量视为错误。
set -o nounset
# 表示 管道的返回值是最后一个以非零状态退出的命令的状态，如果没有命令以非零状态退出，则返回零。
set -o pipefail

# 设置 kubernetes 的 根目录，这里 BASH_SOURCE 为空，因此 KUBE_ROOT=./../
KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

# /hack/lib/init.sh 脚本做了一些初始化的工作，包括：
# 1. 初始化一些常量，并将其 export 到环境变量中
# 2. 加载了一些 工具函数
# 3. 捕捉 ERR 信号，并且 确保 bash 的版本大于4
source "${KUBE_ROOT}/hack/lib/init.sh"

# This sets up a clean GOPATH and makes sure we are currently in it.
# 执行 kube::golang::setup_env 函数，双冒号无意义相当于下划线
# 这个函数就是确保有一个 干净的 GOPATH 来使用
kube::golang::setup_env

# Run the user-provided command.
# 执行 用户传进来的 命令
"${@}"
