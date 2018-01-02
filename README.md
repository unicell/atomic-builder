atomic-builder project provides a Vagrant based environment for Atomic OSTree
repo compose and image build with imagefactory.

It is inspired by / built on https://github.com/jasonbrooks/byo-atomic with
major overhaul to the toolstack.

Tested
======

Vagrant: 1.9.7
VirtualBox: 5.1.18

HOWTOs
======

Steps
-----

    ```sh
    vagrant up
    vagrant ssh
    $ ./atomic-build.sh setup
    $ ./atomic-build.sh images
    ```

Release (using rclone and swift)
--------------------------------

Rclone Config (1st time):

    ```sh
    # ~/.config/rclone/rclone.conf

    [local]
    type = local
    nounc = true

    [cicd]
    type = swift
    user = <redacted>
    key = <redacted>
    auth = https://<keystone endpoint reacted>
    domain =
    tenant = <reacted>
    tenant_domain =
    region = <reacted>
    storage_url =
    auth_version =
    ```

Build and Publish image to Swift:

    ```sh
    vagrant ssh
    $ ./atomic-builder.sh release <version>
    $ for f in $(ls releases/*-<version>.*); do rclone copy local:$f cicd:release/; done
    ```

Update Box metadata to Swift:

    ```sh
    vagrant ssh
    # pull current metadata file
    rclone sync cicd:www/ local:www/
    cd www
    # make changes
    # use `swift` to workaround the rclone bug overwriting Content-Type metadata
    swift upload www vagrant
    ```
