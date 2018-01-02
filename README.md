atomic-builder project provides a Vagrant based environment for Atomic OSTree
repo compose and image build with imagefactory.

It is inspired by https://github.com/jasonbrooks/byo-atomic with major overhaul
to the toolstack.

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
