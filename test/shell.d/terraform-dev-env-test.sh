#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_home="$test_tmp/home with spaces"
stub_bin="$test_tmp/bin"
mkdir -p "$test_home/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/6.0.0/linux_amd64" "$stub_bin"

printf 'shared provider binary\n' >"$test_home/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/6.0.0/linux_amd64/terraform-provider-aws"
cat >"$test_home/.terraformrc" <<'CONFIG'
plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"
disable_checkpoint = true
CONFIG
printf 'complete -C /custom/bin/terraform terraform\n' >"$test_home/.bashrc"
printf 'autoload -U +X bashcompinit && bashcompinit\ncomplete -o nospace -C /custom/bin/terraform terraform\n' >"$test_home/.zshrc"
cp -a "$test_home" "$test_tmp/expected"

cat >"$stub_bin/mise" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_MISE_LOG"
STUB
chmod +x "$stub_bin/mise"

env -i HOME="$test_home" PATH="$stub_bin:/usr/bin:/bin" OMARCHY_PATH="$ROOT" \
  TEST_MISE_LOG="$test_tmp/mise.log" \
  /bin/bash "$ROOT/bin/omarchy-remove-dev-env" terraform >"$test_tmp/output"

diff -r "$test_tmp/expected" "$test_home" ||
  fail "Terraform removal preserves shared provider cache, config, and shell completions"
pass "Terraform removal preserves shared provider cache, config, and shell completions"

printf 'uninstall terraform --all\nrm -g terraform\n' >"$test_tmp/expected-mise.log"
cmp -s "$test_tmp/expected-mise.log" "$test_tmp/mise.log" ||
  fail "Terraform removal uninstalls mise versions and clears the global selection"
pass "Terraform removal uninstalls mise versions and clears the global selection"
