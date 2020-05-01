#!/usr/bin/perl -w

# XENBack by Walery Wysotsky
# built on XenBackup-ng by Riccardo Bicelli
# built on "XEN Server backup by Filippo Zanardo - http://pipposan.wordpress.com"

# Usage: "perl xenback.pl <job name>", where job name is the name of the job file located in subfolder "jobs", without ".conf" suffix.
#

use strict;
use warnings;


# use Data::Dump qw(dump);
use Log::Log4perl;
use Log::Log4perl::Level;
use Number::Format qw(:subs);
use POSIX 'strftime';


use constant {
 false => 0,
 true  => 1,
 check => 2,
 internal => 3,
 VERSION => "2.0.0",
 BASE_DIR => "/etc/xenback"
};

my %backupType = (
 "full" => "Full Backup",
 "part" => "Selected Backup",
 "tag" => "Backup by tag"
);

# sub getRemovableDevices;


# local variables
my $log;
my $status;
my $fdate;


#Load config File
BEGIN {
#Load Default Config File
 my $conf_name = BASE_DIR . "/xenback.conf";
 if ( -e $conf_name ) {
  require $conf_name;
 } else {
  die "Configuration file [$conf_name] not found\n";
 }
}

BEGIN {

 Log::Log4perl::init(\$config{LOG_CONF});
#my $log_level = Log::Log4perl::Level::to_priority($LOG_LEVEL);
#Log::Log4perl::easy_init( { level => $log_level,
#                            file  => $LOG_FILE } );
 $log =  Log::Log4perl::get_logger();

#Load Job File
 my $job_name = BASE_DIR . '/' . $ARGV[0] . '.job';
 if ( -e $job_name ) {
  require $job_name;
  $log->info("Use job $job_name");
 } else {
  die "Job file [$job_name] not found\n";
 }
}


my @removableDevices = getRemovableDevices();
my %vmListAll = getAllVM();

my %vmListSelected = ();    #Hash to store VM to save



#Init Some variables
my $hostname = `hostname`;
$hostname =~ s/\r|\n//g;

my $gstarttime = time;





$log->info("Beginning backup on $hostname, job: [$job{jobName}]");

$b = substr($config{backupdir}, 0, -1);

# Mount Backup Media
if ( $config{Automount} eq true ) {
 my $ismounted = `mount |grep $b`;
 if ( $ismounted eq "" ) {
  my $mount = executeCommand($config{MountCommand});
 } else {
  log->info("Not Mounting, backup dir already mounted\n");
 }
}

# Check Space: check prior size of the VM, then check the space of the backup media.
if ( $config{checkspace} eq true ) {
 my $actualspace = `df -B M | grep $b`;

 my @spaceman = split( ' ', $actualspace );
 my $i = 0;
 my $aspace = 0;
 foreach my $val (@spaceman) {
  if ( $val eq $b ) {
   my $k = $i - 2;
   $aspace = $spaceman[$k];
   $aspace = substr( $aspace, 0, -1 );
  }
  $i += 1;
 }

 if ( $aspace <= $config{spacerequired} ) {
  my $err = "Backup Error: No space avaiable for the backup (actual: $aspace, required: $config{spacerequired})";
  $log->error($err);

# umount backup media
  if ( $config{Automount} eq true ) {
   my $mount = executeCommand($config{UMountCommand});
  }

  if ( $config{mailNotification} eq true ) {
   sendLogMail();
  }

  $log->logdie($err);
 }
}



$log->info("$backupType{$job{type}} selected");


# backup host configuration and software
$fdate = `date +%y%m%d-%H%M`;
chomp($fdate);
if ($job{backupHost} eq true) {
 $log->info("backup host configuration and software");
 my @uuid = parseUUID(executeCommand("xe host-list --minimal"));
 foreach my $host (@uuid) {
  my $hostName = executeCommand("xe host-param-get uuid=$host param-name=name-label");
  chomp($hostName);
  $status = executeCommand("xe host-backup uuid=$host file-name=$config{backupdir}$hostName-$fdate.dump");
  $log->warn("$status") if (length($status) gt 0);
 }
}

