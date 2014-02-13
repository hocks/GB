#!/usr/bin/perl -w
#          LLview - supervising LoadLeveler batch queue utilization 
#
#     ---- Perl API script for DB2 data base of a Blue Gene System ----
#
#   Copyright (C) 2005, Forschungszentrum Juelich GmbH, Federal Republic of
#   Germany. All rights reserved.
#
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions are met:
#
#   Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
#     - Redistributions of source code must retain the above copyright notice,
#       this list of conditions and the following disclaimer.
#
#     - Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#
#     - Any publications that result from the use of this software shall
#       reasonably refer to the Research Centre's development.
#
#     - All advertising materials mentioning features or use of this software
#       must display the following acknowledgement:
#
#           This product includes software developed by Forschungszentrum
#           Juelich GmbH, Federal Republic of Germany.
#
#     - Forschungszentrum Juelich GmbH is not obligated to provide the user with
#       any support, consulting, training or assistance of any kind with regard
#       to the use, operation and performance of this software or to provide
#       the user with any updates, revisions or new versions.
#
#
#   THIS SOFTWARE IS PROVIDED BY FORSCHUNGSZENTRUM JUELICH GMBH "AS IS" AND ANY
#   EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#   WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#   DISCLAIMED. IN NO EVENT SHALL FORSCHUNGSZENTRUM JUELICH GMBH BE LIABLE FOR
#   ANY SPECIAL, DIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER
#   RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF
#   CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
#   CONNECTION WITH THE ACCESS, USE OR PERFORMANCE OF THIS SOFTWARE.

use DBI;
use DBD::DB2::Constants;
use DBD::DB2;

use strict;

my $patint="([\\+\\-\\d]+)";   # Pattern for Integer number
my $patfp ="([\\+\\-\\d.E]+)"; # Pattern for Floating Point number
my $patwrd="([\^\\s]+)";       # Pattern for Work (all noblank characters)
my $patbl ="\\s+";             # Pattern for blank space (variable length)

#########################################################
# Configuration section
#########################################################

$ENV{DB2INSTANCE}="<instance>";
$ENV{DB2_PATH}="<path_todb2>";
$ENV{DB_PROPERTY}="<path_to_prop>/db.properties";


# access information for the DB2 data base
my $db_name='';
my $db_user='';
my $db_password='-';
my $db2searchfile="<path_to_file_containing_userid_and_password>";

if(-f $db2searchfile ) {
    my $line;
    open(IN,"$db2searchfile");
    while($line=<IN>) {
	if($line=~/db2 \'?connect to $patwrd user $patwrd using $patwrd\'?/) {
	    $db_name=$1;
	    $db_user=$2;
	    $db_password=$3;
	}
    }
}
if($db_password eq "-") {
    print STDERR "wrong passwd ... exiting\n";
    exit(0);
}

# some general information about the system which will be shown in llview 
my $system_name = "Blue/Gene";
my $system_mem  = "-";
my $system_cpucount  = "16384";
my $system_ghz  = "0.7";
my $system_cputype  = "PowerPC";
my $system_type  = "BG/L";
my $system_nodes  = "8";
my $system_gflops  = "-";
my $num_racks = 1;

#########################################################
# End of configuration section
#########################################################

my ($dbh, $sth, $stmt);
# debug: print all known data sources...
if ( 0 ) {
  print "DB2 data sources:\n";
  foreach ( DBI->data_sources('DB2') ) {
    print ">>  $_\n";
  }
}

my(%rack,%blocks,%failedmidplane,%failednc,%blockpos,%jobs,%block_inuse,%block_running,%node_classes, %blockidle);

my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$idst)=localtime(time());
$year=substr($year,1,2);
my $date=sprintf("%02d/%02d/%02d-%02d:%02d:%02d",$mon+1,$mday,$year,$hour,$min,$sec);


