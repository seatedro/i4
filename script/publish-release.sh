#!/bin/bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

build_version=""
github_repo="seatedro/i4"
git_remote="origin"
codesign_identity="-"
notarytool_profile=""
cask_git_repo_path=""
site_git_repo_path=""
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --github-repo) github_repo="$2"; shift 2;;
        --git-remote) git_remote="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        --notarytool-profile) notarytool_profile="$2"; shift 2;;
        --cask-git-repo-path) cask_git_repo_path="$2"; shift 2;;
        --site-git-repo-path) site_git_repo_path="$2"; shift 2;;
        *) echo "Unknown option $1"; exit 1;;
    esac
done

if test -z "$build_version"; then
    echo "--build-version flag is mandatory" > /dev/stderr
    exit 1
fi

if test -n "$cask_git_repo_path" && ! test -d "$cask_git_repo_path"; then
    echo "--cask-git-repo-path must point to existing directory" > /dev/stderr
    exit 1
fi

if test -n "$site_git_repo_path" && ! test -d "$site_git_repo_path"; then
    echo "--site-git-repo-path must point to existing directory" > /dev/stderr
    exit 1
fi

if ! command -v gh > /dev/null; then
    echo "gh CLI is required to publish the GitHub release" > /dev/stderr
    exit 1
fi

tag="v$build_version"
zip_path=".release/AeroSpace-v$build_version.zip"
dmg_path=".release/AeroSpace-v$build_version.dmg"
release_zip_url="https://github.com/$github_repo/releases/download/$tag/AeroSpace-v$build_version.zip"

./test.sh
build_release_args=(
    --build-version "$build_version"
    --codesign-identity "$codesign_identity"
)
if test -n "$notarytool_profile"; then
    build_release_args+=(--notarytool-profile "$notarytool_profile")
fi
./build-release.sh "${build_release_args[@]}"

git tag -a "$tag" -m "$tag"
git push "$git_remote" "$tag"
release_assets=("$dmg_path")
if test -n "$cask_git_repo_path"; then
    release_assets+=("$zip_path")
fi
gh release create "$tag" "${release_assets[@]}" \
    --repo "$github_repo" \
    --title "$tag" \
    --notes "Fork build from $github_repo."

if test -n "$cask_git_repo_path"; then
    ./script/build-brew-cask.sh \
        --cask-name aerospace \
        --zip-uri "$release_zip_url" \
        --build-version "$build_version" \
        --homepage-uri "https://github.com/$github_repo"

    if test -x "$cask_git_repo_path/pin.sh"; then
        "$cask_git_repo_path/pin.sh"
    fi
    mkdir -p "$cask_git_repo_path/Casks"
    cp -r .release/aerospace.rb "$cask_git_repo_path/Casks/aerospace.rb"
fi

if test -n "$site_git_repo_path"; then
    rm -rf "${site_git_repo_path:?}/*" # https://www.shellcheck.net/wiki/SC2115
    cp -r .site/* "$site_git_repo_path"
fi
