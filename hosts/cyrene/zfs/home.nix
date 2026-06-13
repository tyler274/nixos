{ ... }:

{
  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
    users = [
      "luluco"
      "phainon"
    ];
  };

  users.users.root.initialHashedPassword = "$6$31uKiv3HbrCU2pbC$D9qnquW32p.8cZH5yz.7j5ExFywS.6j2gii.bqZIRDj551HI2WO5yUiMsUUg0nP.KAXWtSEOj0.VWsXt0uAqt1";
}