my %mmcs_block_status = (
			 'E' => 'Error : An initialization error occurred. An allocate, allocate_block or free command must be issued to reset the block.',
			 'F' => 'Free : The block is available to be allocated.',
			 'A' => 'Allocated : The block has been allocated by a user. iDo connections have been established, but the block has not been booted.',
			 'C' => 'Configuring : The block is in the process of being booted. This is an internal state for communicating between LoadLeveler and mmcs_db.',
			 'B' => 'Booting : The block is in the process of being booted, but has not yet reached the point that ciod has been contacted on all I/O Nodes.',
			 'I' => 'Initialized : The block is ready to run application programs. ciodb has contacted ciod on all I/O Nodes.',
			 'D' => 'Deallocating : The block is in the process of being freed. This is an internal state for communicating between LoadLeveler and mmcs_db.',
			 );

my %mmcs_job_status = (
		       'E' => 'Error : An initialization error occurred. The _errtext field contains the error message.',
		       'Q' => 'Queued : The job has been created in the bgljob database table, but has not been started yet.',
		       'S' => 'Start : The job has been released to start, but has not yet started running.',
		       'R' => 'Running : The job is running.',
		       'T' => 'Terminated : The job has ended.',
		       'D' => 'Dying : The job has been stopped but has not yet ended.',
		       );

my %mmcs_job_status_short = (
		       'E' => 'error',
		       'Q' => 'queued',
		       'S' => 'start',
		       'R' => 'running',
		       'T' => 'terminated',
		       'D' => 'dying',
		       );

my %J_to_N = (
	      "J02 " => "N0",
	      "J03 " => "N1",
	      "J04 " => "N2",
	      "J05 " => "N3",
	      "J06 " => "N4",
	      "J07 " => "N5",
	      "J08 " => "N6",
	      "J09 " => "N7",
	      "J10 " => "N8",
	      "J11 " => "N9",
	      "J12 " => "NA",
	      "J13 " => "NB",
	      "J14 " => "NC",
	      "J15 " => "ND",
	      "J16 " => "NE",
	      "J17 " => "NF",
	      "J102" => "N0",
	      "J104" => "N1",
	      "J106" => "N2",
	      "J108" => "N3",
	      "J111" => "N4",
	      "J113" => "N5",
	      "J115" => "N6",
	      "J117" => "N7",
	      "J203" => "N8",
	      "J205" => "N9",
	      "J207" => "NA",
	      "J209" => "NB",
	      "J210" => "NC",
	      "J212" => "ND",
	      "J214" => "NE",
	      "J216" => "NF"
	      );

my %undefined_J = (
	      "J02 " => "N0",
	      "J03 " => "N1",
	      "J04 " => "N2",
	      "J05 " => "N3",
	      "J06 " => "N4",
	      "J07 " => "N5",
	      "J08 " => "N6",
	      "J09 " => "N7",
	      "J10 " => "N8",
	      "J11 " => "N9",
	      "J12 " => "NA",
	      "J13 " => "NB",
	      "J14 " => "NC",
	      "J15 " => "ND",
	      "J16 " => "NE",
	      "J17 " => "NF"
	      );
#for $J (keys(%J_to_N)) {
#    $N_to_J{$J_to_N{$J}}=$J;
#}


my @hex = ("0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F");

my (%smallblocks_loc);
my (%psets_cpus);

my (%smallblocks_j);

my $nodes=0;
my $nodes_running=0;
my $nodes_alloc=0;

$dbh = DBI->connect("dbi:DB2:$db_name", $db_user, $db_password);
&query_midplanes();
&query_blocks();
&query_blockpos();
&query_smallblocks();
&query_failed_nodecards();
&query_block_idle_time();
#&query_psets();
&query_jobs();
$dbh->disconnect();


# print system information
print "<system \n";
print "     	 system_name=\"$system_name\"\n";
print "     	 system_mem=\"$system_mem GB\"\n";
print "     	 system_cpucount=\"$system_cpucount\"\n";
print "     	 system_cpuspeed=\"$system_ghz GHz\"\n";
print "     	 system_cputype=\"$system_cputype\"\n";
print "     	 system_type=\"$system_type\"\n";
print "     	 system_frames=\"$system_nodes\"\n";
print "     	 system_perform=\"$system_gflops GFLOPS\"\n";
print "     	 system_time=\"$date\"\n";
print "       >\n";

