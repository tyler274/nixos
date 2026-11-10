{ writeShellApplication, git, coreutils, gnugrep, gnused, util-linux }:
writeShellApplication {
  name = "coda-carry";
  runtimeInputs = [ git coreutils gnugrep gnused util-linux ];
  text = builtins.readFile ./coda-carry.sh;
}
