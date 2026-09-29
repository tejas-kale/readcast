#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
install_dir=${READCAST_INSTALL_DIR:-"$HOME/.local/share/readcast"}
command_dir=${READCAST_BIN_DIR:-"$HOME/.local/bin"}

mkdir -p "$install_dir" "$command_dir"
cp "$source_dir/app.R" "$source_dir/cli.R" "$source_dir/README.md" "$install_dir/"
cp -R "$source_dir/R" "$source_dir/bin" "$source_dir/org" "$install_dir/"
ln -sfn "$install_dir/bin/readcast" "$command_dir/readcast"

printf 'Installed Readcast to %s\n' "$install_dir"
printf 'Command: %s/readcast\n' "$command_dir"
case ":$PATH:" in
  *":$command_dir:"*) ;;
  *) printf 'Add %s to PATH in your shell profile.\n' "$command_dir" ;;
esac
