#!/bin/sh
cd /opt/XENBack
carton exec -- /usr/bin/perl xenback.pl tag &> backup.log
