# test-net
`test-net` is a basic CNI networking plugin for Kubernetes on Linux, created for my final project in CPSC 434: Topics in Networked Systems. The plugin provides basic Kubernetes networking functionality, as required by the Kubernetes networking model, using a VXLAN overlay network. In particular, this allows for cloud-provider-agnostic networking (i.e. no need to rely on a specific cloud provider's routing tools).

## Usage

On each node in the cluster, run `setup.bash` as root (from any directory), after ensuring that `kubectl` is properly configured on the node.
Then, on each node in the cluster, move `test-net.bash` to `/opt/cni/bin/test-net.bash`, and move `10-test-net-plugin.conf` to `/etc/cni/net.d/10-test-net-plugin.conf`. Once this is done, the plugin will be installed, and you can use Kubernetes networking features as desired.

## Credits

This project made ample use of two great tutorials on Kubernetes networking: [one by Kevin Sookocheff](https://sookocheff.com/post/kubernetes/understanding-kubernetes-networking-model/) and [one by Siarhei Matsiukevich](https://www.altoros.com/blog/kubernetes-networking-writing-your-own-simple-cni-plug-in-with-bash/). In particular, the CNI script `test-net.bash` is similar to the script provided in the latter tutorial, although it was reimplemented from first principles, and its features were extended (dependence on hardcoded values replaced with values programmatically obtained from kubectl; removed `nmap` dependency).
