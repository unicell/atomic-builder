#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

working_dir="$HOME/working"

# base distro and version
# to switch to Fedora, use "fedora" and "f26" respectively
BASE_DISTRO=${BASE_DISTRO:-"centos"}
DISTRO_VERSION=${DISTRO_VERSION:-"downstream"}

# dnf / yum wrapper
DNF_YUM=${DNF_YUM:-"dnf"}

install_rclone() {
    # rclone
    mkdir -p ~/bin
    curl -LO https://github.com/ncw/rclone/releases/download/v1.36/rclone-v1.36-linux-amd64.zip
    unzip rclone-v1.36-linux-amd64.zip
    mv rclone-v1.36-linux-amd64/rclone ~/bin/

    # swift
    sudo ${DNF_YUM} install -y python2-swiftclient
}

install_dependencies() {
    # install package dependencies
    sudo ${DNF_YUM} update -y
    sudo ${DNF_YUM} install -y rpm-ostree imagefactory imagefactory-plugins lorax pykickstart
    sudo ${DNF_YUM} install -y git docker libvirt createrepo wget tig unzip vim

    # latest version from copr
    sudo ${DNF_YUM} copr enable -y jasonbrooks/rpm-ostree-toolbox
    sudo ${DNF_YUM} --enablerepo="jasonbrooks-rpm-ostree-toolbox" install -y "rpm-ostree-toolbox"

    # tune oz
    sudo sed -i -e 's/# memory = 1024/memory = 3072/g' /etc/oz/oz.cfg
    sudo sed -i -e 's/safe_generation = no/safe_generation = yes/g' /etc/oz/oz.cfg

    # turn on libvirt
    sudo systemctl enable libvirtd
    sudo systemctl start libvirtd
    sudo systemctl start virtlogd 

    # prep docker
    sudo sed -i "s/^DOCKER_STORAGE_OPTIONS.*/DOCKER_STORAGE_OPTIONS=\"-s overlay\"/g" /etc/sysconfig/docker-storage
    sudo sed -i "s/--selinux-enabled//g" /etc/sysconfig/docker
    sudo sed -i "s/^# setsebool -P docker_transition_unconfined 1/setsebool -P docker_transition_unconfined 1/g" /etc/sysconfig/docker
    sudo systemctl enable docker --now
}

install_http_service() {
    # SimpleHTTPServer to host local bits
    # (from https://gist.github.com/funzoneq/737cd5316e525c388d51877fb7f542de)
    sudo tee -a /etc/systemd/system/simplehttp.service <<'EOF'
[Unit]
Description=Job that runs the python SimpleHTTPServer daemon
Documentation=man:SimpleHTTPServer(1)

[Service]
Type=simple
WorkingDirectory=
ExecStart=/usr/bin/python -m SimpleHTTPServer 8000 &
ExecStop=/bin/kill `/bin/ps aux | /bin/grep SimpleHTTPServer | /bin/grep -v grep | /usr/bin/awk '{ print $2 }'`
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    sudo sed -i "s#^WorkingDirectory.*#WorkingDirectory=${working_dir}/build#g" /etc/systemd/system/simplehttp.service
    sudo systemctl enable simplehttp --now
}

install_installers() {
    # mirror installer
    mkdir -p ${working_dir}/build/installer/images/images/pxeboot

    if [ $BASE_DISTRO = "centos" ]; then
      wget -P ${working_dir}/build/installer/images/images/pxeboot/ -r -nH -nd -nc -np -e robots=off -R index.html* https://ci.centos.org/artifacts/sig-atomic/downstream/installer/images/images/pxeboot/
      wget -P ${working_dir}/build/installer/images/LiveOS/ -r -nH -nd -nc -np -e robots=off -R index.html* https://ci.centos.org/artifacts/sig-atomic/downstream/installer/images/LiveOS/
      wget -P ${working_dir}/build/installer/images/ https://ci.centos.org/artifacts/sig-atomic/downstream//installer/images/.treeinfo
    elif [ $BASE_DISTRO = "fedora" ]; then
      wget -P ${working_dir}/build/installer/images/images/pxeboot/ -r -nH -nd -nc -np -R index.html* http://dl.fedoraproject.org/pub/fedora/linux/releases/${DISTRO_VERSION:1}/Everything/x86_64/os/images/pxeboot/
      wget -nc -P ${working_dir}/build/installer/images/images/ http://dl.fedoraproject.org/pub/fedora/linux/releases/${DISTRO_VERSION:1}/Everything/x86_64/os/images/install.img
      wget -nc -P ${working_dir}/build/installer/images/images/ http://dl.fedoraproject.org/pub/fedora/linux/releases/${DISTRO_VERSION:1}/Everything/x86_64/os/images/boot.iso
      # dev version
      #wget -P ${working_dir}/build/installer/images/images/pxeboot/ -r -nH -nd -nc -np -R index.html* http://dl.fedoraproject.org/pub/fedora/linux/development/${DISTRO_VERSION:1}/Everything/x86_64/os/images/pxeboot/
      #wget -nc -P ${working_dir}/build/installer/images/images/ http://dl.fedoraproject.org/pub/fedora/linux/development/${DISTRO_VERSION:1}/Everything/x86_64/os/images/install.img
    fi
}

