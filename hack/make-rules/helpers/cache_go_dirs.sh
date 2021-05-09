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

# This script finds, caches, and prints a list of all directories that hold
# *.go files.  If any directory is newer than the cache, re-find everything and
# update the cache.  Otherwise use the cached file.

# 这个脚本有三个作用：
# 1. 查找，有没有比传入的 缓存文件 更新的 目录项
# 2. 如果没有，表示之前的构建操作与这一次构建没有区别，直接退出
# 3. 如果有，则更新缓存文件，将所有的包含 .go 文件的目录写入到 传入的缓存文件中
set -o errexit
set -o nounset
set -o pipefail

# ${1:-string} 表示 如果 $1 为空值，则使用 string 的值来填充，如果不为空，则不变。
# if 判断 传入的第一个参数是否为空，如果为空，打印 Usage 信息，并退出
if [[ -z "${1:-}" ]]; then
    echo "usage: $0 <cache-file>"
    exit 1
fi
# CACHE 为 传入的参数，shift命令用于对参数的移动(左移)
# shift 完后，$1 就变成了 原先的 $2
CACHE="$1"; shift

# 捕捉信号 HUP INT TERM ERR，如果捕捉到这几个信号，则执行 rm 删除操作
trap 'rm -f "${CACHE}"' HUP INT TERM ERR

# This is a partial 'find' command.  The caller is expected to pass the
# remaining arguments.
#
# Example:
#   kfind -type f -name foobar.go
# kfind 是一个查找函数，可以传入类型和名称等 find 选项，例如：kfind -type f -name foobar.go
# 查找出除了vendor目录中所有的go文件，并且把 开头是 ./staging/src 目录转成 vendor 目录
function kfind() {
    # We want to include the "special" vendor directories which are actually
    # part of the Kubernetes source tree (./staging/*) but we need them to be
    # named as their ./vendor/* equivalents.  Also, we  do not want all of
    # ./vendor or even all of ./vendor/k8s.io.

    # find -H 选项表示 除了指定的路径外，不递归搜索其中的软连接的目录
    # -a(and),-o(or),!(not)  -prune(除了某个目录)
    # -not 内部 不要匹配 下划线 _ 开头的文件，不要匹配没有 以点 . 为后缀名字的文件
    # 搜索路径是 除了 ./vendor 目录下的其他目录
    # 最后 sed 将 ./staging/src 目录 转成 vendor 目录
    find -H .                      \
        \(                         \
        -not \(                    \
            \(                     \
                -name '_*' -o      \
                -name '.[^.]*' -o  \
                -path './vendor'   \
            \) -prune              \
        \)                         \
        \)                         \
        "$@"                       \
        | sed 's|^./staging/src|vendor|'
}

# It's *significantly* faster to check whether any directories are newer than
# the cache than to blindly rebuild it.
# 下面代码段的主要功能：
# 1. 找到比 CACHE 文件更新的目录
# 2. 如果没有，表示这次构建完全和上次一样，没有任何区别，直接退出
# 3. 如果有比 CACHE 新的目录，那就继续执行后面的操作
# -f  文件是否是普通文件（不是目录、设备文件、链接文件）
# -n(not)  表示 CACHE 不为空
# 如果 传入的 CACHE 是普通文件，且不为空
if [[ -f "${CACHE}" && -n "${CACHE}" ]]; then
    # 使用上面 kfind 函数，查找出比 CACHE 文件新的 目录 ，并显示函数
    # wc -l 显示行数
    N=$(kfind -type d -newer "${CACHE}" -print -quit | wc -l)
    # 如果查出的 行数 为 0，则打印 CACHE 文件内容，并退出
    if [[ "${N}" == 0 ]]; then
        cat "${CACHE}"
        exit
    fi
fi

# 创建 缓存文件夹
mkdir -p "$(dirname "${CACHE}")"
# 使用 kfind 函数，查找所有 .go 文件路径
# 第一个 sed 找到最后一个 / 后的内容，也就是文件名，替换为空
# 第二个 sed 将开头的 ./ 替换为空
# LC_ALL=C 是为了去除所有本地化的设置，让命令能正确执行。 sort -u 去除重复行并进行排序
# tee命令用于读取标准输入的数据，并将其内容输出成文件
kfind -type f -name \*.go  \
    | sed 's|/[^/]*$||'    \
    | sed 's|^./||'        \
    | LC_ALL=C sort -u     \
    | tee "${CACHE}"

