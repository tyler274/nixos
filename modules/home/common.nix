{ config, pkgs, lib, ... }:

{
  home.username = "luluco";
  home.homeDirectory = "/home/luluco";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    p7zip
    wireguard-tools
    smartmontools
    dmidecode
    pciutils
    usbutils
    sanoid
    pv
    mbuffer
    lzop
    zstd
    zfs-prune-snapshots
    httm
    hydra-check
    aha
    lm_sensors
    gh
    fastfetch

    # Nix language tooling, available on every host so the Cursor/VS Code
    # Nix IDE extension (see .vscode/settings.json) can launch the LSP and
    # format on save regardless of whether the desktop module is imported.
    nixd
    nixfmt
  ];

  programs.bash = {
    enable = true;
    enableCompletion = true;
    historyControl = [ "ignoredups" "erasedups" ];
    shellAliases = {
      ll = "ls -alh";
      la = "ls -A";
      ".." = "cd ..";
      "..." = "cd ../..";
      nrs = "sudo nixos-rebuild switch --flake ~/code/nixos#$(hostname)";
      nrl = "sudo nixos-rebuild switch --flake ~/code/nixos";
      nfu = "nix flake update --flake ~/code/nixos";
    };
    bashrcExtra = ''
      # home-manager's activation service (hm-setup-env) runs bash -el (login +
      # errexit). As a login shell it sources .bashrc via .bash_profile. The
      # auto-generated "[[ $- == *i* ]] || return" guard below returns $? of the
      # failed test (1) which under set -e kills the whole activation before a
      # single step runs. Placing our own guard first with an explicit "return 0"
      # ensures non-interactive callers exit .bashrc cleanly.
      [[ $- == *i* ]] || return 0

      source ${pkgs.nix-index}/etc/profile.d/command-not-found.sh 2>/dev/null || true
    '';
  };

  programs.htop.enable = true;

  programs.git = {
    enable = true;
    signing.format = null;
    settings = {
      user = {
        name = "tyler";
        email = "tyler274port@gmail.com";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      rerere.enabled = true;
      core = {
        autocrlf = false;
        editor = "vim";
      };
      diff.colorMoved = "default";
      merge.conflictstyle = "zdiff3";
    };
  };

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        AddKeysToAgent = "yes";
        ControlMaster = "auto";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "10m";
      };
    };
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    settings = {
      add_newline = true;
      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };
      nix_shell = {
        disabled = false;
        symbol = " ";
      };
      rust.symbol = " ";
      git_branch.symbol = " ";
    };
  };

  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
    RUSTUP_HOME = "${config.home.homeDirectory}/.rustup";
    CARGO_HOME  = "${config.home.homeDirectory}/.cargo";
    CC_LD  = "mold";
    CXX_LD = "mold";
  };

  home.sessionPath = [
    "${config.home.homeDirectory}/.cargo/bin"
    "${config.home.homeDirectory}/.local/bin"
  ];

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      setSessionVariables = true;
      desktop = "${config.home.homeDirectory}/Desktop";
      documents = "${config.home.homeDirectory}/Documents";
      download = "${config.home.homeDirectory}/Downloads";
      music = "${config.home.homeDirectory}/Music";
      pictures = "${config.home.homeDirectory}/Pictures";
      publicShare = "${config.home.homeDirectory}/Public";
      templates = "${config.home.homeDirectory}/Templates";
      videos = "${config.home.homeDirectory}/Videos";
    };
  };
}
