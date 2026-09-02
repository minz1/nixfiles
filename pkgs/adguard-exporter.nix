{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "adguard-exporter";
  version = "0-unstable-2025-09-14";

  # chosen over znandev/adguardexporter and JonanekDev (no license) — see docs/main-plan.md S4
  src = fetchFromGitHub {
    owner = "henrywhitaker3";
    repo = "adguard-exporter";
    rev = "9d49a564a88d46d32a5fa5afa42b620e2ce40af7";
    hash = "sha256-T9BtFD76hhf72x5CI1JpqpzxBoqrOqiUfyiAb2ktpFY=";
  };

  vendorHash = "sha256-fDSR0+INsVBD5XauPdSETMNJZkrIbpKwZ/6Tb2Po4fY=";

  meta = {
    description = "Prometheus exporter for AdGuard Home";
    homepage = "https://github.com/henrywhitaker3/adguard-exporter";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "adguard-exporter";
  };
})
