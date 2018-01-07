#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

working_dir="$HOME/working"

# base distro and version
# to switch to Fedora, use "fedora" and "f26" respectively
BASE_DISTRO=${BASE_DISTRO:-"centos"}
DISTRO_VERSION=${DISTRO_VERSION:-"downstream"}

TDL_FILE=${TDL_FILE:-"atomic-7.1.tdl"}
KS_FILE=${KS_FILE:-"centos-atomic-vagrant.ks"}

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

install_centos_dependencies() {
    sudo tee -a /etc/yum.repos.d/rhel-atomic-rebuild.repo <<'EOF'
[rhel-atomic-rebuild]
name=rhel-atomic-rebuild
baseurl=http://buildlogs.centos.org/centos/7/atomic/x86_64/Packages/
gpgcheck=0
exclude=systemd systemd-container systemd-container-libs systemd-libs
EOF
    sudo yum -y install ostree rpm-ostree glib2 docker libvirt epel-release libgsystem

    sudo tee -a /etc/yum.repos.d/atomic7-testing.repo <<'EOF'
[atomic7-testing]
name=atomic7-testing
baseurl=http://cbs.centos.org/repos/atomic7-testing/x86_64/os/
gpgcheck=0
enabled=0
EOF
    sudo yum --enablerepo=atomic7-testing -y install rpm-ostree-toolbox

    sudo yum install -y yum-plugin-copr
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

    # prep firewalld if any
    sudo systemctl stop firewalld || true

    # oz 0.16 hotfix
    # https://github.com/clalancette/oz/pull/248
    sudo sed -i -e 's/requests_session.post/requests_session.head/g' /usr/lib/python2.7/site-packages/oz/ozutil.py
}