&print_blocks();
&print_nodes();
&print_jobs();
&print_reservation();

print "<usage date=\"$date\" nodes=\"$nodes\" running=\"$nodes_running\" alloc=\"$nodes_alloc\"\n";
print "       usagestr=\"$date,$nodes,$nodes_running,$nodes_alloc\">\n";
print "</usage>\n";
print "</system>\n";


sub query_midplanes {
    my $r;
    my $stmt = "select POSINMACHINE,LOCATION from BGLMIDPLANE ";
    my $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
#	$midplane{$row[0]}=\@row;
	$r=$row[0];
	$r=~s/\d$//s;
	$rack{$r}=$row[1];
#	print STDERR "BLOCK >$row[0]< $r\n";
    }
}

sub query_blocks {
    my($stmt);
    $stmt = "select blockid,owner,status,mode,sizex,sizey,sizez,NUMPSETS,istorus, STATUSLASTMODIFIED,CREATEDATE from bglblock";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
#	print STDERR "BLOCK >$row[0]<\n";
	$blocks{$row[0]}=\@row;
    }
}

sub query_block_idle_time {
    my($stmt);
    $stmt = "select b.blockid, 
                    b.owner as owner, 
                    b.status, 
                    MAX(b.statuslastmodified) as reservation_started,
                    MAX(j.entrydate)          as last_job 
             from tbglblock b left outer join tbgljob_history j 
             on (b.blockid = j.blockid and b.owner = j.username and j.entrydate >= b.statuslastmodified) 
             where b.status='I' and b.blockid not in (select blockid from tbgljob) 
             group by b.blockid, b.owner, b.status order by b.blockid";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
	$row[4]="-" if(!defined($row[4]));
#	print STDERR "BLOCKIDLE >$row[0]< >$row[1]< >$row[2]< >$row[3]< >$row[4]< \n";
	$blockidle{$row[0]}=\@row;
    }
}

sub query_failed_nodecards {
    my($stmt,$rack,$nc);
    $stmt = "select location,status from bglnodecard where location not in (select location from bglnodecard where (status='A')) order by location";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
	$row[0]=~/(R\d\d-M\d)-N(.)/;
	$rack=$1;$nc=$2;
	$failedmidplane{$rack}++;
	$row[0]=$nc;
	push(@{$failednc{$rack}},\@row);
#	print STDERR "failed NC: >$row[0]< $row[1] $rack,$nc\n";

    }
}


sub query_blockpos {
    my(%foundinstatus);
    my($stmt);
#    $stmt = "select bpid,blockid,x_loc,y_loc,z_loc from bglbpblockstatus";
#    $sth = $dbh->prepare($stmt);
#    $sth->execute();
#    while ( my @row = $sth->fetchrow_array() ) {
#	$row[1]=~s/\s*$//gs;
#	print STDERR "BLOCKS >$row[1]< @row\n";
#	$foundinstatus{$row[1]}=1;
#	push(@{$blockpos{$row[1]}},\@row);
#    }

    $stmt = "select b.bpid,b.blockid,m.location,b.xcoord,b.ycoord,b.zcoord from bglbpblockmap as b JOIN bglMidplane as m ON b.bpid = m.posInMachine order by m.posInMachine";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[1]=~s/\s*$//gs;
#	print STDERR "BLOCK >$row[1]< @row\n";
	push(@{$blockpos{$row[1]}},\@row);
    }

}

sub query_smallblocks {
    my($stmt,$comppos,$ionodepos);
    $stmt = "select blockid,compnodepos,posinmachine,ionodepos from bglsmallblock";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
	$comppos=$row[1];
	$ionodepos=$row[3];
	if($undefined_J{$comppos}) {
	    # bug fix, use ionodepos for the comppos 
	    if($smallblocks_j{$row[0]}{$ionodepos}) {
		# nop
	    } else {
		$row[1]=$row[3];
		push(@{$smallblocks_loc{$row[0]}},\@row);
		$smallblocks_j{$row[0]}{$ionodepos}=1;
#		print STDERR "WF: $row[0] >$comppos<>$ionodepos<\n";
	    }
	} else {
	    push(@{$smallblocks_loc{$row[0]}},\@row);
	    $smallblocks_j{$row[0]}{$comppos}=1;
	}
    }
}

