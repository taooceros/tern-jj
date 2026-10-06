# macOS path_helper resets PATH before this login-shell startup file. The package-manager
# directories match where the block looks for jj (`candidates` in changes.luau), so `jj` runs
# in a development pane wherever it is installed.
path=(/opt/homebrew/bin /usr/local/bin /opt/zerobrew/bin $HOME/.cargo/bin $HOME/.local/bin
  $HOME/.nix-profile/bin /Applications/Tern.app/Contents/MacOS $path)
