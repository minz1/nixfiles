{ lib, topology }:

{
  denyUnless =
    {
      nodes ? [ ],
      sources ? [ ],
    }:
    let
      checked = map (
        n:
        if topology.nodes ? ${n} && topology.nodes.${n}.kind != "device" then
          n
        else
          throw "denyUnless: ${n} is not a fleet server node"
      ) nodes;
    in
    {
      match = [
        {
          not =
            lib.optional (checked != [ ]) {
              expression = lib.concatMapStringsSep " || " (
                n: ''{http.request.tls.client.subject} == "CN=${n}.internal"''
              ) checked;
            }
            ++ lib.optional (sources != [ ]) { remote_ip.ranges = sources; };
        }
      ];
      handle = [
        {
          handler = "static_response";
          status_code = 403;
        }
      ];
    };
}
