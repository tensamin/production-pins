# Tensamin Production Pins

Provides pinned versions of the Client, Iota, Omikron, Omega, MTP and MTP type maps.
This can be used to see the exact versions of the deployed services.

- [Updates](https://docs.tensamin.net/updates/)

## Updating release pins

For a routine release, update only the inputs you intend to ship. For example,
run `nix flake update client` for a Client-only release or
`nix flake update iota mtp-type-maps` when shipping both together. Review the
result with `git diff -- flake.lock`.

Use `nix flake update` when deliberately refreshing all inputs, including
`nixpkgs` and `rust-overlay`. Changes to these shared inputs can invalidate
cached builds across all projects.
