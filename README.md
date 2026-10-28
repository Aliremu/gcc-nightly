# gcc-nightly

Weekly builds of GCC trunk ([gcc-mirror/gcc](https://github.com/gcc-mirror/gcc), tracked as the
`gcc` submodule), published as release archives, Docker images and a Nix flake.

| Build | Archive | Docker image | Nix |
| --- | --- | --- | --- |
| x86-64 Linux, native | `gcc-linux-native-<commit>.tar.zst` | `ghcr.io/aliremu/gcc-nightly:nightly` (amd64) | `x86_64-linux` |
| arm64 Linux, native | `gcc-linux-arm64-native-<commit>.tar.zst` | `ghcr.io/aliremu/gcc-nightly:nightly` (arm64) | `aarch64-linux` |
| x86-64 Linux → Windows (MinGW-w64) | `gcc-windows-<commit>.tar.zst` | `ghcr.io/aliremu/gcc-nightly:windows-nightly` | — |
| Windows-hosted, native | `gcc-windows-native-<commit>.tar.zst` | — | — |

Every build gets a release and git tag `<version>-<date>-<commit>`, such as `17.0.0-20261027-2e76f0ca4736`.
Docker images are also tagged with the release tag.

## Using it

### Docker

The images are Debian bookworm with GCC in `/opt/gcc-trunk` (on `PATH`, and set as `CC`/`CXX`).

```dockerfile
# As a base image
FROM ghcr.io/aliremu/gcc-nightly:nightly

# Or copy the toolchain into another bookworm-or-newer image
FROM ghcr.io/aliremu/gcc-nightly:nightly AS gcc
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends binutils libc6-dev
COPY --from=gcc /opt/gcc-trunk /opt/gcc-trunk
ENV PATH=/opt/gcc-trunk/bin:$PATH
```

Pin a build with a release tag instead of `nightly`, for example `:17.0.0-20261027-2e76f0ca4736`.

### Nix

The default branch always points at the latest trunk build, and each release tag pins one build.

```sh
nix shell github:Aliremu/gcc-nightly            # gcc/g++ on PATH
nix develop github:Aliremu/gcc-nightly          # shell whose cc/c++ is GCC trunk
nix shell github:Aliremu/gcc-nightly/<tag>      # a specific build
```

In a flake, use the overlay:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.gcc-nightly.url = "github:Aliremu/gcc-nightly";

  outputs = { nixpkgs, gcc-nightly, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ gcc-nightly.overlays.default ];
      };
    in {
      # pkgs.gcc-trunk is the wrapped compiler; gccTrunkStdenv builds with it.
      packages.x86_64-linux.default = pkgs.gccTrunkStdenv.mkDerivation { /* ... */ };
      devShells.x86_64-linux.default =
        pkgs.mkShell.override { stdenv = pkgs.gccTrunkStdenv; } { };
    };
}
```

Run `nix flake update gcc-nightly` to move to the newest build.

The flake downloads the release archive and only patches it; nothing is compiled.

## Setup on GitHub

1. Push this repository to GitHub. Release assets must be publicly downloadable for Nix to
   fetch them, so the repository should be public.
2. After the first run, make the `gcc-nightly` package public under
   *Your profile → Packages → gcc-nightly → Package settings* if you want anonymous `docker pull`s.
3. The release job pushes to the default branch with `GITHUB_TOKEN`. If that branch is protected,
   allow GitHub Actions to bypass the protection.

## Workflow

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs every Monday at 04:00 UTC, and
on demand from *Actions → Build GCC → Run workflow*:

- **gcc_ref**: branch, tag or full commit hash. Defaults to `master` (trunk).
- **targets**: any of `windows,linux-native,linux-arm64`. `windows` builds both Windows archives.

Jobs:

1. **prepare** resolves the ref to a commit and picks the release tag.
2. **build** builds each target group in parallel inside a `debian:bookworm` container.
3. **docker** pushes the images to GHCR.
4. **release** points `nix/sources/*.json` at the new release assets, checks that the flake
   compiles a test program, then commits, tags and creates the GitHub release.

Only a full `master` build moves the `nightly` Docker tags, the "latest" release and the default
branch. Other refs and partial builds publish under their release tag only.

Builds run on `ubuntu-latest` by default. If the 6-hour job limit is too tight, set the
`BUILD_RUNNER` repository variable to the label of a larger or self-hosted runner.

## Building locally

Needs Docker on an x86-64 Linux host:

```sh
scripts/fetch-gcc.sh                 # or: scripts/fetch-gcc.sh releases/gcc-15
BUILD_TARGETS=linux-native scripts/build-in-docker.sh
ls dist/
```

`scripts/build.sh` can also run directly on x86-64 Debian bookworm with the packages listed in
`scripts/build-in-docker.sh`. Build trees go to `work/` and are reused while the GCC commit and
configure options stay the same.
