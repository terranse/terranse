#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  early-commands:
    - sudo systemctl stop ssh
  identity:
    hostname: ubuntu-base
    username: packer
    # SHA-512 hash injected from 1Password at build time via templatefile()
    password: "${password_hash}"
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - sudo
    - curl
    - wget
    - git
    - vim
    - htop
    - cloud-init
    - qemu-guest-agent
  storage:
    layout:
      name: lvm
  # user-data passthrough: applied by cloud-init on every boot of the
  # installed system, so SSH password auth stays on and cloud-init does
  # not expire / lock the packer account.
  user-data:
    ssh_pwauth: true
    disable_root: false
    chpasswd:
      expire: false
  late-commands:
    - 'echo "packer ALL=(ALL) NOPASSWD: ALL" > /target/etc/sudoers.d/packer'
    - 'curtin in-target --target=/target -- chmod 440 /etc/sudoers.d/packer'
    # Unlock, don't expire, and ensure password auth stays enabled across boots
    - 'curtin in-target --target=/target -- chage -E -1 -M -1 packer'
    - 'curtin in-target --target=/target -- passwd -u packer'
    - 'curtin in-target --target=/target -- systemctl enable qemu-guest-agent'
