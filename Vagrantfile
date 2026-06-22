# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Hadoop + Spark Cluster: 1 Master, 2 Workers
# NOTE: IPs must match the /etc/hosts block in bootstrap.sh

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", disabled: false

  # Define nodes. Master goes first to ensure NameNode/ResourceManager are up.
  nodes = [
    { name: "master",  ip: "192.168.56.10", memory: 4096, cpus: 2 },
    { name: "worker1", ip: "192.168.56.11", memory: 6144, cpus: 4 },
    { name: "worker2", ip: "192.168.56.12", memory: 6144, cpus: 4 },
  ]
  # Total allocated RAM: 16 GB (Leaves ~8 GB for the Mac host)

  nodes.each do |node|
    config.vm.define node[:name] do |m|
      m.vm.hostname = node[:name]
      m.vm.network "private_network", ip: node[:ip]

      # Forward Master UIs to Mac host
      if node[:name] == "master"
        m.vm.network "forwarded_port", guest: 8888,  host: 8888   # Jupyter
        m.vm.network "forwarded_port", guest: 9870,  host: 9870   # HDFS NameNode
        m.vm.network "forwarded_port", guest: 8088,  host: 8088   # YARN ResourceManager
        m.vm.network "forwarded_port", guest: 18080, host: 18080  # Spark History
      end

      m.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.memory = node[:memory]
        vb.cpus   = node[:cpus]
      end

      # Pass node role to bootstrap script
      m.vm.provision :shell, path: "bootstrap.sh", args: [node[:name]]
    end
  end
end