# backup pool dump database
if ($job{backupPool} eq true) {
 $log->info("backup pool dump database");
 $status = executeCommand("xe pool-dump-database file-name=$config{backupdir}$config{host}-$fdate.pool");
 if (length($status) gt 0) { 
  $log->warn("$status");
 } else {
  cutOldFiles($config{backupdir}, "$config{host}*.pool");
 }
}


# Backup selection

BACKUP_TYPE: {
   $job{type} eq "full" && do {
    while (my ($VMName, $guest) = each(%vmListAll)) { #Populate the array of guests to backup
     if ( grep {$_ eq $VMName} @{$job{Selected}} ) {    #Skip VM in selection
      $log->info("Skipping backup of: $VMName ($guest->{uuid})");
     } else {
      $vmListSelected{$VMName} = $guest;
     }
    }
    last BACKUP_TYPE;
   };
   $job{type} eq "part" && do {
    while (my ($VMName, $guest) = each(%vmListAll)) { #Cycle Selection of VM to backup
     if ( grep $_ eq $VMName, @{$job{Selected}} )	{    #If guest exists in pool then add it to array of UUIDs to backup
      $log->debug("Select $VMName");
      $vmListSelected{$VMName} = $guest;
     }
    }
    last BACKUP_TYPE;
   };
   $job{type} eq "tag" && do {
    foreach my $tagName (@{$job{Selected}}) {
     my @uuid = parseUUID(executeCommand("xe vm-list tags=XENBack:$tagName --minimal"));
     while (my ($VMName, $guest) = each(%vmListAll)) { #Cycle Selection of VM to backup
      if ( grep $_ eq $guest->{uuid}, @uuid )	{    #If guest exists in pool then add it to array of UUIDs to backup
       $log->debug("Select for tag backup $VMName");
       $vmListSelected{$VMName} = $guest;
      }
     }
    }
    last BACKUP_TYPE;
   };
   do {
    $log->logdie("Undefined job type: $job{type}")
   }
}

my $mailString = "";

