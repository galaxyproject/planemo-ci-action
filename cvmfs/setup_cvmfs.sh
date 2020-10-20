#!/bin/bash
set -x

cd "${BASH_SOURCE%/*}/" || exit

sudo apt install lsb-release
wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
sudo dpkg -i cvmfs-release-latest_all.deb
sudo apt-get update
sudo apt install cvmfs cvmfs-config

sudo cp default.local  /etc/cvmfs/default.local
sudo cp galaxyproject.org.conf  /etc/cvmfs/domain.d/galaxyproject.org.conf
sudo cp ./*.galaxyproject.org.pub /etc/cvmfs/keys/
sudo mkdir -p /cvmfs/main.galaxyproject.org
sudo mkdir -p /cvmfs/data.galaxyproject.org
sudo mount -t cvmfs main.galaxyproject.org /cvmfs/main.galaxyproject.org
sudo mount -t cvmfs data.galaxyproject.org /cvmfs/data.galaxyproject.org
