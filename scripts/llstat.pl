#!/usr/bin/perl -w
#
#          LLview - supervising LoadLeveler batch queue utilization 
#
#     ---- Command line version of LLview client, for use on BG/L ---
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

my $patint="([\\+\\-\\d]+)";   # Pattern for Integer number
my $patfp ="([\\+\\-\\d.E]+)"; # Pattern for Floating Point number
my $patwrd="([\^\\s]+)";       # Pattern for Work (all noblank characters)
my $patbl ="\\s+";             # Pattern for blank space (variable length)

my @hex = ("0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F");
my %hextod = ("0" => 0,"1" => 1,"2" => 2,"3" => 3,"4" => 4,"5" => 5,"6" => 6,"7" => 7,
	      "8" => 8,"9" => 9,"A" => 10,"B" => 11,"C" => 12,"D" => 13,"E" => 14,"F" => 15);


 
use FindBin;
use lib "$FindBin::RealBin/lib";

use Getopt::Long;
use XML::Simple;
use Data::Dumper;
use Time::HiRes qw ( time );
use Time::Local;
use strict;

my $opt_dump=0;
my $opt_verbose=0;
my $opt_long=0;
my $opt_reverse=0;

usage($0) if( ! GetOptions( 
			    'verbose'          => \$opt_verbose,
			    'long'             => \$opt_long,
			    'reverse'          => \$opt_reverse,
			    'dump'             => \$opt_dump
			    ) );

my $idfile="./.bench_current_id.dat";

my $hostname=`hostname`;
my $query;

#########################################################
# Configuration section
#########################################################
# location of bglquery perl script
if($hostname=~/<servicenode>/) {
    # local on this node
    $query="$FindBin::RealBin/bglquery.pl";
} else {
    # wrapper script, which calls bglquery.pl over ssh on servicenode (eg. with a special ssh-key)
    $query="/bgl/local/bin/llview_query";
}

my $xs=XML::Simple->new();
my $tstart=time;
my $nummidplanes=16;
my $pmarker="";
my $rmarker="";
my $xml="";
my @col_order;
@col_order=(0,1) if(!$opt_reverse);
@col_order=(1,0) if($opt_reverse);

if($ARGV[0]) {
    open(PIPE,$ARGV[0]);
} else {
    open(PIPE,"$query|");
}

while(<PIPE>) {
    if(!$opt_long) {
	next if(/(part_statuslong|part_nodelist|part_statuslong|part_status)/)
    }
    $xml.=$_;
}
close(PIPE);
my $tdiff=time-$tstart;
printf("WF: generating XML in %6.4f sec\n",$tdiff) if($opt_verbose);

$tstart=time;
my $benchref=$xs->XMLin($xml,KeyAttr => {node => "node_name",
					 reservation => "resid", 
					 partition => "part_name", 
					 job => "job_name"});
$tdiff=time-$tstart;
printf("WF: parsing    XML in %6.4f sec\n",$tdiff) if($opt_verbose);
$tstart=time;

my($noderef,$partref,$jobref,$pc,$part,$resref);
my($sum_midplanes,$sum_chips,$sum_smalljobs,$sum_onlyallocchips,$jobcount,$jobname);
my($colw,$colsep,$leftm,$row,$midplane,$help0,$help1,$rack,$nodename,%smallpart);
my($nodeboard,%nodeusage,%nodeowner,%nodechipnum,%smalljobs,%nodemode,%nodestatus,%nodetasknum);
my(%nstat,$p,$resid,$rescount);

