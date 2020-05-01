# XENBack

Citrix Xenserver Guests Virtual Machines backup. 
Different way configuration, jobs, logging, email report in html etc.

Features:
  * detect removable disk
  * full backup
  * selected backup
  * backup by tag
  * email report in html
  * snapshot backup
  * full export backup with keeping running state
  * backup versioning

built on XenBackup-ng by Riccardo Bicelli
built on "XEN Server backup by Filippo Zanardo - http://pipposan.wordpress.com"

Usage: "carton exec -- perl xenback.pl <job name>", where job name is the name of the job file located in subfolder "jobs", without ".conf" suffix.


## Installation

  1. Run installation script (install perl packages, install application to /opt/XENBack and configurations to /etc/xenback )
`sh ./install.sh`
  1. Set up /etc/xenback/xenback.conf
  1. Create jobs for backup in /etc/xenback/

