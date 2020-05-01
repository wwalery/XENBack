#!/bin/sh
cpan Carton
carton install --deployment
INSTALL_DIR=/opt/XENBack
CONF_DIR=/etc/xenback

mkdir $INSTALL_DIR
rsync -a -v * $INSTALL_DIR
cd $INSTALL_DIR

mkdir $CONF_DIR
rsync -a -v --ignore-existing ./etc/* $CONF_DIR