if($benchref) {
    
    if($opt_dump) {
	print Dumper($benchref);
	exit(1);
    }

    print "\n";
    printf("--------------------------------------------------------\n");
    printf("llstat (FZJIBM Blue Gene/L): %20s\n",$benchref->{'system_time'});
    printf("--------------------------------------------------------\n");
    
    $noderef=$benchref->{'node'};
    $partref=$benchref->{'partition'};
    $jobref=$benchref->{'job'};
    $resref=$benchref->{'reservation'};
    if($opt_long) {
	print "\n${pmarker}Defined Partitions:\n";
	printf( "${pmarker}\t%3s: %-20s %-10s %-8s %-6s %-5s %7s %7s %s\n","Nr","Name","Owner","Status","Mode","Torus","#N-Cards","#CPUs","Location");
	print "${pmarker}\t","-"x90,"\n";
	$pc=0;
	if($partref->{'part_nodelist'}) {
	    output_part($partref,$partref->{'part_name'});
	}else {
	    foreach $part (sort {$a cmp $b} (keys(%$partref))) {
		output_part($partref->{$part},$part);
	    }
	}
    }

    print "${pmarker}\n";

    print "Reservations:       (starting in the next 48 hours)\n";
    print "------------\n";
    printf( "     %2s  %6s %-4s %-10s %-17s %-17s %4s %6s\n",
	    "Nr","ResID","Mode","User","Start","End","Prio","Midplanes");
    print "    ","-"x101,"\n";
    $rescount=0;
    if($resref->{'resid'}) {
	output_reservation($resref,$resref->{'resid'});
    }else {
	foreach $resid (sort {        &date_to_sec($resref->{$a}->{'starttime'}) 
				  <=> &date_to_sec($resref->{$b}->{'starttime'})} (keys(%$resref))) {
	    output_reservation($resref->{$resid},$resid);
	}
    }


    print "\n";
    $sum_midplanes=0;
    $sum_chips=0;
    $sum_smalljobs=0;
    $sum_onlyallocchips=0;
    print "Running Jobs:       (1 rack = 2 midplanes = 2*16 node books = 2*16*32=1024 nodes = 2*16*32*2=2048 cpus)\n";
    print "------------\n";
    printf( "     %2s  %-20s %-10s %-10s %-8s %-7s %-6s %-6s  %-6s %-6s  %6s\n",
	    "Nr","Step name","Job name","Owner","Queue","#NBooks","#Nodes","#Tasks","Mode","Torus","cpu-h");
    print "    ","-"x101,"\n";
    $jobcount=0;
    if($jobref->{'job_step'}) {
	output_job($jobref,$jobref->{'job_step'});
    }else {
	foreach $jobname (sort {$jobref->{$b}->{'job_totaltasks'} <=> $jobref->{$a}->{'job_totaltasks'}} (keys(%$jobref))) {
	    output_job($jobref->{$jobname},$jobname);
	}
    }

    $colw=40;
    $colsep=4;
    $leftm=8;
    
    print "\nMidplane usage:\n";
    print "---------------"." "x(30)."#nodes"." "x(42)."#nodes"."\n";
    foreach $row (0,1,2,3) {
	print " "x$leftm."+-"."-"x$colw."-+"." "x$colsep."+-"."-"x$colw."-+"."\n";
	foreach $midplane (1,0) {
	    $help0=sprintf(" %-${colw}s ",&get_midplane_info($row,$col_order[0],$midplane));
	    $help1=sprintf(" %-${colw}s ",&get_midplane_info($row,$col_order[1],$midplane));
	    print " "x$leftm."|".$help0."|"." "x$colsep."|".$help1."|"."\n";
	}
	print " "x$leftm."+-"."-"x$colw."-+"." "x$colsep."+-"."-"x$colw."-+"."\n";
    }

    print "\nMidplanes with small blocks:\n";
    print "----------------------------\n";
    foreach $rack (00,01,10,11,20,21,30,31) {
	foreach $midplane (1,0) {
	    $nodename=sprintf("R%02d-M%1d",$rack,$midplane);
	    next if(!$smallpart{$nodename}); 
	    foreach $nodeboard (@hex) {	$nstat{$nodeboard}="R"; }
	    if($noderef->{$nodename}->{'node_state'} ne "Running") {
		foreach $p (split(/,/,$noderef->{$nodename}->{'node_failed_parts'})) {
		    $p=~/\(N(.):(.)\)/;$nstat{$1}=$2;
		}
	    } else {
	    }
	    printf("      %s:   ",$nodename);
	    my $c=0;
	    print "";
	    foreach $nodeboard (@hex) {
		$c++;
		$nodename=sprintf("R%02d-M%1d-N%1s",$rack,$midplane,$nodeboard);
		printf("N%1s: ",$nodeboard);
		if($nstat{$nodeboard} eq "R") {
		    if($nodeusage{$nodename}) {
			printf(" <%02d> %-8s   ",$nodeusage{$nodename},substr($nodeowner{$nodename},0,8));
		    } else {
			printf(" <%2s> %-8s   ","--","");
		    }
		} else {
		    printf(" ERROR: state %s   ",$nstat{$nodeboard});
		}
		if($c>=4) {
		    print "\n                ";$c=0;
		}
	    }
	    print "\n";
	    
	}
    }

    $sum_midplanes+=scalar (keys(%smallpart));
    printf("Usage:  %d (%.1f%%) of %d nodes, %d of %d midplanes, %d (%.1f%%) nodes only allocated\n",
	   $sum_chips,$sum_chips/($nummidplanes*16*32)*100,$nummidplanes*16*32,
	   $sum_midplanes,$nummidplanes,
	   $sum_onlyallocchips,$sum_onlyallocchips/($nummidplanes*16*32)*100
	   );
    printf("------  %d running jobs (%d small jobs)\n",
	   $jobcount,$sum_smalljobs
	   );
   

$tdiff=time-$tstart;
printf("WF: printing in %6.4f sec\n",$tdiff) if($opt_verbose);
   
}

