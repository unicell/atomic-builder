Vagrant.configure(2) do |config|

  config.vm.box = "fedora/27-cloud-base"

  config.vm.provider "virtualbox" do |vb, override|
    vb.cpus = 4
    vb.memory = 8192
  end

  config.vm.synced_folder ".", "/vagrant", type: "rsync", disabled: true

  config.vm.provision "file",
    source: "atomic-build.sh", destination: "atomic-build.sh"

  config.vm.provision "shell",
    inline: "sed -i 's#^working_dir=.*#working_dir=\"/home/vagrant/working\"#g' atomic-build.sh"

end
