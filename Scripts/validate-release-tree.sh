#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fail() {
    echo "Release tree validation failed: $*" >&2
    exit 2
}

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! repo_root="$(git -C "$script_root" rev-parse --show-toplevel 2>/dev/null)"; then
    fail "the script must be located inside the project Git repository."
fi
cd "$repo_root"

required_paths=(
    Makefile
    LICENSE
    README.md
    README.zh-CN.md
    CHANGELOG.md
    CONTEXT.md
    Resources
    Sources
    Tests
    Scripts
    docs
)
for required_path in "${required_paths[@]}"; do
    if [[ ! -e "$required_path" ]]; then
        fail "required release path is missing: $required_path"
    fi
done

untracked_files=()
while IFS= read -r -d '' candidate; do
    if ! git ls-files --error-unmatch -- "$candidate" >/dev/null 2>&1 &&
        ! git check-ignore -q -- "$candidate"; then
        untracked_files+=("$candidate")
    fi
done < <(
    printf '%s\0' Makefile LICENSE README.md README.zh-CN.md CHANGELOG.md CONTEXT.md
    find Resources Sources Tests Scripts docs \( -type f -o -type l \) -print0
)

if [[ "${#untracked_files[@]}" -ne 0 ]]; then
    echo "Release tree validation failed: release inputs exist but are not tracked by Git:" >&2
    printf '  - %s\n' "${untracked_files[@]}" | sort >&2
    echo "Review and stage the intended files before creating a release commit; this check did not modify the index." >&2
    exit 2
fi

if ! git diff --quiet -- "${required_paths[@]}"; then
    echo "Release tree validation failed: release inputs differ between the working tree and Git index:" >&2
    git diff --name-status -- "${required_paths[@]}" >&2
    echo "Stage or restore these files so release artifacts match the prospective release commit." >&2
    exit 2
fi

echo "Release tree validation passed: source, tests, scripts, resources, documentation, and license are fully tracked."