sub query_smallblocks_save {
    my($stmt);
    $stmt = "select blockid,compnodepos,posinmachine from bglsmallblock";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
	push(@{$smallblocks_loc{$row[0]}},\@row);
    }
}

sub query_psets {
    my($stmt,$size,$tab);
    for $size ("128", "64", "32") {
	$tab="bglbppset".$size;
	$stmt = "select psetid,LOCATION from $tab";
	$sth = $dbh->prepare($stmt);
	$sth->execute();
	while ( my @row = $sth->fetchrow_array() ) {
	    $row[0]=~s/\s*$//gs;
	    push(@{$psets_cpus{$size}{$row[0]}},$row[1]);
	}
    }
}

sub query_jobs {
    my($stmt);
    $stmt = "select jobid,username,blockid,jobname,executable,outputdir,status,statuslastmodified,outfile,errfile,args,envs,errtext,exitstatus from bgljob";
    $sth = $dbh->prepare($stmt);
    $sth->execute();
    while ( my @row = $sth->fetchrow_array() ) {
	$row[0]=~s/\s*$//gs;
#	print STDERR "WF: $row[0] $row[1] $row[2] $row[3]\n";
	$jobs{$row[0]}=\@row;
	$row[2]=~s/\s*$//gs;
	if(($row[6] eq "R") || ($row[6] eq "E") || ($row[6] eq "D")  ) {
	    $block_inuse{$row[2]}=$row[0];
	}
	if(($row[6] eq "R") ) {
	    $block_running{$row[2]}=$row[0];
	}
    }
}


sub print_reservation {
    my($line,$nodelist);
    my($startdate,$enddate,$prio);

    open(IN,"/usr/local/bin/sched_bgl -l|");
    while($line=<IN>) {
	next if ($line=~/^\s*ResID/);
	if($line=~/^$patwrd$patbl$patint$patbl$patwrd$patbl$patwrd$patbl$patwrd$patbl$patwrd$patbl(\d+)?/) {
	    my($mode,$resid,$user,$startt,$endt,$racks)=($1,$2,$3,$4,$5,$6);
	    if ($7) {
		$prio=$7;
	    } else {
		$prio=1;
		# for tests
#		$prio=2 if ($user eq "jzam0409");
	    }

	    my(@nodelist,$block,$posref);  
	    @nodelist=();
	    foreach $block (split(/,/,$racks)) {
		foreach $posref (@{$blockpos{$block}}) {
		    my($bpid,$blockid,$loc,$xcoord,$ycoord,$zcoord)=(@$posref);
		    push(@nodelist,$loc);
		}
		$nodelist=join(",",@nodelist);
	    }

	    $startdate=&convdate2($startt);
	    $enddate=&convdate2($endt);
	    if(($startdate ne "-1") && ($enddate ne "-1")) {
		print "<reservation\n";
		print "\t mode=\"",$mode,"\"\n";
		print "\t resid=\"",$resid,"\"\n";
		print "\t user=\"",$user,"\"\n";
		print "\t starttime=\"",$startdate,"\"\n";
		print "\t endtime=\"",$enddate,"\"\n";
		print "\t nodelist=\"",$nodelist,"\"\n";
		print "\t priority=\"",$prio,"\"\n";
		print "\t >\n";
		print "\t </reservation>\n";
	    }
	}
    }
    close(IN);
}

