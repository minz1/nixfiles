{ lib }:
let
  inherit
    (import ./caddy.nix {
      inherit lib;
      topology.nodes = {
        a.kind = "incus-vm";
        b.kind = "incus-vm";
        d.kind = "device";
      };
    })
    denyUnless
    ;
  guard = not: {
    match = [ { inherit not; } ];
    handle = [
      {
        handler = "static_response";
        status_code = 403;
      }
    ];
  };
  expr = {
    expression = ''{http.request.tls.client.subject} == "CN=a.internal" || {http.request.tls.client.subject} == "CN=b.internal"'';
  };
  src = {
    remote_ip.ranges = [ "10.0.0.1/32" ];
  };
  fails = args: !(builtins.tryEval (lib.deepSeq (denyUnless args) true)).success;
  cases = {
    nodes =
      denyUnless {
        nodes = [
          "a"
          "b"
        ];
      } == guard [ expr ];
    sources = denyUnless { sources = [ "10.0.0.1/32" ]; } == guard [ src ];
    both =
      denyUnless {
        nodes = [
          "a"
          "b"
        ];
        sources = [ "10.0.0.1/32" ];
      } == guard [
        expr
        src
      ];
    unknown = fails { nodes = [ "x" ]; };
    device = fails { nodes = [ "d" ]; };
  };
in
{
  failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
}
