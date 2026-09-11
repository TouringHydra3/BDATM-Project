# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", disabled: false
  config.vm.boot_timeout = 600
  config.ssh.insert_key  = false

  nodes = [
    { name: "master", ip: "192.168.56.10", memory: 2560,  cpus: 2, ssh_port: 2222 },
    { name: "worker", ip: "192.168.56.11", memory: 13312, cpus: 6, ssh_port: 2223 },
  ]

  nodes.each do |node|
    config.vm.define node[:name] do |m|
      m.vm.hostname = node[:name]
      m.vm.network "private_network", ip: node[:ip]
      m.vm.network "forwarded_port", guest: 22, host: node[:ssh_port], id: "ssh"

      if node[:name] == "master"
        m.vm.network "forwarded_port", guest: 8888, host: 8888  # Jupyter
        m.vm.network "forwarded_port", guest: 9870, host: 9870  # HDFS NameNode
        m.vm.network "forwarded_port", guest: 8088, host: 8088  # YARN ResourceManager
        m.vm.network "forwarded_port", guest: 4040, host: 4040  # Spark Live UI
      end

      m.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.memory = node[:memory]
        vb.cpus   = node[:cpus]
      end

      m.vm.provision :shell, path: "bootstrap.sh", args: [node[:name]]
    end
  end
end
