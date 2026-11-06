# The HTPC's accounts against the real base role: sudo asks the grown-up for a
# password, the child's account has no sudo at all, and the fleet account that
# deploys to the box still gets in without one. It imports the host's own
# accounts.nix, not a copy, so this fails if that file stops doing its job.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "htpc-accounts";

  nodes.machine = {
    imports = [
      ../roles/base.nix
      ../hosts/htpc/accounts.nix
      ../hosts/htpc/deploy.nix
    ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("vuxna is an administrator who must type a password"):
        machine.succeed("id -nG vuxna | grep -w wheel")
        machine.fail("su - vuxna -c 'sudo -n true'")

    with subtest("barn has no administrative rights"):
        machine.fail("id -nG barn | grep -w wheel")
        machine.fail("su - barn -c 'sudo -n true'")

    with subtest("the fleet account still deploys without a password"):
        machine.succeed("su - default-user -c 'sudo -n true'")

    with subtest("the deploy account is not an administrator"):
        machine.fail("id -nG deploy | grep -w wheel")
        machine.fail("su - deploy -c 'sudo -n true'")
        # It logs in with the fleet key, not one of its own.
        assert (
            machine.succeed("cat /etc/ssh/authorized_keys.d/deploy")
            == machine.succeed("cat /etc/ssh/authorized_keys.d/default-user")
        )
  '';
}
