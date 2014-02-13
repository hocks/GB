#!/usr/bin/ksh

cd ~hocks/scripts


for i in `cat BG.ionodes.ip`
do 
  echo $i 
  ping -c 1 $i 
   if [ $? = "0" ];  then 
     ssh $i  'cat /proc/personality.sh > /bggpfs/hocks/`hostname`.personality'
   else
    echo $i down
   fi
done  

