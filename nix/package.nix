# Repackages a prebuilt archive from the GitHub release: no compiling, only
# pointing the dynamic x86-64 binaries at Nix's glibc and zlib (the arm64
# binaries are static).
{ lib, stdenv, fetchurl, zstd, patchelf, zlib, source }:

stdenv.mkDerivation {
  pname = "gcc-trunk";
  version = "${source.version}-${source.commit}";
  src = fetchurl {
    name = source.file;
    url = source.url;
    sha256 = source.sha256;
  };
  nativeBuildInputs = [ zstd patchelf ];
  sourceRoot = "opt/gcc-trunk";
  unpackCmd = "tar -I zstd -xf $curSrc";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  # GCC's non-PIE host binaries segfault if patchelf sets the interpreter
  # before the RPATH (autoPatchelfHook's order), or if the RPATH is shrunk
  # afterwards.
  dontPatchELF = true;
  installPhase = ''
    cp -a . $out
    find $out -type f -perm -u+x | while read -r f; do
      patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue
      patchelf --set-rpath ${lib.makeLibraryPath [ zlib ]} "$f"
      patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$f"
    done
  '';
  passthru = { isGNU = true; langC = true; langCC = true; };
  meta = {
    description = "GCC ${source.version} (commit ${source.commit}), prebuilt";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
