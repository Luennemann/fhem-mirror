#################################################################################
# 40_RFXCOM.pm
# Modul for FHEM
#
# Tested with USB-RFXCOM-Receiver (433.92MHz, USB, order code 80002)
# (see http://www.rfxcom.com/).
# To use this module, you need to define an RFXCOM receiver:
#	define RFXCOM RFXCOM /dev/ttyUSB0
#
# The module also has code to access LAN based RFXCOM receivers like 81003 and 83003.
#
# To use it define the IP-Adresss and the Port:
#	define RFXCOM RFXCOM 192.168.169.111:10001
# optionally you may issue not to initialize the device (useful for FHEM2FHEM raw 
# and if you share an RFXCOM device with other programs) 
#	define RFXCOM RFXCOM 192.168.169.111:10001 noinit
#
# The RFXCOM receivers supports lots of protocols that may be implemented for FHEM 
# writing the appropriate FHEM modules.
# Special thanks to RFXCOM, http://www.rfxcom.com/, for their help. 
# I own an USB-RFXCOM-Receiver (433.92MHz, USB, order code 80002) and highly recommend it.
#
# The module 41_OREGON.pm implements the decoding of the Oregon Scientific weather sensors.
# It is derived from xPL Perl (http://www.xpl-perl.org.uk/). I suggest to look there 
# if you want to implement other protocols.
# 
###########################
#
# Copyright (C) 2010,2012 Willi Herzig
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# The GNU General Public License may also be found at http://www.gnu.org/licenses/gpl-2.0.html .
###########################
# $Id$
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);

my $last_rmsg = "abcd";
my $last_time = 1;

sub RFXCOM_Clear($);
sub RFXCOM_Read($);
sub RFXCOM_SimpleWrite(@);
sub RFXCOM_SimpleRead($);
sub RFXCOM_Ready($);
sub RFXCOM_Parse($$$$);

sub RFXCOM_OpenDev($$);
sub RFXCOM_CloseDev($);
sub RFXCOM_Disconnected($);

sub
RFXCOM_Initialize($)
{
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

  # Provider
  $hash->{ReadFn}  = "RFXCOM_Read";
  $hash->{WriteFn} = "RFXCOM_Write";
  $hash->{Clients} =
        ":RFXMETER:OREGON:RFXX10REC:RFXELSE:";
  my %mc = (
    "1:RFXMETER"   => "^30.*",
    "2:OREGON"   => "^(3[8-9A-F]|[4-6][0-9A-F]|7[0-8]).*", #38-78
    "3:RFXX10REC"   => "^(20|29).*",
    #"4:RFXELSE"   => "^.*", # RFXELSE no longer after changing from bin to hexstring
  );
  $hash->{MatchList} = \%mc;

  $hash->{ReadyFn} = "RFXCOM_Ready";

  # Normal devices
  $hash->{DefFn}   = "RFXCOM_Define";
  $hash->{UndefFn} = "RFXCOM_Undef";
  $hash->{GetFn}   = "RFXCOM_Get";
  $hash->{SetFn}   = "RFXCOM_Set";
  $hash->{StateFn} = "RFXCOM_SetState";
  $hash->{AttrList}= "dummy:1,0 do_not_init:1:0 longids loglevel:0,1,2,3,4,5,6";
  $hash->{ShutdownFn} = "RFXCOM_Shutdown";
}

#####################################
sub
RFXCOM_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  return "wrong syntax: define <name> RFXCOM devicename [noinit]"
    if(@a != 3 && @a != 4);

  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  my $opt = $a[3] if(@a == 4);;

  if($dev eq "none") {
    Log 1, "RFXCOM: $name device is none, commands will be echoed only";
    $attr{$name}{dummy} = 1;
    return undef;
  }

  if($dev !~ /\@/) {
	Log 1,"RFXCOM: added baudrate 4800 as default";
	$dev .= "\@4800";
  }

  if(defined($opt)) {
    if($opt eq "noinit") {
      Log 1, "RFXCOM: $name no init is done";
      $attr{$name}{do_not_init} = 1;
    } else {
      return "wrong syntax: define <name> RFXCOM devicename [noinit]"
    }
  }
  
  
  $hash->{DeviceName} = $dev;
  my $ret = DevIo_OpenDev($hash, 0, "RFXCOM_DoInit");
  return $ret;
}

#####################################
# Input is hexstring
sub
RFXCOM_Write($$$)
{
  my ($hash,$fn,$msg) = @_;
  my $name = $hash->{NAME};
  my $ll5 = GetLogLevel($name,5);

  return if(!defined($fn));

  my $bstring;
  $bstring = "$fn$msg";
  Log $ll5, "$hash->{NAME} sending $bstring";

  DevIo_SimpleWrite($hash, $bstring, 1);
}

#####################################
sub
RFXCOM_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  foreach my $d (sort keys %defs) {
    if(defined($defs{$d}) &&
       defined($defs{$d}{IODev}) &&
       $defs{$d}{IODev} == $hash)
      {
        my $lev = ($reread_active ? 4 : 2);
        Log GetLogLevel($name,$lev), "deleting port for $d";
        delete $defs{$d}{IODev};
      }
  }

  DevIo_CloseDev($hash);
  return undef;
}

#####################################
sub
RFXCOM_Shutdown($)
{
  my ($hash) = @_;
  return undef;
}

#####################################
sub
RFXCOM_Set($@)
{
  my ($hash, @a) = @_;

  my $msg;
  my $name=$a[0];
  my $reading= $a[1];
  $msg="$name => No Set function ($reading) implemented";

  return $msg;
}

