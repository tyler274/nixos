# NixOS configuration inside the coda-agent container (on top of what
# modules/nixos/agent-sandbox.nix sets for every sandbox).
{ repo }:
{ pkgs, ... }:
let
  secrets = "/run/agent-secrets";
  # Git asks this for HTTPS credentials; the token never lands in a git config.
  credentialHelper = pkgs.writeShellScript "github-token-credential" ''
    test "$1" = get || exit 0
    test -r ${secrets}/github-token || exit 0
    echo username=x-access-token
    echo "password=$(cat ${secrets}/github-token)"
  '';
in
{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.git = {
    enable = true;
    config = {
      # The agent has no SSH key; GitHub is reached over HTTPS with the
      # scoped token, including remotes written as git@github.com:.
      url."https://github.com/".insteadOf = [
        "git@github.com:"
        "ssh://git@github.com/"
      ];
      credential."https://github.com".helper = "${credentialHelper}";
      init.defaultBranch = "main";
    };
  };

  # gh and Doppler read their tokens from the environment.
  environment.extraInit = ''
    if [ -r ${secrets}/github-token ]; then
      GH_TOKEN="$(cat ${secrets}/github-token)"; export GH_TOKEN
    fi
    if [ -r ${secrets}/doppler-token ]; then
      DOPPLER_TOKEN="$(cat ${secrets}/doppler-token)"; export DOPPLER_TOKEN
    fi
  '';

  environment.systemPackages = with pkgs; [
    gnumake
    ripgrep
    fd
    rsync
    file
    which
  ];

  # Returns the disk of idle worktree builds (dev/worktree.sh in coda-rust).
  systemd.services.coda-worktree-gc = {
    description = "Reset idle coda-rust worktree builds to the seed";
    unitConfig.ConditionPathIsExecutable = "${repo}/dev/worktree.sh";
    path = with pkgs; [
      bash
      coreutils
      findutils
      git
      gnugrep
      gawk
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "agent";
      Group = "users";
      WorkingDirectory = repo;
      ExecStart = "${repo}/dev/worktree.sh gc";
    };
  };
  systemd.timers.coda-worktree-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
