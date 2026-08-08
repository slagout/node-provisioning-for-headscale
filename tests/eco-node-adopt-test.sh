#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/eco-node-adopt.sh"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_equal "VI" "$(extract_code 'Virgin Islands (U.S.) (VI)')" "display region code"
assert_equal "US" "$(extract_code 'us')" "plain region code"

is_entrypoint "" "bash" || { echo "FAIL: streamed script was not treated as an entrypoint" >&2; exit 1; }
is_entrypoint "/tmp/eco-node-adopt.sh" "/tmp/eco-node-adopt.sh" || {
  echo "FAIL: directly executed script was not treated as an entrypoint" >&2
  exit 1
}
if is_entrypoint "/tmp/eco-node-adopt.sh" "/tmp/test-runner.sh"; then
  echo "FAIL: sourced script was treated as an entrypoint" >&2
  exit 1
fi

if extract_code "usvi_atlantic" >/dev/null; then
  echo "FAIL: non-country region code was accepted" >&2
  exit 1
fi

NODE_REGION="Virgin Islands (U.S.) (VI)"
NODE_REGION_CODE=""
prompt_for_region_selection
assert_equal "VI" "$REGION_CODE" "derived region code"

NODE_REGION="usvi_atlantic"
NODE_REGION_CODE="vi"
prompt_for_region_selection
assert_equal "VI" "$REGION_CODE" "explicit region code"
assert_equal "usvi_atlantic" "$REGION_DISPLAY" "region display preservation"

test_secret_dir="$(mktemp -d)"
trap 'rm -rf "$test_secret_dir"' EXIT
test_secret_file="${test_secret_dir}/secret"
printf 'test-secret-value' > "$test_secret_file"
stat() {
  printf '600\n'
}
assert_equal "test-secret-value" "$(read_secret_file TEST_SECRET "$test_secret_file")" "secret file"
unset -f stat

echo "Node adoption behavior tests passed."