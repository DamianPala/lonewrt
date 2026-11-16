#!/usr/bin/env bash
# Stand-in for fetch-deps.sh in the scratch repo of tests/ci: records its arguments.
set -euo pipefail
echo "fetch-deps.sh $*" >>"$STUB_REC/calls"
