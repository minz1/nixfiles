{
  lib,
  topology,
  services,
  hostDirs,
}:
let
  inherit (builtins)
    attrNames
    attrValues
    concatMap
    filter
    head
    length
    ;
  inherit (lib) mapAttrsToList unique;

  cfg =
    (lib.evalModules {
      modules = [
        (import ./schema.nix { inherit lib hostDirs; })
        { inherit (topology) networks nodes; }
        services
      ];
    }).config;

  nodeList = attrValues cfg.nodes;
  memberships = concatMap (
    n:
    mapAttrsToList (net: m: {
      node = n.name;
      inherit net;
      inherit (m) ip role endpoint;
    }) n.networks
  ) nodeList;
  inNet = net: filter (m: m.net == net) memberships;
  dupes = xs: unique (filter (x: length (filter (y: y == x) xs) > 1) xs);
  # shortcut: /24 only, upgrade if a non-/24 network is added
  prefixOf = subnet: lib.concatStringsSep "." (lib.take 3 (lib.splitString "." subnet));
  needs =
    n: field: value:
    lib.optional (value == null) "${n.name}: ${n.kind} needs ${field}";

  failures =
    mapAttrsToList (
      net: v:
      lib.optionalString (!lib.hasSuffix "/24" v.subnet) "network ${net}: subnet ${v.subnet} is not /24"
    ) cfg.networks
    ++ map (
      m:
      if !(cfg.networks ? ${m.net}) then
        "${m.node}: unknown network ${m.net}"
      else
        lib.optionalString (
          !lib.hasPrefix "${prefixOf cfg.networks.${m.net}.subnet}." m.ip
        ) "${m.node}: ${m.ip} is outside ${m.net} ${cfg.networks.${m.net}.subnet}"
    ) memberships
    ++ concatMap (net: map (ip: "${net}: duplicate IP ${ip}") (dupes (map (m: m.ip) (inNet net)))) (
      attrNames cfg.networks
    )
    ++ concatMap (
      net:
      let
        servers = filter (m: m.role == "server") (inNet net);
      in
      lib.optional (
        cfg.networks.${net}.type == "wireguard" && length servers != 1
      ) "${net}: needs exactly one server, has ${toString (length servers)}"
    ) (attrNames cfg.networks)
    ++ map (m: "${m.node}: endpoint on ${m.net} but role is not server") (
      filter (m: m.endpoint != null && m.role != "server") memberships
    )
    ++ concatMap (
      n:
      if n.kind == "vps" || n.kind == "incus-host" then
        needs n "storage" n.storage
      else if n.kind == "incus-vm" || n.kind == "incus-container" then
        needs n "incus" n.incus
        ++ lib.optionals (n.incus != null) (
          if n.kind == "incus-vm" then
            needs n "incus.nix_gib" n.incus.nix_gib
            ++ needs n "incus.total_gib" n.incus.total_gib
            ++
              lib.optional
                (n.incus.nix_gib != null && n.incus.total_gib != null && n.incus.nix_gib + 4 > n.incus.total_gib)
                "${n.name}: nix_gib ${toString n.incus.nix_gib} leaves under 4 GiB of total_gib ${toString n.incus.total_gib} for /persist"
          else
            needs n "incus.root_gib" n.incus.root_gib
        )
      else
        [ ]
    ) nodeList
    ++ map (d: "hosts/${d} has no node in common/topology.nix") (
      filter (d: !(cfg.nodes ? ${d})) hostDirs
    )
    ++ mapAttrsToList (
      s: v:
      lib.optionalString (cfg.nodes.${v.host}.kind == "device") "service ${s}: host ${v.host} is a device"
    ) cfg.services
    ++ map (hp: "two services use ${hp}") (
      dupes (mapAttrsToList (_: v: "${v.host}:${toString v.port}") cfg.services)
    )
    ++ concatMap (
      s:
      mapAttrsToList (
        h: p:
        lib.optionalString (
          cfg.services.${s}.port == p
        ) "service ${s} uses hostPort ${h}'s port ${toString p}"
      ) cfg.hostPorts
    ) (attrNames cfg.services);

  errors = filter (e: e != "") failures;
  undeployed = map (n: n.name) (filter (n: n.kind != "device" && !n.hasConfig) nodeList);
  checked =
    if errors != [ ] then
      throw "fleet: invalid topology:\n  ${lib.concatStringsSep "\n  " errors}"
    else
      lib.warnIf (
        undeployed != [ ]
      ) "nixfiles: skipping undeployed VMs: ${lib.concatStringsSep ", " undeployed}" true;
  guard = x: builtins.seq checked x;

  nodes = guard cfg.nodes;

  addressOf =
    from: to:
    let
      fromNets = if nodes ? ${from} then nodes.${from}.networks else { };
      toNets = nodes.${to}.networks;
      shared = filter (net: fromNets ? ${net} && toNets ? ${net}) [
        "incus_bridge"
        "mgmt"
        "edge"
      ];
      own = filter (net: toNets ? ${net}) [
        "mgmt"
        "incus_bridge"
      ];
    in
    if shared != [ ] then
      toNets.${head shared}.ip
    else if own != [ ] then
      toNets.${head own}.ip
    else
      null;

  services' = guard cfg.services;
in
{
  inherit nodes addressOf;
  isGuest = node: node.kind == "incus-vm" || node.kind == "incus-container";
  networks = guard cfg.networks;
  services = services';
  hostPorts = guard cfg.hostPorts;
  withRole =
    role: lib.sort lib.lessThan (map (n: n.name) (filter (n: lib.elem role n.roles) nodeList));
  tunnelEndpoints = lib.sort lib.lessThan (
    map (m: m.ip) (
      filter (m: nodes.${m.node}.kind == "vps" && cfg.networks.${m.net}.type == "wireguard") memberships
    )
  );
  endpointsFor =
    host:
    lib.mapAttrs (_: s: {
      ip = addressOf host s.host;
      inherit (s) port;
    }) services';
}
