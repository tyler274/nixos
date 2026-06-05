{ config, lib, pkgs, ... }:

{
  programs.plasma = {
    enable = true;

    workspace = {
      lookAndFeel = "org.kde.breezedark.desktop";
      cursor = {
        theme = "breeze_cursors";
        size = 24;
      };
    };

    kwin = {
      # No magnetic edge resistance on screen edges; prevents cursor from
      # snagging when moving between monitors in multi-display setups.
      edgeBarrier = 0;
      cornerBarrier = false;
    };

    kscreenlocker = {
      lockOnResume = true;
      # Lock after 15 minutes of inactivity.
      timeout = 15;
      passwordRequired = true;
      passwordRequiredDelay = 0;
    };

    shortcuts = {
      ksmserver."Lock Session" = [ "Screensaver" "Meta+Ctrl+Alt+L" ];
      kwin = {
        # Overview / Expose for quick window switching.
        "Expose"     = "Meta+,";
        "Expose All" = "Meta+.";
        # Vim-style directional focus switching.
        "Switch Window Down"  = "Meta+J";
        "Switch Window Left"  = "Meta+H";
        "Switch Window Right" = "Meta+L";
        "Switch Window Up"    = "Meta+K";
      };
    };

    configFile = {
      # Baloo file indexer generates substantial I/O churn on ZFS; disable it.
      # Use ripgrep or `locate` via `plocate` if search is needed.
      "baloofilerc"."Basic Settings"."Indexing-Enabled" = false;

      # Four virtual desktops laid out in a single horizontal row.
      "kwinrc".Desktops.Number = { value = 4; };
      "kwinrc".Desktops.Rows   = { value = 1; };

      # Show KRunner centred and floating rather than anchored to the top bar.
      "krunnerrc".General.FreeFloating = true;

      # Place window close/min/max buttons on the Right (Windows muscle memory).
      "kwinrc"."org.kde.kdecoration2".ButtonsOnRight = "XIA";
    };

    panels = [
      {
        location = "bottom";
        height   = 48;
        widgets  = [
          {
            kickoff = {
              sortAlphabetically = true;
              icon = "nix-snowflake-white";
            };
          }
          {
            iconTasks = {
              launchers = [
                "applications:org.kde.dolphin.desktop"
                "applications:org.kde.konsole.desktop"
                "applications:firefox.desktop"
              ];
            };
          }
          "org.kde.plasma.marginsseparator"
          {
            systemTray.items = {
              shown = [
                "org.kde.plasma.networkmanagement"
                "org.kde.plasma.volume"
                "org.kde.plasma.bluetooth"
              ];
            };
          }
          {
            digitalClock = {
              calendar.firstDayOfWeek = "sunday";
              time.format = "24h";
            };
          }
          "org.kde.plasma.showdesktop"
        ];
      }
    ];
  };

  # Konsole terminal emulator profile — font must be set for size changes to
  # work (plasma-manager limitation: always writes the font name to the profile).
  programs.konsole = {
    enable = true;
    defaultProfile = "nix";
    profiles."nix" = {
      name        = "nix";
      colorScheme = "Breeze";
      font = {
        name = "Hack Nerd Font Mono";
        size = 11;
      };
    };
  };
}
