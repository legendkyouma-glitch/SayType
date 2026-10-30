#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/saytype-regression.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Compile the production logic with isolated dependencies. No app entry point,
# microphone, credentials, user history, or network request is used by these tests.
xcrun swiftc -swift-version 6 -parse-as-library \
  "$project_root/app/Sources/Cloud.swift" \
  "$project_root/app/Sources/History.swift" \
  "$project_root/app/Sources/ConfigurationPaths.swift" \
  "$project_root/tests/TestDependencies.swift" \
  "$project_root/tests/RegressionTests.swift" \
  -o "$test_dir/regression-tests"
"$test_dir/regression-tests"