# backup
while (my ($VMName, $guest) = each(%vmListSelected)) {

 $guest->{start} = time;
 $guest->{startf} = strftime('%d-%b-%Y %H:%M:%S', localtime);


 my $exportstring;
 my $finalname;
 my $versiondir;
 my $snapshotUUID;

 $log->info("Beginning backup of $VMName: $guest->{uuid}");

 my $useSnap = $config{useSnap};
 $useSnap = $job{useSnap} if exists $job{useSnap};

 if (@removableDevices) {
  detachRemovableDevices($guest, \@removableDevices);
 }



SNAPSHOT:
 if (($useSnap eq true) || ($useSnap eq check))  {

  #Begin Of Snapshot Backup

  my $SnapResult = 1;
  my $command;
  my $usequiesce = $config{usequiesce};


QUISCE:
  if ($usequiesce eq true) {

# Try Quiesce First
   $log->info("Taking a snapshot of: $guest->{uuid} of the vm: $VMName with quiesce");
   $snapshotUUID = executeCommand("xe vm-snapshot-with-quiesce vm=$guest->{uuid} new-name-label=$VMName-backup_vm --minimal");
   if ($? > 0) {
#If snapshot failed try with normal method
    $log->warn("Quiesce snapshot failed, doing the normal way...");
    $usequiesce = false;
    goto QUISCE;
   }
  } else {
   $log->info("Taking a snapshot of: $guest->{uuid} of the vm: $VMName");
   $snapshotUUID = executeCommand("xe vm-snapshot vm=$guest->{uuid} new-name-label=$VMName-backup_vm --minimal");    #Snapshot the VM
  }
  my $snapResult = $?;

  if ( $snapResult eq 0 ) {
   chomp($snapshotUUID);
   $log->info("Snapshot: $snapshotUUID created.");
   $log->info("Turning: $snapshotUUID snapshot into a vm");
   
   $log->info("Exporting VM: $snapshotUUID");    #export the snapshot
   $status = executeCommand("xe template-param-set is-a-template=false ha-always-run=false uuid=$snapshotUUID");
   $useSnap = true;
#End Of Snapshot Mode
  } else {
   $log->warn("Snapshot failed!");
   if ($useSnap eq check)  {
    $useSnap = false;
    goto SNAPSHOT;
   }
  }
  $guest->{backupMode} = "Snapshot";
  if ( $config{usequiesce} eq true ) {
   $guest->{backupMode} = "Snapshot/Quiesce";
  }
 } else {
  if ($job{backupMeta} eq false) {
#Shutdown-Export mode selected
   $guest->{backupMode} = "Shutdown/Restart";

   if ( $guest->{state} eq "running" ) {
    $log->info("Shutting down $VMName");           #export the snapshot
    my $shut = executeCommand("xe vm-shutdown uuid=$guest->{uuid}");
   }
  }
 }

 if ( $config{subfolder} eq true ) {    #create folder structure
  if ( ! -d $config{backupdir} . $VMName ) {
   mkdir( $config{backupdir} . $VMName, 0777 );
  }
  $versiondir = $config{backupdir} . $VMName . "/";
 } else {
  $versiondir   = $config{backupdir};
 }
 $fdate = `date +%y%m%d-%H%M`;
 chomp($fdate);
 $exportstring = $versiondir . $VMName . "-" . $fdate . ".xvatmp";
 $finalname  = $versiondir . $VMName . "-" . $fdate . ".xva";

 $log->info("Exporting VM: $exportstring -> $finalname");

 my $xeCompress;
 if ($config{compress} eq internal) {
  $xeCompress="compress=true";
 } else {
  $xeCompress="compress=false";
 }

 my $vmMeta;
 if ($job{backupMeta} eq true) {
  $vmMeta="metadata=true";
 } else {
  $vmMeta="";
 }
 
 if ( $useSnap eq true ) {
  $status = executeCommand("xe vm-export vm=$snapshotUUID $xeCompress $vmMeta filename=$exportstring");
 } else {
  $status = executeCommand("xe vm-export uuid=$guest->{uuid} $xeCompress $vmMeta filename=$exportstring");
 }

 $guest->{export_status} = $status;
 $log->info("Renaming backup file");

 $status = executeCommand("mv -vf $exportstring $finalname");

 if ( $config{compress} eq true ) {
  my $compressName;

#Compress backup
  if ( substr( $config{compressext}, 0, 1 ) eq "." ) {
   $compressName = "$finalname$config{compressext}";
  } else {
   $compressName = "$finalname.$config{compressext}";
  }

  $status = executeCommand("$config{compresscmd} $compressName $finalname");

  $status = executeCommand("rm -f $finalname");
  $finalname = $compressName; 
 }

 if ($config{fake}) {
  `/bin/touch $finalname`;
 }

 $guest->{size} = format_bytes((stat($finalname))[7]);
 
 if ($useSnap eq true) {

#Uninstall Snapshot
  $status = executeCommand("xe vm-uninstall uuid=$snapshotUUID  force=true");
  if ($? eq 0) {
   $log->info("Done, Snapshot removed: $snapshotUUID");
  } else {
   $log->warn("Unable to remove Snapshot: $snapshotUUID");
  }
 } else {
  if (($guest->{state} eq "running") && ($job{backupMeta} eq false)) {
   $log->info("Restarting VM: $VMName");
   $status = executeCommand("xe vm-start uuid=$guest->{uuid}");
   $log->debug("$status");
  }
 }
 if ($config{removable} eq true ) {
  reattachRemovableDevices($guest);
 }


# Save MAC addresses
 if ($job{saveMAC} eq true) {
  my @vifList = parseUUID(executeCommand("xe vif-list vm-uuid=$guest->{uuid} --minimal"));
  open(VIF,">$versiondir$VMName-MAC.lst");
  foreach my $vif (@vifList) {
   my $device = executeCommand("xe vif-param-get uuid=$vif param-name=device");
   chomp($device);
   my $MAC = executeCommand("xe vif-param-get uuid=$vif param-name=MAC");
   chomp($MAC);
   print(VIF "$device,$MAC\n");
  }
  close(VIF);
 }



 if ( -e $finalname ) {
  cutOldFiles($versiondir, '*');
  $guest->{stop} = time;
  $guest->{stopf} = strftime('%d-%b-%Y %H:%M:%S', localtime);
  my $tm;
  {
   use integer;
   my $sec;
   $sec    = $guest->{stop} - $guest->{start};
   $tm     = sprintf("%u:%02u:%02u",$sec/(60*60),($sec/60)%60,$sec%60);
  }
  $log->info("Completed backup of $VMName elapsed: $tm");
 } else {
  $log->warn("Backup Error: No backup file found");
 }
}

