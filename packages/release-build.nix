{ pkgs }:
pkgs.writeShellScript "release-build" ''
  set -euo pipefail
  root=$(pwd)
  channel=''${1:?Channel required}
  out=$(realpath -m "''${2:?Output directory required}")
  [[ $channel == stable || $channel == canary ]]
  mkdir -p "$out"
  export TENSAMIN_CHANNEL=$channel ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export TENSAMIN_ANDROID_VERSION_CODE=''${RELEASE_SEQUENCE:?}
  system=''${3:-${pkgs.stdenv.hostPlatform.system}}
  target=''${4:-all}
  arch=''${system%-linux}
  [[ $target == all || $target == desktop || ( $target == android && $arch == x86_64 ) ]]
  build_android=false
  if [[ $target != desktop && $arch == x86_64 ]]; then
    build_android=true
  fi
  environment() {
    local kind=$1
    shift
    nix build --impure --no-update-lock-file --print-out-paths "$@" --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"$kind\"; channel = \"$channel\"; system = \"$system\"; }"
  }
  if [[ $target != android ]]; then
    link=(--no-link)
    if [[ -n ''${RUNNER_TEMP:-} ]]; then
      link=(--out-link "$RUNNER_TEMP/release-linux")
    fi
    linux=$(environment linux "''${link[@]}")
    cp -rL "$linux/portable/." "$out/"
    chmod -R u+w "$out"
    if [[ $arch == x86_64 ]]; then
      tar -czf "$out/client-web.tar.gz" -C "$linux/web" .
    fi
  fi
  if [[ -n ''${RELEASE_RUST_CACHE:-} && -n ''${RUNNER_TEMP:-} ]]; then
    # Cargo's metadata for path dependencies includes the workspace path.
    work_root=$RUNNER_TEMP/release-work
    mkdir "$work_root"
  else
    work_root=$(mktemp -d)
  fi
  work=$work_root/tensamin/client
  cleanup() {
    local status=$?
    trap - EXIT
    if [[ $build_android == true && -n ''${RELEASE_WORK:-} && -f $work/apps/tauri/src-tauri/gen/android/gradlew ]]; then
      # Re-enter the SDK's scoped GRADLE_USER_HOME, not a user's global daemon.
      if ! nix develop --impure --no-update-lock-file --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"tauri\"; }" \
        --command bash "$work/apps/tauri/src-tauri/gen/android/gradlew" --stop >/dev/null 2>&1; then
        printf 'Could not stop Gradle cleanly; retrying workspace cleanup.\n' >&2
      fi
    fi
    for _attempt in 1 2 3; do
      if rm -rf "$work_root"; then exit "$status"; fi
      sleep 1
    done
    exit 1
  }
  trap cleanup EXIT
  mkdir -p "$work"
  mtp_source=$(nix eval --impure --raw --expr "(builtins.getFlake \"$root\").inputs.mtp.outPath")
  cp -r "$mtp_source" "$work_root/mtp"
  chmod -R u+w "$work_root/mtp"
  source=$(nix build --no-update-lock-file --no-link --print-out-paths ".#packages.$system.client-source")
  cp -r "$source/frontend/client/." "$work/"
  cp -r "$source/mtp/sdk/." "$work_root/mtp/sdk/"
  chmod -R u+w "$work" "$work_root/mtp/sdk"
  export RELEASE_ROOT=$root RELEASE_OUT=$out RELEASE_WORK=$work RELEASE_ARCH=$arch
  export TENSAMIN_RELEASE_TAG=''${RELEASE_TAG:?} TENSAMIN_RELEASE_VERSION=$RELEASE_TAG
  export TENSAMIN_RELEASE_ASSET_BASE_URL="''${GITHUB_SERVER_URL:-https://github.com}/''${GITHUB_REPOSITORY:?}/releases/download/$RELEASE_TAG"
  # Pinned client revisions may still read the previous variable name.
  export FORGEJO_RELEASE_ASSET_BASE_URL=$TENSAMIN_RELEASE_ASSET_BASE_URL
  if [[ $target != android ]]; then
    desktop=$(environment client-desktop --no-link)
    nix develop --impure --no-update-lock-file --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"electron\"; system = \"$system\"; }" \
      --command bash "$desktop"
  fi
  if [[ $build_android == true ]]; then
    android=$(environment client-android --no-link)
    profile=()
    if [[ -n ''${RUNNER_TEMP:-} ]]; then
      profile=(--profile "$RUNNER_TEMP/release-android")
    fi
    nix develop --impure --no-update-lock-file "''${profile[@]}" --expr "import $root/packages/release-environment.nix { root = builtins.toPath \"$root\"; kind = \"tauri\"; }" \
      --command bash "$android"
  fi
''
