#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source ./script/setup.sh

swift test \
    -c release \
    -Xswiftc -DIMMUTABLE_TREE_BENCHMARK \
    --filter ImmutableTreeBenchmarkTest
