# The general idea of this project
The main goal is to have a fully reprodicible home server build with, more or less, a simple command. E.g.
`make it so`. The setup is meant to use to two components and to the furthest extent possible use very few
dependencies; this is to, hopefully, futureproof the project a bit more. Mainly `ansible` and `terraform`
will be used, where the former finds and sets up all entities created by the latter. 

## How to run
Currently the project is setup by running: `ansible-playbook -i inventory deploy_infra.yaml`.

## Obstacles
The above setup is currently not working -- terraform does not run the Ansible command required.

