{
  minz-vultr-nix-0 = {
    type = "nixos";
    role = "server";
    ip = "10.8.0.1";
    sshUser = "minz1";
    publicKey = "R42VqreOxYnlgs6SoaX+uOHrzComhJcOMshgjjXHcBc=";
    endpoint = "144.202.58.162:51820";
  };
  device-2 = {
    type = "external";
    role = "client";
    ip = "10.8.0.2";
    publicKey = "kvjC79ivkCmFXBUiJm2wt4SLoyFrlxyiZvOffSraJCc=";
  };
  device-3 = {
    type = "external";
    role = "client";
    ip = "10.8.0.3";
    publicKey = "t/NvyVClqspHWixGJzjWBOnbfm4AyZNEdF9NGT1hWw4=";
  };
  minz-desktop = {
    type = "external";
    role = "client";
    ip = "10.8.0.4";
    publicKey = "E/ptYaj0yogTCFlHuvnYV88NLErGdOL5F8p/PeW6JXM=";
  };
  minz-home-vm-0 = {
    type = "nixos";
    role = "client";
    ip = "10.8.0.5";
    sshUser = "minz1";
    publicKey = "82wMGARWEdw9PGqZXYGRoo/fYOaCffokD3BOv/4mEG0=";
  };
}