sub print_blocks {
    my($block,$blockref,$blockid,$owner,$status,$mode,$sizex,$sizey,$sizez,$numpsets,$istorus);
    my($nodelist,$loc,$pblockid,$px,$py,$pz,$size,$nodebook,$locref,$posinmachine,$moddate,$createdate);
    my($posref,$bpid,$xcoord,$ycoord,$zcoord,$lnodes);
    foreach $block (keys(%blocks)) {
	 $blockref=$blocks{$block};
	($blockid,$owner,$status,$mode,$sizex,$sizey,$sizez,$numpsets,$istorus,$moddate,$createdate)=@{$blockref};
	my(@nodelist);
	@nodelist=();
#	next if($status eq "F");
	 $lnodes=0;
	print "<partition\n";
	print "\t part_name=\"",$block,"\"\n";
#	print STDERR "WF: part_name= $block $sizex*$sizey*$sizez $numpsets\n";
	if (($sizex*$sizey*$sizez==0) && ($numpsets==0)) {
	    # small block
	    if($smallblocks_loc{$block}) {
		$size=(scalar @{$smallblocks_loc{$block}})*32;
	    } else {
		$size=0;
	    }

	    foreach $locref (@{$smallblocks_loc{$block}}) {
		($pblockid,$loc,$posinmachine)=(@{$locref});
		$posinmachine=~/R(\d)(\d)(\d)/;
		($px,$py,$pz)=($1,$2,$3);
#		print "WF: $loc\n";
		if($J_to_N{$loc}) {
		    $nodebook="R${px}${py}-M${pz}-".$J_to_N{$loc};
		    push(@nodelist,"$nodebook");
		    push(@{$node_classes{$nodebook}},"(".$block.",".(($mode eq "C")?32:64).")");
		    $lnodes+=32;
#		print STDERR "--> $nodebook, $loc,$posinmachine, $px,$py,$pz\n";
		} else {
		    print STDERR "--> unknown nodebook >$loc< block $block\n";
		}
	    }
	    $nodelist=join(",",@nodelist);
	} else {
	    $nodelist="";
	    foreach $posref (@{$blockpos{$block}}) {
		($bpid,$blockid,$loc,$xcoord,$ycoord,$zcoord)=(@$posref);
#		print STDERR "$block -> ($bpid,$blockid,$xcoord,$ycoord,$zcoord)\n";
		push(@nodelist,$loc);
		push(@{$node_classes{$loc}},"(".$block.",".(($mode eq "C")?512:1024).")");
		$lnodes+=512;
	    }
	    $nodelist=join(",",@nodelist);
	}
	print "\t part_nodelist=\"",$nodelist,"\"\n";
	print "\t part_owner=\"",$owner,"\"\n";
	print "\t part_mode=\"",$mode,"\"\n";
	print "\t part_istorus=\"",$istorus,"\"\n";
	print "\t part_status=\"",$status,"\"\n";
	if($mmcs_block_status{$status}) {
	    print "\t part_statuslong=\"",$mmcs_block_status{$status},"\"\n";
	} else {
	    print "\t part_statuslong=\"","unknown","\"\n";
	}
	if( (($status eq "I") ||($status eq "A") || ($status eq "B"))  && (!exists($block_inuse{$block}))) {
	    print "\t part_reserved=\"1\"\n";
	}
	print "\t >\n";
	print "\t </partition>\n";

	# blocked partitions
	if( (($status eq "I") || ($status eq "A") || ($status eq "B") || ($status eq "D")) && (!exists($block_inuse{$block}))) {
	    $size=0;
	    $nodes_alloc+=$lnodes if($owner ne "bgldiag");
	    print "<job\n";
	    print "\t job_step=\"$block\"\n";
	    print "\t job_name=\"init_$block\"\n" if($status eq "I");
	    print "\t job_name=\"alloc_$block\"\n" if($status eq "A");
	    print "\t job_name=\"boot_$block\"\n" if($status eq "B");
	    print "\t job_name=\"deallocate_$block\"\n" if($status eq "D");
	    {
		my ($i,$node,@nodes,$nodelist2);
		foreach $node (split(/,/,$nodelist)) {
		    push (@nodes,"(".$node.",0)");
		}
		$nodelist2=join(",",@nodes);
		print "\t job_nodelist=\"",$nodelist2,"\"\n";
	    }
	    print "\t job_queuedate=\"",&convdate($moddate),"\"\n";
	    if(defined($blockidle{$block})) {
		if(${$blockidle{$block}}[4] ne "-") {
		    print "\t job_dispatchdate=\"",&convdate(${$blockidle{$block}}[4]),"\"\n";
		} else {
		    print "\t job_dispatchdate=\"",&convdate($moddate),"\"\n";
		}
	    } else  {
		print "\t job_dispatchdate=\"",&convdate($moddate),"\"\n";
	    }
	    print "\t job_enddate=\"$date\"\n";
	    print "\t job_owner=\"",substr($owner,0,8),"\"\n";
	    print "\t job_queue=\"init\"\n" if($status eq "I");
	    print "\t job_queue=\"alloc\"\n" if($status eq "A");
	    print "\t job_queue=\"boot\"\n" if($status eq "B");
	    print "\t job_queue=\"dealloc\"\n" if($status eq "D");
	    print "\t job_status=\"","$status","\"\n";
	    print "\t job_statusnr=\"","1","\"\n";
	    print "\t job_statuslong=\"","","\"\n";
	    print "\t job_sysprio=\"",0,"\"\n";
	    print "\t job_totaltasks=\"",$size,"\"\n";
	    print "\t job_taskspernode=\"",32,"\"\n";
	    print "\t job_nummachines=\"",$size/32,"\"\n";
	    print "\t job_totaltasksR=\"",$size,"\"\n";
	    print "\t job_taskspernodeR=\"",32,"\"\n";
	    print "\t job_totalnodesR=\"",10,",",10,"\"\n";
	    print "\t job_conscpu=\"",($mode eq "V")?2:1,"\"\n";
	    print "\t job_consmem=\"",1,"\"\n";
	    print "\t job_comment=\"","$block, NOT Unicore","\"\n";
	    print "\t job_taskexec=\"","No Executable started","\"\n";
	    print "\t job_node_usage=\"","NOT_SHARED","\"\n";
	    print "\t job_wall=\"","","\"\n";
	    print "\t job_wallsoft=\"","","\"\n";
	    print "\t job_cpu=\"","","\"\n";
	    print "\t job_cpusoft=\"","","\"\n";
	    print "\t job_restart=\"","Yes","\"\n";
	    print "\t job_userprio=\"","1","\"\n";
	    print "\t job_usertime=\"","1","\"\n";
	    print "\t job_cputime=\"","1","\"\n";
	    print "\t job_bgl_istorus=\"","$istorus","\"\n";
	    print "\t job_bgl_mode=\"","$mode","\"\n";
	    print "\t job_bgl_args=\"","","\"\n";
	    print "\t job_bgl_env=\"","","\"\n";
	    print "\t >\n";
	    print "\t </job>\n";

	}

    }
}

