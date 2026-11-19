{
  root,
  central ? builtins.getFlake (toString root),
  kind ? "tools",
  channel ? "canary",
  system ? builtins.currentSystem,
  sources ? { },
}:
let
  pkgs = import central.inputs.nixpkgs {
    inherit system;
    overlays = [ central.inputs.rust-overlay.overlays.default ];
  };
  project = central.lib.mkPackages { inherit system sources; };
  # Reuse only the client's tool shells, with central nixpkgs and Rust inputs.
  clientTools = central.inputs.client;
  checks = import ./checks.nix {
    inherit
      pkgs
      project
      system
      ;
    root = central.outPath;
    inputs = central.inputs;
  };
  artifacts = import ./release-artifacts.nix { inherit pkgs project channel; };
  client = clientTools.packages.${system};
  releaseChecks = pkgs.linkFarm "release-checks" (
    pkgs.lib.mapAttrsToList (name: path: {
      inherit name path;
    }) checks
  );
  # Statically linked installers do not keep their build libraries alive for the cache.
  portableLibraries = pkgs.linkFarm "iota-portable-build-libraries" (
    pkgs.lib.concatMap (library: [
      {
        name = "${library.pname}-dev";
        path = pkgs.lib.getDev library;
      }
      {
        name = "${library.pname}-lib";
        path = pkgs.lib.getLib library;
      }
    ]) project.packages.iota-portable.buildInputs
  );
  web = project.packages.client-web.overrideAttrs { TENSAMIN_CHANNEL = channel; };
in
if kind == "tools" then
  pkgs.mkShell {
    CONTAINERS_POLICY = pkgs.writeText "release-containers-policy.json" (
      builtins.toJSON { default = [ { type = "insecureAcceptAnything"; } ]; }
    );
    packages = with pkgs; [
      nix
      git
      bun
      bash
      coreutils
      jq
      zip
      gnutar
      gzip
      openssh
      skopeo
      shellcheck
    ];
  }
else if kind == "electron" || kind == "tauri" then
  clientTools.devShells.${system}.${kind}.overrideAttrs (old: {
    buildInputs =
      builtins.filter (package: !(pkgs.lib.hasPrefix "corepack" (package.pname or ""))) (
        old.buildInputs or [ ]
      )
      ++ [ pkgs.pnpm ];
    nativeBuildInputs = builtins.filter (
      package: !(pkgs.lib.hasPrefix "corepack" (package.pname or ""))
    ) (old.nativeBuildInputs or [ ]);
    shellHook =
      ''cd "''${RELEASE_WORK:?}"''
      + "\n"
      + old.shellHook
      + "\n"
      + pkgs.lib.optionalString (kind == "tauri") ''
        if [[ -n ''${RELEASE_GRADLE_CACHE:-} ]]; then
          mkdir -p "$GRADLE_USER_HOME/caches" "$RELEASE_GRADLE_CACHE"/{modules-2,wrapper}
          ln -sfnT "$RELEASE_GRADLE_CACHE/modules-2" "$GRADLE_USER_HOME/caches/modules-2"
          ln -sfnT "$RELEASE_GRADLE_CACHE/wrapper" "$GRADLE_USER_HOME/wrapper"
        fi
      '';
  })
else if kind == "client-desktop" then
  client.release-desktop
else if kind == "client-android" then
  client.release-android
else if kind == "checks" then
  releaseChecks
else if kind == "portable" then
  artifacts.portable
else if kind == "web" then
  web
else if kind == "linux" then
  pkgs.linkFarm "release-linux-${channel}" (
    {
      checks = releaseChecks;
      inherit (artifacts) portable;
      portable-libraries = portableLibraries;
    }
    // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
      inherit web;
      inherit (project.packages) iota-daemon;
    }
  )
else if kind == "packages" then
  artifacts.packages
else if kind == "build" then
  import ./release-build.nix { inherit pkgs; }
else
  throw "Unknown release environment ${kind}"