run_http_service() {
    sudo docker kill ostree-webserver || true
    sudo docker rm ostree-webserver || true
    sudo docker run -d --name ostree-webserver -p 8000:80 -v ${working_dir}/build:/usr/local/apache2/htdocs/ -v /srv/repo:/srv/repo httpd:2.4
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

ensure_ostree_repo_modes() {
    # deal with https://bugzilla.gnome.org/show_bug.cgi?id=748959
    sudo chmod -R a+r /srv/repo/objects
    sudo find /srv/repo/ -type d -exec chmod -R a+x {} \;
    sudo find /srv/repo/ -type f -exec chmod -R a+r {} \;
}

# depends on install_repos
prep_ostree_repos() {
    # initialize ostree repo
    sudo mkdir -p /srv/repo
    sudo ostree --repo=/srv/repo init --mode=archive-z2

    # mirror ostree repo
    if [ $BASE_DISTRO = "centos" ]; then
      sudo ostree remote add --repo=/srv/repo centos-atomic-host --set=gpg-verify=false http://mirror.centos.org/centos/7/atomic/x86_64/repo
      sudo ostree pull --depth=1 --repo=/srv/repo --mirror centos-atomic-host centos-atomic-host/7/x86_64/standard
    elif [ $BASE_DISTRO = "fedora" ]; then
      sudo ostree remote add --repo=/srv/repo fedora-atomic --set=gpg-verify=false https://kojipkgs.fedoraproject.org/atomic/${DISTRO_VERSION:1}/
      sudo ostree pull --depth=1 --repo=/srv/repo --mirror fedora-atomic fedora/${DISTRO_VERSION:1}/x86_64/atomic-host
    fi

    ensure_ostree_repo_modes
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

    # hack repo url
    #sed -i 's#http://.*#https://ci.centos.org/artifacts/sig-atomic/downstream/installer/images/</url>#g' metadata/*.tdl
    #sed -i 's#--url=.* #--url="http://192.168.122.1:8000/repo/" #g' kickstarts/*atomic*.ks

    sed -i -e 's#</template>#    <disk>\n        <size>20G</size>\n    </disk>\n</template>#g' metadata/${TDL_FILE}

    # fedora config.ini needs a tweak
    #if [ $BASE_DISTRO = "fedora" ]; then
      #sed -i "s#^release.*#release     = ${DISTRO_VERSION}#g" metadata/config.ini
      #sed -i "s#%(release)s#${DISTRO_VERSION:1}#g" metadata/config.ini
    #fi
    popd
}

setup() {
    prep_build

    install_dependencies
    #install_installers
    install_repos

    run_http_service
    prep_ostree_repos

    prep_scripts
}

build_installer() {
    echo "building installer"
    sudo rpm-ostree-toolbox installer --overwrite --ostreerepo ${working_dir}/build/repo -c ${working_dir}/metadata/config.ini -o ${working_dir}/build/installer
}

build_vagrant_images_deprecated() {
    pushd $working_dir
    sudo rpm-ostree-toolbox imagefactory --overwrite --tdl ${working_dir}/metadata/atomic-7.1.tdl -c  ${working_dir}/metadata/config.ini -i kvm -i vagrant-libvirt -i vagrant-virtualbox -k ${working_dir}/kickstarts/centos-atomic.ks --vkickstart ${working_dir}/kickstarts/centos-atomic-vagrant.ks --ostreerepo http://192.168.122.1:8000/repo/ -o ${working_dir}/build/virt
    popd
}

build_vagrant_images() {
    pushd $working_dir

    # cleanup
    logfile=${working_dir}/build/log
    :> $logfile
    sudo rm /var/lib/imagefactory/storage/*

    # build base image
    sudo imagefactory --verbose base_image --file-parameter install_script ${working_dir}/kickstarts/${KS_FILE} ${working_dir}/metadata/${TDL_FILE} --parameter offline_icicle true |& tee ${logfile}

    result_line=$(tail -1 ${logfile})
    image_type=$(tail -5 ${logfile} | awk '/Type:/ {print $2}')
    if ! [[ $result_line =~ "SUCCESSFULLY" && $image_type == "base_image" ]]; then
        echo "Base image build failure!"
        exit 1
    fi

    # build target image for Vagrant Virtualbox
    base_uuid=$(tail -5 ${logfile} | awk '/UUID:/ {print $2}')
    sudo imagefactory --verbose target_image --id ${base_uuid} vsphere |& tee ${logfile}

    result_line=$(tail -1 ${logfile})
    image_type=$(tail -5 ${logfile} | awk '/Type:/ {print $2}')
    if ! [[ $result_line =~ "SUCCESSFULLY" && $image_type == "target_image" ]]; then
            echo "Vsphere target image build failure!"
            exit 1
    fi

    # package target image for Vagrant Virtualbox
    target_uuid=$(tail -5 ${logfile} | awk '/UUID:/ {print $2}')
    sudo imagefactory --verbose target_image --parameter vsphere_ova_format vagrant-virtualbox --id ${target_uuid} ova |& tee ${logfile}

    result_line=$(tail -1 ${logfile})
    image_type=$(tail -5 ${logfile} | awk '/Type:/ {print $2}')
    image_file=$(tail -5 ${logfile} | awk '/Image filename:/ {print $2}')
    if ! [[ $result_line =~ "SUCCESSFULLY" && $image_type == "target_image" ]]; then
            echo "Vagrant virtualbox target image build failure!"
            exit 1
    fi
    echo "${image_file} Ready!!"

        #sudo imagefactory --verbose target_image --id ${base_uuid} rhevm
        #sudo imagefactory --verbose target_image --parameter rhevm_ova_format vagrant-libvirt --id 7630af20-5350-4c54-a0bb-a533fb1bceea ova

    popd
}

build_fedora_vagrant_images() {
    pushd $working_dir
    sudo imagefactory --verbose base_image --file-parameter install_script kickstarts/${KS_FILE} metadata/${TDL_FILE} --parameter offline_icicle true

    #sudo imagefactory --verbose target_image --id 95762804-ab21-4799-8eef-7ca934e2f95c vsphere
    #sudo imagefactory --verbose target_image --parameter vsphere_ova_format vagrant-virtualbox --id 7378fb87-30ee-46f7-a299-bb431977bece ova

    #sudo imagefactory --verbose target_image --id 95762804-ab21-4799-8eef-7ca934e2f95c rhevm
    #sudo imagefactory --verbose target_image --parameter rhevm_ova_format vagrant-libvirt --id 7630af20-5350-4c54-a0bb-a533fb1bceea ova
    popd
}

images() {
    build_installer
    build_vagrant_images
}

tree() {
echo "composing tree"
sudo rpm-ostree compose tree --repo=/srv/repo ${working_dir}/metadata/*-host.json
}

"$@"