if ( $config{Automount} eq true ) {
 my $mount = executeCommand($config{UMountCommand});
}

my $gfinishtime = time;
# my $gminutes    = ($gfinishtime - $gstarttime) / 60;

my $endt = strftime("%d/%m/%Y %H:%M:%S", localtime);
$log->info("Backup completed at $endt");

#Init mail File

if ( $config{mailNotification} eq true ) {
 sendLogMail();
}

################################################################################################
# 				Functions/Sub Library
################################################################################################

sub getRemovableDevices {
 my @result;
 foreach my $rtype (@{$config{removable}}) {
  my @srlist = parseUUID(executeCommand("xe sr-list type=$rtype --minimal"));
  foreach my $sr (@srlist) {
   my @vdilist = parseUUID(executeCommand("xe vdi-list sr-uuid=$sr --minimal"));
   push(@result,@vdilist);
  }
 }
 return @result;
}

sub detachRemovableDevices {
 my $guest = shift;
 my $devices = shift;
# dump($devices);

 $log->info("Detaching removable devices");
 $guest->{'toreattach'} = ();
 
# get all devices for VM 
 my $cmd = executeCommand("xe vbd-list vm-uuid=$guest->{uuid} params=uuid,vdi-uuid,device");
 my @lineList =	split( /\n\n/, $cmd );
 foreach my $line (@lineList) {
  $line =~ /uuid.+?: (.+?)\n.*?vdi-uuid.+?: (.+?)\n.*?device.+?: (.*)/;
  my ($uuid,$vdi,$device) = ($1,$2,$3);
  if ( grep { $_ eq $vdi} @{$devices} ) {    
# Removable device, remove it
   $log->debug("unplug $vdi & $device as removable for vm: $guest->{uuid}");
   $guest->{'toreattach'}->{$vdi} = $device;
   my $unplug = executeCommand("xe vbd-unplug uuid=$uuid");
   my $dest   = executeCommand("xe vbd-destroy uuid=$uuid");
  }
 }
}

sub reattachRemovableDevices {
 my $guest = shift; 
 if ($guest->{'toreattach'}) {
  $log->info("Reattaching removable devices");
  my $i = 0;
  while (my ($uuid, $disk) = each(%{$guest->{'toreattach'}})) {
   $log->debug("attach $uuid as $disk to vm: $guest->{uuid}");
   my $create = executeCommand("xe vbd-create vm-uuid=$guest->{uuid} vdi-uuid=$uuid device=$disk --minimal");
   my $plug = executeCommand("xe vbd-plug uuid=$create");
   $i += 1;
  }
 }
}