install_repos() {
    if [ $BASE_DISTRO = "centos" ]; then
      metadata_repo="https://github.com/CentOS/sig-atomic-buildscripts.git"
    elif [ $BASE_DISTRO = "fedora" ]; then
      metadata_repo="https://pagure.io/fedora-atomic.git"
    fi

    if [ $BASE_DISTRO = "centos" ]; then
      kickstart_repo="https://github.com/CentOS/sig-atomic-buildscripts.git"
    elif [ $BASE_DISTRO = "fedora" ]; then
      kickstart_repo="https://pagure.io/fedora-kickstarts.git"
    fi

    # get atomic host metadata and kickstarts
    mkdir -p $working_dir
    cd $working_dir
    git clone -b $DISTRO_VERSION $metadata_repo metadata
    git clone -b $DISTRO_VERSION $kickstart_repo kickstarts
}

# depends on install_repos
prep_repos() {
    # initialize ostree repo
    sudo mkdir -p /srv/repo
    sudo ostree --repo=/srv/repo init --mode=archive-z2

    # mirror ostree repo
    if [ $BASE_DISTRO = "centos" ]; then
      sudo ostree remote add --repo=/srv/repo centos-atomic-host --set=gpg-verify=false http://mirror.centos.org/centos/7/atomic/x86_64/repo
      sudo ostree pull --depth=0 --repo=/srv/repo --mirror centos-atomic-host centos-atomic-host/7/x86_64/standard
    elif [ $BASE_DISTRO = "fedora" ]; then
      sudo ostree remote add --repo=/srv/repo fedora-atomic --set=gpg-verify=false https://kojipkgs.fedoraproject.org/atomic/${DISTRO_VERSION:1}/
      sudo ostree pull --depth=0 --repo=/srv/repo --mirror fedora-atomic fedora/${DISTRO_VERSION:1}/x86_64/atomic-host
    fi
}

prep_build() {
    mkdir -p $working_dir/build
    pushd $working_dir/build
    ln -s /srv/repo/ repo
    popd
}

# depends on install_repos
prep_scripts() {
    pushd $working_dir
    # use local repo
    #sed -i 's#http://.*#http://192.168.122.1:8000/installer/images/</url>#g' metadata/*.tdl
    sed -i 's#http://.*#https://ci.centos.org/artifacts/sig-atomic/downstream/installer/images/</url>#g' metadata/*.tdl
    sed -i 's#--url=.* #--url="http://192.168.122.1:8000/repo/" #g' kickstarts/*atomic*.ks

    # fedora config.ini needs a tweak
    #if [ $BASE_DISTRO = "fedora" ]; then
      #sed -i "s#^release.*#release     = ${DISTRO_VERSION}#g" metadata/config.ini
      #sed -i "s#%(release)s#${DISTRO_VERSION:1}#g" metadata/config.ini
    #fi
    popd
}

setup() {
    install_dependencies
    install_http_service
    #install_installers
    install_repos

    prep_repos
    prep_build
    prep_scripts
}

build_vagrant_images() {
    pushd $working_dir
    sudo imagefactory --verbose base_image --file-parameter install_script kickstarts/centos-atomic-vagrant.ks metadata/atomic-7.1.tdl  --parameter offline_icicle true

    #sudo imagefactory --verbose target_image --id 95762804-ab21-4799-8eef-7ca934e2f95c vsphere
    #sudo imagefactory --verbose target_image --parameter vsphere_ova_format vagrant-virtualbox --id 7378fb87-30ee-46f7-a299-bb431977bece ova

    #sudo imagefactory --verbose target_image --id 95762804-ab21-4799-8eef-7ca934e2f95c rhevm
    #sudo imagefactory --verbose target_image --parameter rhevm_ova_format vagrant-libvirt --id 7630af20-5350-4c54-a0bb-a533fb1bceea ova
    popd
}

tree() {
echo "composing tree"
sudo rpm-ostree compose tree --repo=/srv/repo ${working_dir}/metadata/*-host.json
}

build_installer() {
    echo "building installer"
    sudo rpm-ostree-toolbox installer --overwrite --ostreerepo ${working_dir}/build/repo -c ${working_dir}/metadata/config.ini -o ${working_dir}/build/installer
}

"$@"
