Vagrant.configure("2") do |config|
  config.vm.box = "generic/alpine310"
  config.vm.host_name = "k3s-local"
  config.vm.network "forwarded_port", guest: 6443, host: 6443
  config.vm.network "forwarded_port", guest: 443, host: 8443
  config.vm.network "forwarded_port", guest: 80, host: 8080
  config.vm.provider :libvirt do |domain|
    domain.cpus = 4
    domain.graphics_type = "spice"
    domain.memory = 2048
    domain.video_type = "qxl"
  end
  config.vm.provision "file", source: "./config", destination: "/tmp/config"
  config.vm.provision "shell", path: "./provision.sh"

  config.vm.synced_folder "./kubeconfig", "/root/kubeconfig", type: "sshfs" #, sshfs_opts_append: "-o nonempty"

  if Vagrant.has_plugin?("vagrant-timezone")
    config.timezone.value = :host
  end
end