sub sendLogMail {

 open( F_MAIL, ">", "/tmp/emailmsg" );
 print F_MAIL "To:$config{MailTo}\n";
 print F_MAIL "From:$config{MailFrom}\n";
 print F_MAIL "Subject: [$config{host} XEN Server Backup Script] [$job{jobName}]\n";
 print F_MAIL "Content-Type: multipart/mixed;boundary=safebounder001\n";
 print F_MAIL "\n";
 print F_MAIL "\n--safebounder001\n";
 print F_MAIL "Content-type: text/html;charset=utf-8\n\n";
 print F_MAIL "<html><body><table border=\"0\"><tr>";
 print F_MAIL "<tr><td>&nbsp;</td></tr>";
 print F_MAIL "<tr><td>Host name: <b>$hostname</b></td></tr>";
 print F_MAIL "<tr><td>Job Name: <b>$job{jobName}</b></td></tr>";
 print F_MAIL "<tr><td>&nbsp;</td></tr>";
 print F_MAIL "<tr><td><h2>Job Details</h2></td></tr>";
 print F_MAIL "</table>";
 print F_MAIL "<table border=\"1\"><tr>";
 print F_MAIL "<th>Name</th>";
 print F_MAIL "<th>Mode</th>";
 print F_MAIL "<th>Status</th>";
 print F_MAIL "<th>Elapsed Time</th>";
 print F_MAIL "<th>Exported size</th>";
 print F_MAIL "<th>Start time</th>";
 print F_MAIL "<th>End time</th>";
 print F_MAIL "</tr>";
 
 while (my ($VMName, $guest) = each(%vmListSelected)) {
  my $color;
  if ($guest->{export_status} ne 'Export succeeded') {
   $color = ' bgcolor="#81F7BE"';
  } else {
   $color = ' bgcolor="#F78181"';
  }
  print F_MAIL "<tr $color>";
  print F_MAIL "<td>$VMName</td>";
  print F_MAIL "<td>$guest->{backupMode}</td>";
  print F_MAIL "<td>$guest->{export_status}</td>";
  my $sec = $guest->{stop} - $guest->{start};
  my $tm  = sprintf("%u:%02u:%02u",$sec/(60*60),($sec/60)%60,$sec%60);

  print F_MAIL "<td align=\"right\">$tm</td>";
  print F_MAIL "<td align=\"right\">$guest->{size}</td>";
  print F_MAIL "<td align=\"right\">$guest->{startf}</td>";
  print F_MAIL "<td align=\"right\">$guest->{stopf}</td>";
  print F_MAIL "</tr>";
 }
 print F_MAIL "</table></html>";
 close F_MAIL;
 my $send = executeCommand("/usr/sbin/ssmtp $config{MailTo} </tmp/emailmsg");
 $log->debug($send);
}

sub cutOldFiles {
 my ($versiondir, $mask) = @_;
 $log->info("cut old files in $versiondir, method = $config{delmethod}");
 if ( $config{versioning} eq true ) {
  my @files = <$versiondir/$mask>;
# 	    logLine("list all files = @files");
# Switch.pm is buggy - it can't work in subroutine
  if ($config{delmethod} eq "numbers") {
   @files = sort { -M $a < -M $b } @files;
   @files = @files[-$config{delnumber}];
  } elsif ($config{delmethod} eq "hours") {
   @files = grep { -M $_ > ($config{delnumber} / 24) } @files;
  } elsif ($config{delmethod} eq "days") {
   @files = grep { -M $_ > $config{delnumber} } @files;
  } else {
   log->error("Backup Error: Unknown delete method: $config{delmethod}");
   return;
  }
  foreach my $file (@files) {
    $log->info("Deleting file: " . $file);
    if (!$config{fake}) {
     unlink($file);
    }
  }
 }
}


sub getAllVM { 
 my $vmlist = `xe vm-list params=uuid,name-label,power-state is-control-domain=false is-a-snapshot=false`;    # Get the formatted list of guests, without control domain
 my @lineList =	split( /\n\n/, $vmlist );     # Split the list of guests into and array of VM
 my %result = ();                # Hash to store uuid's and names in
 foreach my $line (@lineList) {
  $line =~ /uuid.+?: (.+?)\n.*?name-label.+?: (.+?)\n.*?power-state.+?: (.*)/;
  $result{$2} = {uuid => $1, state => $3};
 }
 return %result;
}

sub executeCommand {
 my ($command) = @_;
 my $result;
 $log->debug("Executing: $command");
 if ($config{fake}) {
  $log->info($command);
  $result = "undef";
 } else {
  $result = `$command`;
 }
 $log->debug("command return: $result");
 return $result;
}

sub trim {
 my $string = shift;
 $string =~ s/^\s+//;
 $string =~ s/\s+$//;
 return $string;
}

sub parseUUID {
 my $cmd = shift;
 chomp($cmd);
 my @uuid;
 if ($cmd) {
  @uuid = split(/,/, $cmd);
 }
 return @uuid;
}