sub get_midplane_info {
    my($row,$col,$midplane)=@_;
    my($help,$nodename,$spec,$p,$nc,$s,$c,$addstr,$errmsg);
    $help=sprintf("R%1d%1d-M%1d:",$row,$col,$midplane);
    $nodename=sprintf("R%1d%1d-M%1d",$row,$col,$midplane);
    if($smallpart{$nodename}) {
	$spec=sprintf("%4d",$nodechipnum{$nodename});
	$help.=sprintf(" small, %2d cards, %2d jobs %7s",$smallpart{$nodename},
		       (exists($smalljobs{$nodename})?$smalljobs{$nodename}:0),
		       $spec);
    } elsif($nodeusage{$nodename}) {
	# FZJ spec: bgldiag allocated blocks are free for reservation
	if(($nodeowner{$nodename} eq "bgldiag") && ($nodestatus{$nodename}=~/(alloc|init)/)) {
	    $help.=sprintf(" <%02s>  %20s     ","--"," free for reservation");
	} else {
	    $spec=sprintf("[%s,%s] %4d",$nodemode{$nodename},$nodestatus{$nodename},$nodechipnum{$nodename});
	    $help.=sprintf(" <%02d> %-8s %18s",$nodeusage{$nodename},substr($nodeowner{$nodename},0,8),$spec);
	}
    } else {
	$spec=sprintf("%4d",0);
	if($noderef->{$nodename}->{'node_state'} ne "Running") {
	    $c=0;
	    foreach $p (split(/,/,$noderef->{$nodename}->{'node_failed_parts'})) {
		$p=~/\(N(.):(.)\)/;($nc,$s)=($1,$2);
		$c++;
	    }
	    if($noderef->{$nodename}->{'node_state'} eq "partly error") {
		$errmsg="P.Err";
		$addstr="$c  NBs: state $s";
	    } else {
		$errmsg=$noderef->{$nodename}->{'node_state'};
		$addstr="all NBs: state $s";
	    }

	    $help.=sprintf(" <%2s> %-5s: %20s","--",uc($errmsg),$addstr."    ");
	} else {
	    $help.=sprintf(" <%2s> %-8s %18s","--","",$spec);
	}
    }

    return($help);
}
#                                                     *(($nodemode{$nodemode} eq "V")?2:1);


sub output_part {
    my($partref,$partname)=@_;
    my($nc,@nc,@ncc,@last,$boards,%board,$m,%nboard,$node,$R,$M,$c,$N);
    $pc++;
    $nc=0;
    $boards="";
    $last[0]=$last[1]=-1;
    foreach $R ('00','01','10','11','20','21','30','31') {
	$board{$R}{'0'}=$board{$R}{'1'}=0;
    }    
    foreach $node (split(/,/,$partref->{'part_nodelist'})) {
	if($node=~/R(\d\d)-M(\d)-N(.)/s) {
	    my($R,$M,$N)=($1,$2,$3);
	    # it's one board
	    $nboard{$R}{$M}{$N}=1;
	    $nc++;
#	    print "WF: set {$R}{$M}{$N}\n";
	    
	} elsif($node=~/R(\d\d)-M(\d)/s) {
	    # it's a midplane
	    my($R,$M)=($1,$2);
	    $board{$R}{$M}=1;
	    $nc+=16;
#	    print "WF: set {$R}{$M}\n";
	}
    }
	
    
    foreach $R ('00','01','10','11','20','21','30','31') {
	if( ($board{$R}{'0'}==1) && ($board{$R}{'1'}==1)) {
	    # complete rack
	    $boards.="," if(length($boards)>0);
	    $boards.="R$R";
	} else {
	    $boards.="R${R}-M0" if($board{$R}{'0'}==1);
	    $boards.="R${R}-M1" if($board{$R}{'1'}==1);
	}

	
	foreach $M ('1','0') {
	    if(keys(%{$nboard{$R}{$M}})>0) {
		$boards.="R${R}-M${M}:";
		$c=0;
		foreach $N (@hex) {
		    if(exists($nboard{$R}{$M}{$N})) {
			$boards.="," if ($c>0);
			$boards.="N${N}";
			$c++;
		    }
		}
	    }
	}
	delete($board{$R});
	delete($nboard{$R});
    }



    printf("${pmarker}\t%3d: %-20s %-10s %-8s %-6s %-5s %7d %7d  %s\n",$pc,
	   $partname,
	   $partref->{'part_owner'},
	   $partref->{'part_status'},
	   $partref->{'part_mode'},
	   $partref->{'part_istorus'},
	   $nc,
	   $nc*64,
	   $boards
	   );
}

