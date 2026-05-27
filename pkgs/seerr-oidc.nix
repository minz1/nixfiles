{
  lib,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  fetchFromGitHub,
  stdenv,
  makeWrapper,
  nodejs_22,
  python3,
  python3Packages,
  sqlite,
}:

let
  nodejs = nodejs_22;
  pnpm = pnpm_10.override { inherit nodejs; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "seerr";
  version = "3.2.0-oidc";

  # Fork of seerr-team/seerr adding OIDC/OpenID Connect login support.
  # Track upstream PR; replace src + pnpmDeps hashes once merged into seerr-team/seerr.
  # To get hashes: nix build .#packages.x86_64-linux.seerr-oidc 2>&1 | grep 'got:'
  src = fetchFromGitHub {
    owner = "michaelhthomas";
    repo = "seerr";
    rev = "98d6d8fbf53cd89fa70fb26cee58c11731f41200";
    hash = "sha256-bfNRUlMjKmxv0uvvjktQpCvCKl26C2Krs30ykkIRz7I=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 3;
    hash = "sha256-AvbTO6hBK/NB8uS6oLTgbgrARabvsFjiThqg2aTn1Fs=";
  };

  buildInputs = [ sqlite ];

  nativeBuildInputs = [
    python3
    python3Packages.distutils
    nodejs
    makeWrapper
    pnpmConfigHook
    pnpm
  ];

  preBuild = ''
    export npm_config_nodedir=${nodejs}
    pushd node_modules
    pnpm rebuild bcrypt sqlite3
    popd
  '';

  buildPhase = ''
    runHook preBuild
    pnpm build
    CI=true pnpm prune --prod --ignore-scripts
    rm -rf .next/cache
    find node_modules -xtype l -delete
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share
    cp -r -t $out/share .next node_modules dist public package.json seerr-api.yml
    runHook postInstall
  '';

  postInstall = ''
    mkdir -p $out/bin
    makeWrapper '${nodejs}/bin/node' "$out/bin/seerr" \
      --add-flags "$out/share/dist/index.js" \
      --chdir "$out/share" \
      --set NODE_ENV production
  '';

  meta = {
    description = "Seerr with OIDC login (fork: michaelhthomas feat/oidc-login-basic)";
    homepage = "https://github.com/michaelhthomas/seerr/tree/feat/oidc-login-basic";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "seerr";
  };
})
