pkgs: with pkgs; with lib; rec {

  relayGroupForRegion = region:
      let prefix =
        if (hasPrefix "ap" region) then "asia-pacific"
        else if (hasPrefix "us" region) then "north-america"
        else "europe";
      in "${prefix}.${globals.relaysNew}";

  withinOneHop =
    let
      # list of max number of nodes that can be connected within one hop using 'nbPeers':
      maxNbNodes = genList (p: { maxNbNodes = p * (p + 1); nbPeers = p;}) 100;
    in nodes: let
      nbNodes = length nodes;
      nbPeers = (findFirst (i: nbNodes <= i.maxNbNodes) (throw "too many nodes") maxNbNodes).nbPeers;
      indexedNodes = imap0 (idx: node: { inherit idx node;}) nodes;
      names = let names = map (n: n.name) nodes; in names ++ names; # to avoid overflows
      topologies = map ({node, idx}:
        rec { inherit node;
            startIndex = if idx == 0 then 1 else mod ((elemAt topologies (idx - 1)).endIndexExcluded) nbNodes;
            endIndexExcluded = let unfiltrerProducers = sublist startIndex nbPeers names;
              in startIndex + nbPeers + (if (elem node.name unfiltrerProducers) then 1 else 0);
            producers = filter (p: p != node.name) (sublist startIndex (endIndexExcluded - startIndex) names);
        }
      ) indexedNodes;
      in map (n: n.node // {
        producers = n.node.producers ++ n.producers;
      }) topologies;

  mkRelayTopology = {
    regions
  , relayPrefix ? "rel"
  , coreNodes
    # Since we don't have relays in every regions,
    # we define a substitute region for each region we don't deploy to;
  , regionsSubstitutesExtra ? {}
  , regionsSubstitutes ? {
      eu-north-1 = "eu-central-1";
      ap-northeast-3 = "ap-northeast-1";
      ap-northeast-2 = "ap-northeast-1";
      cn-north-1 = "ap-northeast-1";
      cn-northwest-1 = "ap-northeast-1";
      ap-east-1 = "ap-southeast-1";
      ap-south-1 = "ap-southeast-1";
      ap-southeast-2 = "ap-southeast-1";
      me-south-1 = "ap-southeast-1";
      us-east-1 = "us-east-2";
      sa-east-1 = "us-east-2";
      ca-central-1 = "us-east-2";
      us-west-2 = "us-west-1";
      af-south-1 = "eu-west-2";
      eu-west-1 = "eu-west-2";
      eu-west-3 = "eu-west-2";
    } // regionsSubstitutesExtra
  }:
    let

      inUseRegions = mapAttrsToList (_: r: r.name) regions;
      regionLetters = (attrNames regions);
      indexedRegions = imap0 (rIndex: rLetter:
        { inherit rIndex rLetter;
          region = regions.${rLetter}.name; }
      ) regionLetters;

      thirdPartyRelays = globals.static.additionalPeers ++
        (filter (r: !(hasSuffix globals.relaysNew r.addr))
          (if builtins.pathExists ../static/registered_relays_topology.json then
            (builtins.fromJSON (builtins.readFile ../static/registered_relays_topology.json)).Producers
          else []));

      stateAwsAffinityIndex = builtins.fromJSON (builtins.readFile (pkgs.aws-affinity-indexes + "/state-index.json"));

      thirdPartyRelaysByRegions = groupBy (r: r.region) (map
        (relay:
          let bestRegion = stateAwsAffinityIndex.${relay.state} or
            (builtins.trace "WARNING: relay has unknow 'state': ${relay.state}. Using ${regions.a.name})" regions.a.name);
          in relay // {
            region = if (builtins.elem bestRegion inUseRegions) then bestRegion else regionsSubstitutes.${bestRegion} or
            (builtins.trace "WARNING: relay affected to unknown 'region': ${bestRegion} (to be added in 'regionsSubstitutes'). Using ${regions.a.name})" regions.a.name);
          }
        ) thirdPartyRelays);

      indexedThirdPartyRelays = mapAttrs (_: (imap0 (index: mergeAttrs {inherit index;}))) thirdPartyRelaysByRegions;

      indexedCoreNodes = imap0 (index: mergeAttrs {inherit index;}) coreNodes;

      nbRelaysPerRegions = mapAttrs (_: {minRelays, name, ...}:
        # we scale so that relays have less than 20 producers, with a given minimum:
        minRelays + (builtins.div (length (thirdPartyRelaysByRegions.${name} or [])) 20)
      ) regions;
    in
      imap1 (i: r:
        removeAttrs r ["nodeIndex"] // { nodeId = i + (length coreNodes); }
      ) (sort (r1: r2: r1.nodeIndex < r2.nodeIndex) (concatMap ({rLetter, rIndex, region}:
        let
          nbRelays = nbRelaysPerRegions.${rLetter};
          relayIndexesInRegion = genList (i: i + 1) nbRelays;
          relaysForRegion = map (nodeIndex:
            let
              name = "${relayPrefix}-${rLetter}-${toString nodeIndex}";
            in {
              inherit region name nodeIndex;
              producers =
                # a share of the core nodes:
                (map (c: c.name) (filter (c: mod c.index nbRelays == (nodeIndex - 1)) indexedCoreNodes))
                # one relay in each other regions:
                ++ map (r: "${relayPrefix}-${r}-${toString (mod (nodeIndex - 1) nbRelaysPerRegions.${r} + 1)}") (filter (r: r != rLetter) regionLetters)
                # a share of the third-party relays:
                ++ (filter (p: mod p.index nbRelays == (nodeIndex - 1)) (indexedThirdPartyRelays.${region} or []));
              org = "IOHK";
            }
          ) relayIndexesInRegion;
        # Ensure every relay inside the region is at most at one hop away from one another:
        in withinOneHop relaysForRegion
      ) indexedRegions));

}