sub print_nodes {
    my($mid,$rack,$nodename,$failednodes,$N,$state,$rowref);
    foreach $rack (keys(%rack)) {
#	print "WF: $rack\n";
	for($mid=0;$mid<=1;$mid++) {
	    $nodename="${rack}-M${mid}";
	    print "<node \n";
	    print "\t node_name=\"$nodename\"\n";
	    if(exists($failedmidplane{$nodename})) {
		if($failedmidplane{$nodename}==16) {
		    print "\t node_state=\"","error","\"\n";
		} else {
		    print "\t node_state=\"","partly error","\"\n";
		}
		$failednodes="";
		foreach $rowref (@{$failednc{$nodename}}) {
		    ($N,$state)=(@{$rowref});
		    $failednodes.=($failednodes?",":"")."(N$N:$state)";
		}
		    print "\t node_failed_parts=\"",$failednodes,"\"\n";
	    } else {
		print "\t node_state=\"","Running","\"\n";
	    }
	    $nodes+=512;
	    print "\t node_arch=\"","BGL midplane PowerPC","\"\n";
	    print "\t node_cpus=\"",1024,"\"\n";
	    print "\t node_maxtasks=\"",1024,"\"\n";
	    print "\t node_speed=\"",0.7,"\"\n";
	    print "\t node_schedd=\"-1\"\n";
	    print "\t node_scheddjobs=\"-1\"\n";
	    print "\t node_avail_classes=\"",join(",",@{$node_classes{$nodename}}),"\"\n";
	    print "\t >\n";
	    print "<mem \n";
	    print "\t mem_total=\"",16384,"\"\n";
	    print "\t mem_used=\"",16384,"\"\n";
	    print "\t mem_avail=\"",0,"\"\n";
	    print "\t mem_unit=\"","mb","\"\n";
	    print "\t >\n";
	    print "</mem>\n";
	    print "<cpu \n";
	    print "\t cpu_total=\"",1024,"\"\n";
	    print "\t cpu_avail=\"",0,"\"\n";
	    print "\t cpu_run=\"",1024,"\"\n";
	    print "\t >\n";
	    print "</cpu>\n";
	    print "<load load_avg=\"1\" />";
	    
	    print "</node>\n";
	}
     }
}


