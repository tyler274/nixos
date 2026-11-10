# IPv4 ranges a sandbox (agent container or CI guest) must never reach:
# this host, the LAN, Tailscale's CGNAT range, link-local, multicast and the
# other special-purpose blocks. Imported as a plain list.
[
  "0.0.0.0/8"
  "10.0.0.0/8"
  "100.64.0.0/10"
  "127.0.0.0/8"
  "169.254.0.0/16"
  "172.16.0.0/12"
  "192.0.0.0/24"
  "192.168.0.0/16"
  "198.18.0.0/15"
  "224.0.0.0/4"
  "240.0.0.0/4"
]
