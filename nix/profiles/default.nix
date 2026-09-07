# kind -> module path, mirroring nix/roles/default.nix. A machine's `kind` in
# nix/machines.nix picks exactly one of these, and it is the only thing that
# decides whether the machine believes it has firmware and a disk.
{
  metal = ./metal.nix;
  lxc = ./lxc.nix;
}
