# name -> module path. Adding a role is adding one line here and one file
# next to it; nothing else in the flake needs to know.
{
  base = ./base.nix;
  dev = ./dev.nix;
}