sub print_jobs {
    my($jobid,$msize,$blockref,$blockid,$owner,$status,$mode,$sizex,$sizey,$sizez,$numpsets,$istorus);
    my($psets,$nodelist,$size,$locref,$pblockid,$posinmachine,$node,$posref,$bpid,$loc,$lnodes);
    my($xcoord,$ycoord,$zcoord);
    foreach $jobid (keys(%jobs)) {
	my($jjobid,$jusername,$jblockid,$jjobname,$jexecutable,$joutputdir,$jstatus,
	   $jstatuslastmodified,$joutfile,$jerrfile,$jargs,
	   $jenvs,$jerrtext,$jexitstatus)=(@{$jobs{$jobid}});
	$lnodes=0;
	$jblockid=~s/\s*$//gs;
	$blockref=$blocks{$jblockid};
	($blockid,$owner,$status,$mode,$sizex,$sizey,$sizez,$numpsets,$istorus)=@{$blockref};
	next if($jstatus eq "S"); # print_blocks will print the job information
	print "<job\n";
	print "\t job_step=\"",$jblockid,"\"\n";
	print "\t job_name=\"",$jobid,"\"\n";
	$msize=0;
	$jargs="" if(!defined($jargs));
	$jenvs="" if(!defined($jenvs));
	if($jargs=~/-np\s+(\d+)/) {
	    $msize=$1;
	}
	if($jenvs=~/BGLMPI_SIZE=(\d+)/) {
	    $msize=$1;
	}
	if($msize>0) {
	    $msize/=2 if ($mode eq "V");
	}
#	print STDERR "WF: >$jblockid<>$jenvs<>$jargs< $msize\n";
	if (($sizex*$sizey*$sizez==0) && ($numpsets==0)) {
	    # small block
	    my(@nodelist,%nodelist,$loc);
	    @nodelist=();
	    keys %nodelist=0;
	    $size=(scalar @{$smallblocks_loc{$jblockid}})*32;
	    $msize=$size if($msize==0);
	    foreach $locref (@{$smallblocks_loc{$jblockid}}) {
		($pblockid,$loc,$posinmachine)=(@{$locref});
		$posinmachine=~/R(\d)(\d)(\d)/;
		my($px,$py,$pz)=($1,$2,$3);
		my $nodebook="R${px}${py}-M${pz}-".$J_to_N{$loc};
#		print STDERR "--> $nodebook, $loc,$posinmachine, $px,$py,$pz\n";
		$nodelist{$nodebook}+=32*$msize/$size;
		$lnodes+=32;
	    }
	    foreach $node (keys(%nodelist)) {
		push(@nodelist,"($node,".($nodelist{$node}).")");
	    }
	    $nodelist=join(",",@nodelist);
	} else {
	    $nodelist="";
	    $size=0;
	    $size=(scalar @{$blockpos{$jblockid}})*512;
	    $msize=$size if($msize==0);
	    foreach $posref (@{$blockpos{$jblockid}}) {
		($bpid,undef,$loc,$xcoord,$ycoord,$zcoord)=(@$posref);
#		print STDERR "$jblockid ($bpid,$pblockid,$xcoord,$ycoord,$zcoord)\n";
		my $midplane=$zcoord;
		my $asize=$msize/(scalar @{$blockpos{$jblockid}});
		$nodelist.="($loc,$asize)";
		$lnodes+=512;

	    }
	}
#	print STDERR "$jusername $jblockid >$size<>$msize<  $istorus $mode $jargs $jenvs \n";
	my $wall=24*60*60;
	my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$idst)=localtime(time()+24*60*60);
	$year=substr($year,1,2);
	my $enddate=sprintf("%02d/%02d/%02d-%02d:%02d:%02d",
			 $mon+1,$mday,$year,$hour,$min,$sec);

	if(!exists($mmcs_job_status_short{$status})) {
	    $mmcs_job_status_short{$status}=$status;
	    $mmcs_job_status{$status}="unknown_$status";
	}
	
#	if( ($jstatus eq "R") || ($jstatus eq "E") ) {
#	print STDERR "WF: $jobid $jstatus $status $blockid \n";
# TODO: error job with initialized partition will only be handled correctly on large partition
#       on small partition we have to check all nodebook on its status
	if( ($jstatus eq "R") || (($jstatus eq "E") && ($status eq "I") && (!exists($block_running{$blockid}))) ) {
	    $nodes_running+=$lnodes;
	    $block_running{$blockid}=$jobid;
	    print "\t job_nodelist=\"",$nodelist,"\"\n";
	} else {
	    print "\t job_nodelist=\"","","\"\n";
	    $msize=0;
	}
	print "\t job_queuedate=\"",&convdate($jstatuslastmodified),"\"\n";
	print "\t job_dispatchdate=\"",&convdate($jstatuslastmodified),"\"\n";
	print "\t job_enddate=\"",$enddate,"\"\n";
	print "\t job_owner=\"",substr($jusername,0,8),"\"\n";
	print "\t job_queue=\"",$mmcs_job_status_short{$jstatus},"\"\n";
	print "\t job_status=\"","$jstatus","\"\n";
	print "\t job_statusnr=\"","$jstatus","\"\n";
	print "\t job_statuslong=\"",$mmcs_job_status{$jstatus},"\"\n";
	print "\t job_sysprio=\"",0,"\"\n";
	print "\t job_totaltasks=\"",$msize,"\"\n";
	print "\t job_taskspernode=\"",512,"\"\n";
	print "\t job_nummachines=\"",$msize/512,"\"\n";
	print "\t job_totaltasksR=\"",$msize,"\"\n";
	print "\t job_taskspernodeR=\"",512,"\"\n";
	print "\t job_totalnodesR=\"",$msize,",",$msize,"\"\n";
	print "\t job_conscpu=\"",1,"\"\n";
	print "\t job_consmem=\"",1,"\"\n";
	print "\t job_comment=\"","$jblockid, NOT Unicore","\"\n";
	print "\t job_taskexec=\"","$jexecutable","\"\n";
	print "\t job_node_usage=\"","NOT_SHARED","\"\n";
	print "\t job_wall=\"","$wall","\"\n";
	print "\t job_wallsoft=\"","$wall","\"\n";
	print "\t job_cpu=\"","$wall","\"\n";
	print "\t job_cpusoft=\"","$wall","\"\n";
	print "\t job_restart=\"","Yes","\"\n";
	print "\t job_userprio=\"","1","\"\n";
	print "\t job_usertime=\"","1","\"\n";
	print "\t job_cputime=\"","1","\"\n";
	print "\t job_bgl_istorus=\"","$istorus","\"\n";
	print "\t job_bgl_mode=\"","$mode","\"\n";
	print "\t job_bgl_args=\"","$jargs","\"\n";
	print "\t job_bgl_env=\"","$jenvs","\"\n";
	print "\t >\n";
	print "\t </job>\n";
	

    }
    return;
}

sub convdate {
    my($indate)=@_;
    $indate=~/\d\d(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)\.(\d+)/gs;
    my $date="$2/$3/$1-$4:$5:$6";
    return($date);
}

sub convdate2 {
    my($indate)=@_;
    if($indate=~/\d\d(\d\d)\.(\d+)\.(\d+)_(\d+):(\d+)/gs) {
	my $date="$2/$3/$1-$4:$5:00";
	return($date);
    } else {
	return("-1");
    }
}
