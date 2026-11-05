# Boot nixhost's role next to a LAN client and assert what the HTPC and the
# laptop depend on: the cache answers on 8080, the netboot API answers the
# HTPC's MAC and nobody else's, nothing else is open, the nightly timer is at
# 01:30 and catches up after downtime, and the git account takes clones and
# pushes over SSH but gives no shell. The last subtest runs the nightly unit
# against a stub nightly.sh pushed to the bare repo, so the checkout, the
# branch setting and the signing-key handoff are exercised without a build.
{ pkgs }:
let
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  htpcMac = "bc:e9:2f:86:35:3b";

  # The real image is the flake's htpc-netboot package, a few hundred MB.
  # The API only ever reads these three names, so stand-ins prove the wiring.
  fakeImage = pkgs.runCommand "fake-htpc-netboot" { } ''
    mkdir $out
    echo fake-kernel > $out/bzImage
    echo fake-initrd > $out/initrd
    echo "init=/nix/store/fake-toplevel/init loglevel=4" > $out/cmdline
  '';
in
pkgs.testers.runNixOSTest {
  name = "update-host";

  nodes.nixhost = {
    imports = [
      ../roles/base.nix
      ../roles/update-host.nix
    ];

    roles.update-host = {
      enable = true;
      netbootMac = htpcMac;
      netbootImage = fakeImage;
      # Not the default, so the test sees the setting reach the checkout.
      branch = "feat/test";
      haUrl = "http://127.0.0.1:8123";
      notifyService = "notify.test";
      environmentFile = "/run/nixhost-env";
      gitAuthorizedKeys = [ keys.snakeOilEd25519PublicKey ];
    };

    virtualisation.memorySize = 2048;
  };

  nodes.client =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.git
        pkgs.curl
      ];
      programs.ssh.extraConfig = ''
        Host nixhost
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
          IdentityFile /root/.ssh/id_ed25519
      '';
    };

  testScript = ''
    import json
    import re

    start_all()
    nixhost.wait_for_unit("multi-user.target")
    nixhost.wait_for_unit("nixhost-git-setup.service")
    nixhost.wait_for_unit("nginx.service")
    nixhost.wait_for_unit("pixiecore.service")
    nixhost.wait_for_unit("nixhost-pxe-api.service")
    nixhost.wait_for_open_port(8080)
    nixhost.wait_for_open_port(8099, "127.0.0.1")
    client.wait_for_unit("multi-user.target")

    client.succeed(
        "install -d -m 700 /root/.ssh && "
        "install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/.ssh/id_ed25519"
    )

    with subtest("the cache is served on 8080 from /srv/nix-cache"):
        nixhost.succeed("echo 'StoreDir: /nix/store' > /srv/nix-cache/nix-cache-info")
        code = client.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://nixhost:8080/nix-cache-info"
        )
        assert code == "200", f"cache file: HTTP {code}"
        body = client.succeed("curl -sf http://nixhost:8080/nix-cache-info")
        assert body.strip() == "StoreDir: /nix/store", f"cache served {body!r}"
        code = client.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://nixhost:8080/no-such-file"
        )
        assert code == "404", f"missing file: HTTP {code}"

    with subtest("the netboot API answers the HTPC's MAC with kernel and initrd"):
        for mac in ["${htpcMac}", "bc%3Ae9%3A2f%3A86%3A35%3A3b"]:
            out = json.loads(
                nixhost.succeed(f"curl -sf http://127.0.0.1:8099/v1/boot/{mac}")
            )
            assert out.get("kernel"), f"no kernel for {mac}: {out}"
            assert out.get("initrd"), f"no initrd for {mac}: {out}"
            assert "init=/nix/store/fake-toplevel/init" in out.get("cmdline", ""), out
        assert nixhost.succeed(f"curl -sf {out['kernel']}").strip() == "fake-kernel"
        assert nixhost.succeed(f"curl -sf {out['initrd'][0]}").strip() == "fake-initrd"

    with subtest("any other MAC gets a 404"):
        for mac in ["52:54:00:12:34:56", "bc:e9:2f:86:35:3c", ""]:
            code = nixhost.succeed(
                "curl -s -o /dev/null -w '%{http_code}' "
                f"http://127.0.0.1:8099/v1/boot/{mac}"
            )
            assert code == "404", f"MAC {mac!r}: HTTP {code}"

    with subtest("only SSH, the cache and the PXE set are open"):
        rules = nixhost.succeed("iptables -S nixos-fw")
        opened = set(
            (proto, int(port))
            for proto, port in re.findall(
                r"-p (tcp|udp) .*--dport (\d+) .*-j nixos-fw-accept", rules
            )
        )
        expected = {
            ("tcp", 22),
            ("tcp", 8080),
            ("tcp", 8081),
            ("udp", 67),
            ("udp", 69),
            ("udp", 4011),
        }
        assert opened == expected, f"open ports {sorted(opened)}, expected {sorted(expected)}"
        # Pixiecore is what the LAN talks to; the API it reads is not.
        client.fail("curl -s --max-time 5 http://nixhost:8099/v1/boot/${htpcMac}")
        client.succeed("curl -s --max-time 5 -o /dev/null http://nixhost:8081/")

    with subtest("the nightly timer fires at 01:30 and catches up after downtime"):
        nixhost.succeed("systemctl is-active nixhost-nightly.timer")
        cal = nixhost.succeed("systemctl show nixhost-nightly.timer -p TimersCalendar")
        assert "OnCalendar=*-*-* 01:30:00" in cal, cal
        persistent = nixhost.succeed("systemctl show nixhost-nightly.timer -p Persistent")
        assert persistent.strip() == "Persistent=yes", persistent

    with subtest("git clones and pushes over SSH, and gives no shell"):
        client.succeed("git clone git@nixhost:/srv/git/terranse.git /tmp/terranse")
        client.succeed("git clone git@nixhost:/srv/git/home-player.git /tmp/home-player")
        client.succeed(
            "cd /tmp/terranse && mkdir scripts && "
            "cat > scripts/nightly.sh <<'EOF'\n"
            "#!/usr/bin/env bash\n"
            "{\n"
            '  echo "machine=$1"\n'
            '  echo "checkout=$(git rev-parse --abbrev-ref HEAD)"\n'
            '  echo "branch=$NIGHTLY_BRANCH"\n'
            '  echo "cache=$NIX_CACHE_DIR"\n'
            '  echo "key=$(cat "$SIGNING_KEY_FILE")"\n'
            '  echo "keymode=$(stat -c %a "$SIGNING_KEY_FILE")"\n'
            '  echo "ha=$HA_TOKEN $HA_URL $HA_NOTIFY_SERVICE"\n'
            '  echo "leak=''${NIX_SIGNING_KEY:-}"\n'
            '} > "$NIX_CACHE_DIR/stub-ran"\n'
            "EOF\n"
            "chmod +x scripts/nightly.sh && git add scripts && "
            "git -c user.name=t -c user.email=t@t commit -qm stub && "
            "git push -q origin HEAD:feat/test"
        )
        pushed = client.succeed("git -C /tmp/terranse rev-parse HEAD").strip()
        stored = nixhost.succeed(
            "runuser -u git -- git -C /srv/git/terranse.git rev-parse feat/test"
        ).strip()
        assert stored == pushed, f"bare repo has {stored}, pushed {pushed}"

        status, out = client.execute("ssh git@nixhost id 2>&1")
        assert status != 0, f"git ran a command: {out}"
        assert "uid=" not in out, out
        status, out = client.execute("ssh -tt git@nixhost 2>&1 </dev/null")
        assert status != 0, f"git got an interactive shell: {out}"

    with subtest("the nightly job runs nightly.sh from a checkout of the local repo"):
        # Values made up for the test; the real ones only ever come from 1Password.
        nixhost.succeed(
            "printf 'HA_TOKEN=test-ha-token\\nNIX_SIGNING_KEY=test-key:c2VjcmV0\\n' "
            "> /run/nixhost-env && chmod 600 /run/nixhost-env"
        )
        nixhost.succeed("systemctl start nixhost-nightly.service")
        ran = dict(
            line.split("=", 1)
            for line in nixhost.succeed("cat /srv/nix-cache/stub-ran").splitlines()
        )
        assert ran["machine"] == "htpc", ran
        assert ran["checkout"] == "feat/test", ran
        assert ran["branch"] == "feat/test", ran
        assert ran["cache"] == "/srv/nix-cache", ran
        assert ran["key"] == "test-key:c2VjcmV0", ran
        assert ran["keymode"] == "600", ran
        assert ran["ha"] == "test-ha-token http://127.0.0.1:8123 notify.test", ran
        assert ran["leak"] == "", f"signing key left in the environment: {ran}"
        # The key file is gone once the job is.
        nixhost.fail("ls /run/nixhost-nightly/signing.key")
  '';
}
