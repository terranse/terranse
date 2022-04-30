# This is a start of something new

The aim being that everything is solved with ansible and terraform in the end:
 - Terraform will be the setup of all hosts, VMs and (host-based) containers, while...
 - Ansible will setup each machine correctly, e.g., with Docker containers from compose

The end goal is for a new user to run a single command and, given available hardware,
to get a fully operational server in no time.
Additionally, the end goal is for this whole setup to be quite extensible. If you'd rather
have it all setup on with a cloud provider, then there should be a way to specify that