sub output_job {
    my($jobref,$jobname)=@_;
    my($part,$midplane,$smalljob,$nc,$tc,$node,$freejob);
    $jobcount++; $nc=0; $tc=0; $smalljob=0;
    $part=$jobref->{'job_step'};
    $freejob=0;
    $freejob=1 if(($jobref->{'job_owner'} eq "bgldiag") && ($jobref->{'job_queue'}=~/(alloc|init)/));
#    print "WF: $jobref->{'job_nodelist'} $jobname\n";
    foreach $node (split(/\)\,?\(/,$jobref->{'job_nodelist'})) {
	$node=~/\(?(.*)\,(\d+)\)?/gs;
	my ($nodename,$number)=($1,$2);
	$nodeusage{$nodename}=$jobcount;
	$nodeowner{$nodename}=$jobref->{'job_owner'};
	$nodestatus{$nodename}=$jobref->{'job_queue'};
	$nodetasknum{$nodename}=$number;
	$nodemode{$nodename}=$partref->{$part}->{'part_mode'};
	$nodename=~/^(R\d\d-M\d)/;
	$midplane=$1;
	if($nodename=~/-N.$/) {
	    # its a nodecard
	    $nc++;
	    $smallpart{$midplane}++;
#	    $nodetasknum{$midplane}+=$number*(($partref->{$part}->{'part_mode'} eq "V")?2:1);
	    $nodetasknum{$midplane}+=$number;
	    $nodechipnum{$midplane}+=32;
	    $smalljob=1;
	} else {
	    # its a midplane
	    $nc+=16;
	    $nodechipnum{$midplane}+=16*32;
	    $sum_midplanes++ if(!$freejob);
	}
	$tc+=$number;
#	print "WF: >$node< $nc >$nodename<>$nodeusage{$nodename}<$nc\n";
    }

    # FZJ spec: bgldiag allocated blocks are free for reservation
    if(!$freejob) {
	$sum_chips+=$nc*32;
	$sum_smalljobs++ if($smalljob);
	$smalljobs{$midplane}++ if($smalljob);
	$sum_onlyallocchips+=$nc*32 if($tc==0);
	printf("    <%02d> %-20s %-10s %-10s %-8s %7d %6d %6d   %-6s %-6s %6.2f\n",$jobcount,
	       substr($jobref->{'job_step'},0,20),
	       substr($jobname,0,10),
	       substr($jobref->{'job_owner'},0,10),
	       substr($jobref->{'job_queue'},0,8),
	       $nc,
	       $nc*32,
	       $tc*(($partref->{$part}->{'part_mode'} eq "V")?2:1),
	       $partref->{$part}->{'part_mode'},
	       $partref->{$part}->{'part_istorus'},
	       &timediff($benchref->{'system_time'},$jobref->{'job_dispatchdate'})/3600.0
	       );
    }
}
    
sub output_reservation {
    my($resref,$resid)=@_;
    if(&timediff($resref->{'starttime'},$benchref->{'system_time'})<= 3600*24*2 ) {
	$rescount++;
	printf("    <%02d> %6s %4s %-10s %-17s %-17s %2d   %s\n",$rescount,
	       $resid,
	       $resref->{'mode'},
	       $resref->{'user'},
	       $resref->{'starttime'},
	       $resref->{'endtime'},
	       $resref->{'priority'},
	       $resref->{'nodelist'});
    }
}

sub date_to_sec {
    my ($date)=@_;
#    print"WF: date_to_sec $date\n";
    my ($mon,$mday,$year,$hours,$min,$sec)=split(/[ :\/\-]/,$date);
    $mon--;
#    print "WF: $date -> sec=$sec,min=$min,hours=$hours,mday=$mday,mon=$mon,year=$year $^O\n";
    my $timesec=timelocal($sec,$min,$hours,$mday,$mon,$year);
#    print "WF: $date -> sec=$sec,min=$min,hours=$hours,mday=$mday,mon=$mon,year=$year -> $timesec\n";
    return($timesec);
}

sub timediff {
    my ($date1,$date2)=@_;
#    print"WF: timediff $date1 $date2\n";
    my $timesec1=&date_to_sec($date1);
    my $timesec2=&date_to_sec($date2);
#    if((($timesec1-$timesec2)/3600)>200) {
#	printf("timediff: %20s - %20s -> %d\n",$date1,$date2,$timesec1-$timesec2);
#    }
    return($timesec1-$timesec2);
}


sub usage {
    die "Usage: $_[0] <options> [<xml-file>]
                -reverse           : plot midplanes in hardware order
                -long              : print partitions too
                -verbose           : verbose
                -dump              : dump XML-file structure

";
}