#####################################
sub
RFXCOM_Get($@)
{
  my ($hash, @a) = @_;

  my $msg;
  my $name=$a[0];
  my $reading= $a[1];
  $msg="$name => No Get function ($reading) implemented";
    Log 1,$msg;
    return $msg;
}

#####################################
sub
RFXCOM_SetState($$$$)
{
  my ($hash, $tim, $vt, $val) = @_;
  return undef;
}

sub
RFXCOM_Clear($)
{
  my $hash = shift;
  my $buf;

  # clear buffer:
  if($hash->{USBDev}) {
    while ($hash->{USBDev}->lookfor()) { 
    	$buf = DevIo_SimpleRead($hash);
    }
  }
  if($hash->{TCPDev}) {
   # TODO
    return $buf;
  }
}

#####################################
sub
RFXCOM_DoInit($)
{
  my $hash = shift;
  my $name = $hash->{NAME};
  my $err;
  my $msg = undef;
  my $buf;
  my $char = undef ;

  if(defined($attr{$name}) && defined($attr{$name}{"do_not_init"})) {
    	Log 1, "RFXCOM: defined with noinit. Do not send init string to device.";
  	$hash->{STATE} = "Initialized" if(!$hash->{STATE});

        # Reset the counter
        delete($hash->{XMIT_TIME});
        delete($hash->{NR_CMD_LAST_H});

	return undef;
  }

  RFXCOM_Clear($hash);

  #
  # Init
  my $init = pack('H*', 'F02C');
  DevIo_SimpleWrite($hash, $init, 0);
  sleep(1);

  $buf = DevIo_TimeoutRead($hash, 0.1);
  if (defined($buf)) { $char = ord($buf); }
  if (! $buf) {
    	Log 1, "RFXCOM: Initialization Error $name: no char read";
	return "RFXCOM: Initialization Error $name: no char read";
  } elsif ($char ne 0x2c) {
	my $hexline = unpack('H*', $buf);
    	Log 1, "RFXCOM: Initialization Error hexline='$hexline'";
	return "RFXCOM: Initialization Error %name expected char=0x2c, but char=$char received.";
  } else {
    	Log 1, "RFXCOM: Init OK";
  	$hash->{STATE} = "Initialized" if(!$hash->{STATE});
  }
  #

  # Reset the counter
  delete($hash->{XMIT_TIME});
  delete($hash->{NR_CMD_LAST_H});

  return undef;
}


#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub
RFXCOM_Read($)
{
  my ($hash) = @_;

  my $name = $hash->{NAME};

  my $char;

  my $mybuf = DevIo_SimpleRead($hash);

  if(!defined($mybuf) || length($mybuf) == 0) {
    DevIo_Disconnected($hash);
    return "";
  }

  my $rfxcom_data = $hash->{PARTIAL};
  #Log 5, "RFXCOM/RAW: $rfxcom_data/$mybuf";
  $rfxcom_data .= $mybuf;

  #my $hexline = unpack('H*', $rfxcom_data);
  #Log 1, "RFXCOM: RFXCOM_Read '$hexline'";

  # first char as byte represents number of bits of the message
  my $bits = ord(substr($rfxcom_data,0,1));
  my $num_bytes = $bits >> 3; if (($bits & 0x7) != 0) { $num_bytes++; }

  while(length($rfxcom_data) > $num_bytes) {
    # the buffer contains at least the number of bytes we need
    my $rmsg;
    $rmsg = substr($rfxcom_data, 0, $num_bytes+1);
    #my $hexline = unpack('H*', $rmsg);
    #Log 1, "RFXCOM_Read rmsg '$hexline'";
    $rfxcom_data = substr($rfxcom_data, $num_bytes+1);;
    #$hexline = unpack('H*', $rfxcom_data);
    #Log 1, "RFXCOM_Read rfxcom_data '$hexline'";
    #
    RFXCOM_Parse($hash, $hash, $name, unpack('H*', $rmsg));
    $bits = ord(substr($rfxcom_data,0,1));
    $num_bytes = $bits >> 3; if (($bits & 0x7) != 0) { $num_bytes++; }
  }
  #Log 1, "RFXCOM_Read END";

  $hash->{PARTIAL} = $rfxcom_data;
}


sub
RFXCOM_Parse($$$$)
{
  my ($hash, $iohash, $name, $rmsg) = @_;

  Log 5, "RFXCOM_Parse1 '$rmsg'";

  my %addvals;
  # Parse only if message is different within 2 seconds 
  # (some Oregon sensors always sends the message twice, X10 security sensors even sends the message five times)
  if (("$last_rmsg" ne "$rmsg") || (time() - $last_time) > 1) { 
    Log 5, "RFXCOM_Dispatch '$rmsg'";
    Dispatch($hash, $rmsg, \%addvals); 
    $hash->{"${name}_MSGCNT"}++;
    $hash->{"${name}_TIME"} = TimeNow();
    $hash->{RAWMSG} = $rmsg;
  } else { 
    #Log 1, "RFXCOM_Dispatch '$rmsg' dup";
    #Log 1, "<-duplicate->";
  }

  $last_rmsg = $rmsg;
  $last_time = time();

}


#####################################
sub
RFXCOM_Ready($)
{
  my ($hash) = @_;

  return DevIo_OpenDev($hash, 1, "RFXCOM_Ready")
                if($hash->{STATE} eq "disconnected");

  # This is relevant for windows/USB only
  my $po = $hash->{USBDev};
  my ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags) = $po->status;
  return ($InBytes>0);
}

1;
