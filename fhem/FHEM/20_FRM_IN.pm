########################################################################################
# $Id$
########################################################################################

=encoding UTF-8

=head1 NAME

FHEM module for one Firmata digial input pin

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2013 ntruchess
Copyright (C) 2018 jensb

All rights reserved

This script is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This script is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this script; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

A copy of the GNU General Public License, Version 2 can also be found at

http://www.gnu.org/licenses/old-licenses/gpl-2.0.

This copyright notice MUST APPEAR in all copies of the script!

=cut

package main;

use strict;
use warnings;

#add FHEM/lib to @INC if it's not already included. Should rather be in fhem.pl than here though...
BEGIN {
  if (!grep(/FHEM\/lib$/,@INC)) {
    foreach my $inc (grep(/FHEM$/,@INC)) {
      push @INC,$inc."/lib";
    };
  };
};

#####################################

# default values for Attr
my %sets = (
  "alarm" => "",
  "count" => 0,
);

# default values for Get
my %gets = (
  "reading" => "",
  "state"   => "",
  "count"   => 0,
  "alarm"   => "off"
);

sub FRM_IN_Initialize
{
  my ($hash) = @_;

  $hash->{SetFn}     = "FRM_IN_Set";
  $hash->{GetFn}     = "FRM_IN_Get";
  $hash->{AttrFn}    = "FRM_IN_Attr";
  $hash->{DefFn}     = "FRM_Client_Define";
  $hash->{InitFn}    = "FRM_IN_Init";
  $hash->{UndefFn}   = "FRM_Client_Undef";

  $hash->{AttrList}  = "IODev count-mode:none,rising,falling,both count-threshold reset-on-threshold-reached:yes,no internal-pullup:on,off activeLow:yes,no $main::readingFnAttributes";
  main::LoadModule("FRM");
}

sub FRM_IN_PinModePullupSupported
{
  my ($hash) = @_;
  my $iodev = $hash->{IODev};
  my $pullupPins = defined($iodev)? $iodev->{pullup_pins} : undef;

  return defined($pullupPins);
}

sub FRM_IN_Init
{
  my ($hash,$args) = @_;
  my $name = $hash->{NAME};

  if (defined($main::defs{$name}{IODev_ERROR})) {
    return 'Perl module Device::Firmata not properly installed';
  }

  if (FRM_IN_PinModePullupSupported($hash)) {
    my $pullup = AttrVal($name, "internal-pullup", "off");
    my $ret = FRM_Init_Pin_Client($hash,$args,defined($pullup) && ($pullup eq "on")? Device::Firmata::Constants->PIN_PULLUP : Device::Firmata::Constants->PIN_INPUT);
    return $ret if (defined $ret);
    eval {
      my $firmata = FRM_Client_FirmataDevice($hash);
      my $pin = $hash->{PIN};
      $firmata->observe_digital($pin,\&FRM_IN_observer,$hash);
    };
    if ($@) {
      my $ret = FRM_Catch($@);
      readingsSingleUpdate($hash, 'state', "error initializing: $ret", 1);
      return $ret;
    }
  } else {
    my $ret = FRM_Init_Pin_Client($hash, $args, Device::Firmata::Constants->PIN_INPUT);
    return $ret if (defined $ret);
    eval {
      my $firmata = FRM_Client_FirmataDevice($hash);
      my $pin = $hash->{PIN};
      if (defined(my $pullup = AttrVal($name, "internal-pullup", undef))) {
        $firmata->digital_write($pin,$pullup eq "on" ? 1 : 0);
      }
      $firmata->observe_digital($pin,\&FRM_IN_observer,$hash);
    };
    if ($@) {
      my $ret = FRM_Catch($@);
      readingsSingleUpdate($hash, 'state', "error initializing: $ret", 1);
      return $ret;
    }
  }

  if (!(defined AttrVal($name, "stateFormat", undef))) {
    $main::attr{$name}{"stateFormat"} = "reading";
  }

  main::readingsSingleUpdate($hash,"state","Initialized",1);

  return undef;
}

sub FRM_IN_observer
{
  my ($pin,$last,$new,$hash) = @_;
  my $name = $hash->{NAME};

  my $old = ReadingsVal($name, "reading", undef);
  if (defined($old)) {
    $old = $old eq "on" ? Device::Firmata::Constants->PIN_HIGH : Device::Firmata::Constants->PIN_LOW;
  }
  if (AttrVal($hash->{NAME},"activeLow","no") eq "yes") {
    $new = $new == Device::Firmata::Constants->PIN_LOW ? Device::Firmata::Constants->PIN_HIGH : Device::Firmata::Constants->PIN_LOW;
  }
  Log3 $name, 5, "$name: observer pin: $pin, old: ".(defined $old ? $old : "--").", new: ".(defined $new ? $new : "--");

  my $changed = !defined($old) || $old != $new;
  if ($changed) {
    main::readingsBeginUpdate($hash);
    if (defined (my $mode = main::AttrVal($name,"count-mode",undef))) {
      if (($mode eq "both")
      or (($mode eq "rising") and ($new == Device::Firmata::Constants->PIN_HIGH))
      or (($mode eq "falling") and ($new == Device::Firmata::Constants->PIN_LOW))) {
          my $count = main::ReadingsVal($name,"count",0);
          $count++;
          if (defined (my $threshold = main::AttrVal($name,"count-threshold",undef))) {
            if ( $count > $threshold ) {
              if (AttrVal($name,"reset-on-threshold-reached","no") eq "yes") {
                $count=0;
                main::readingsBulkUpdate($hash,"alarm","on",1);
              } elsif ( main::ReadingsVal($name,"alarm","off") ne "on" ) {
                main::readingsBulkUpdate($hash,"alarm","on",1);
              }
            }
          }
          main::readingsBulkUpdate($hash,"count",$count,1);
        }
    };
    main::readingsBulkUpdate($hash, "reading", $new == Device::Firmata::Constants->PIN_HIGH ? "on" : "off", 1);
    main::readingsEndUpdate($hash,1);
  }
}

sub FRM_IN_Set
{
  my ($hash, $name, $cmd, @a) = @_;

  return "set command missing" if(!defined($cmd));
  return "unknown set command '$cmd', choose one of " . join(" ", sort keys %sets) if(!defined($sets{$cmd}));
  return "$cmd requires 1 argument" unless (@a == 1);

  my $value = shift @a;
  COMMAND_HANDLER: {
    $cmd eq "alarm" and do {
      return undef if (!($value eq "off" or $value eq "on"));
      main::readingsSingleUpdate($hash,"alarm",$value,1);
      last;
    };
    $cmd eq "count" and do {
      main::readingsSingleUpdate($hash,"count",$value,1);
      last;
    };
  }
}

sub FRM_IN_Get
{
  my ($hash, $name, $cmd, @a) = @_;

  return "get command missing" if(!defined($cmd));
  return "unknown get command '$cmd', choose one of " . join(":noArg ", sort keys %gets) . ":noArg" if(!defined($gets{$cmd}));

  ARGUMENT_HANDLER: {
    $cmd eq "reading" and do {
      my $last;
      eval {
        if (defined($main::defs{$name}{IODev_ERROR})) {
          die 'Perl module Device::Firmata not properly installed';
        }
        $last = FRM_Client_FirmataDevice($hash)->digital_read($hash->{PIN});
        if (AttrVal($hash->{NAME},"activeLow","no") eq "yes") {
          $last = $last == Device::Firmata::Constants->PIN_LOW ? Device::Firmata::Constants->PIN_HIGH : Device::Firmata::Constants->PIN_LOW;
        }
      };
      if ($@) {
        my $ret = FRM_Catch($@);
        $hash->{STATE} = "get $cmd error: " . $ret;
        return $hash->{STATE};
      }
      return $last == Device::Firmata::Constants->PIN_HIGH ? "on" : "off";
    };

    ($cmd eq "count" or $cmd eq "alarm" or $cmd eq "state") and do {
      return main::ReadingsVal($name,$cmd,$gets{$cmd});
    };
  }

  return undef;
}

sub FRM_IN_Attr
{
  my ($command,$name,$attribute,$value) = @_;
  my $hash = $main::defs{$name};
  my $pin = $hash->{PIN};

  eval {
    if ($command eq "set") {
      ARGUMENT_HANDLER: {
        $attribute eq "IODev" and do {
          if ($main::init_done and (!defined ($hash->{IODev}) or $hash->{IODev}->{NAME} ne $value)) {
            FRM_Client_AssignIOPort($hash,$value);
            FRM_Init_Client($hash) if (defined ($hash->{IODev}));
          }
          last;
        };

        $attribute eq "count-mode" and do {
          if ($value ne "none" and !defined main::ReadingsVal($name,"count",undef)) {
            main::readingsSingleUpdate($main::defs{$name},"count",$sets{count},1);
          }
          last;
        };

        $attribute eq "reset-on-threshold-reached" and do {
          if ($value eq "yes"
          and defined (my $threshold = main::AttrVal($name,"count-threshold",undef))) {
            if (main::ReadingsVal($name,"count",0) > $threshold) {
              main::readingsSingleUpdate($main::defs{$name},"count",$sets{count},1);
            }
          }
          last;
        };

        $attribute eq "count-threshold" and do {
          if (main::ReadingsVal($name,"count",0) > $value) {
            main::readingsBeginUpdate($hash);
            if (main::ReadingsVal($name,"alarm","off") ne "on") {
              main::readingsBulkUpdate($hash,"alarm","on",1);
            }
            if (main::AttrVal($name,"reset-on-threshold-reached","no") eq "yes") {
              main::readingsBulkUpdate($main::defs{$name},"count",0,1);
            }
            main::readingsEndUpdate($hash,1);
          }
          last;
        };

        $attribute eq "internal-pullup" and do {
          if ($main::init_done) {
            if (defined($main::defs{$name}{IODev_ERROR})) {
              die 'Perl module Device::Firmata not properly installed';
            }
            my $firmata = FRM_Client_FirmataDevice($hash);
            if (FRM_IN_PinModePullupSupported($hash)) {
              $firmata->pin_mode($pin, $value eq "on"? Device::Firmata::Constants->PIN_PULLUP : Device::Firmata::Constants->PIN_INPUT);
            } else {
              $firmata->digital_write($pin,$value eq "on" ? 1 : 0);
              #ignore any errors here, the attribute-value will be applied next time FRM_IN_init() is called.
            }
          }
          last;
        };

        $attribute eq "activeLow" and do {
          my $oldval = AttrVal($hash->{NAME},"activeLow","no");
          if ($oldval ne $value) {
            $main::attr{$hash->{NAME}}{activeLow} = $value;
            if ($main::init_done) {
              if (defined($main::defs{$name}{IODev_ERROR})) {
                die 'Perl module Device::Firmata not properly installed';
              }
              my $firmata = FRM_Client_FirmataDevice($hash);
              FRM_IN_observer($pin,undef,$firmata->digital_read($pin),$hash);
            }
          };
          last;
        };
      }
    } elsif ($command eq "del") {
      ARGUMENT_HANDLER: {
        $attribute eq "internal-pullup" and do {
          if (defined($main::defs{$name}{IODev_ERROR})) {
            die 'Perl module Device::Firmata not properly installed';
          }
          my $firmata = FRM_Client_FirmataDevice($hash);
          if (FRM_IN_PinModePullupSupported($hash)) {
            $firmata->pin_mode($pin, Device::Firmata::Constants->PIN_INPUT);
          } else {
            $firmata->digital_write($pin,0);
          }
          last;
        };

        $attribute eq "activeLow" and do {
          if (AttrVal($hash->{NAME},"activeLow","no") eq "yes") {
            if (defined($main::defs{$name}{IODev_ERROR})) {
              die 'Perl module Device::Firmata not properly installed';
            }
            delete $main::attr{$hash->{NAME}}{activeLow};
            my $firmata = FRM_Client_FirmataDevice($hash);
            FRM_IN_observer($pin,undef,$firmata->digital_read($pin),$hash);
          };
          last;
        };
      }
    }
  };
  if ($@) {
    my $ret = FRM_Catch($@);
    $hash->{STATE} = "$command $attribute error: " . $ret;
    return $hash->{STATE};
  }
}

1;

=pod

=head1 CHANGES

  15.02.2019 jensb
    o bugfix: change detection no longer assumes that reading "reading" is defined

  04.11.2018 jensb
    o bugfix: get alarm/reading/state
    o feature: remove unused FHEMWEB input field from all get commands
    o feature: @see https://forum.fhem.de/index.php/topic,81815.msg842557.html#msg842557
               - use current FHEM reading instead of perl-firmata "old" value to improve change detection
               - only update reading on change to filter updates by other pins on same Firmata digital port

  03.01.2018 jensb
    o implemented Firmata 2.5 feature PIN_MODE_PULLUP (requires perl-firmata 0.64 or higher)

  24.08.2020 jensb
    o check for IODev install error in Init, Get and Attr
    o prototypes removed
    o set argument verifier improved

  19.10.2020 jensb
    o annotaded module help of attributes for FHEMWEB

=cut


=pod

=head1 FHEM COMMANDREF METADATA

=over

=item device

=item summary Firmata: digital input

=item summary_DE Firmata: digitaler Eingang

=back

=head1 INSTALLATION AND CONFIGURATION

=begin html

<a name="FRM_IN"/>
<h3>FRM_IN</h3>
<ul>
  This module represents a pin of a <a href="http://www.firmata.org">Firmata device</a>
  that should be configured as a digital input.<br><br>

  Requires a defined <a href="#FRM">FRM</a> device to work. The pin must be listed in
  the internal reading <a href="#FRMinternals">"input_pins" or "pullup_pins"</a>
  of the FRM device (after connecting to the Firmata device) to be used as digital input with or without pullup.<br><br>

  <a name="FRM_INdefine"/>
  <b>Define</b>
  <ul>
  <code>define &lt;name&gt; FRM_IN &lt;pin&gt;</code> <br>
  Defines the FRM_IN device. &lt;pin&gt> is the Firmata pin to use.
  </ul>

  <br>
  <a name="FRM_INset"/>
  <b>Set</b><br>
  <ul>
    <li>alarm on|off<br>
    set the 'alarm' reading to on or off. Typically used to clear the alarm.
    The alarm is set to 'on' whenever the count reaches the threshold and doesn't clear itself.</li>
    <li>count <number><br>
    set the 'count' reading to a specific value.
    The counter is incremented depending on the attribute 'count-mode'.</li>
  </ul><br>

  <a name="FRM_INget"/>
  <b>Get</b>
  <ul>
    <li>reading<br>
    returns the logical state of the input pin last received from the Firmata device depending on the attribute 'activeLow'.
    Values are 'on' and 'off'.<br></li>
    <li>count<br>
    returns the current counter value. Contains the number of toggles reported by the Fimata device on this input pin.
    Depending on the attribute 'count-mode' every rising or falling edge (or both) is counted.</li>
    <li>alarm<br>
    returns the 'alarm' reading. Values are 'on' and 'off' (Defaults to 'off').
    The 'alarm' reading doesn't clear itself, it has to be set to 'off' explicitly.</li>
    <li>state<br>
    returns the 'state' reading</li>
  </ul><br>

  <a name="FRM_INattr"/>
  <b>Attributes</b><br>
  <ul>
    <a name="activeLow"/>
    <li>activeLow yes|no<br>
    inverts the logical state of the pin reading if set to yes (defaults to 'no').
    </li>

    <a name="count-mode"/>
    <li>count-mode none|rising|falling|both<br>
    Determines whether 'rising' (transitions from 'off' to 'on') of falling (transitions from 'on' to 'off')
    edges (or 'both') are counted (defaults to 'none').
    </li>

    <a name="count-threshold"/>
    <li>count-threshold &lt;number&gt;<br>
    sets the threshold-value for the counter - if defined whenever 'count' exceeds the 'count-threshold'
    the 'alarm' reading is set to 'on' (defaults to undefined). Use 'set alarm off' to clear the alarm.
    </li>

    <a name="reset-on-threshold-reached"/>
    <li>reset-on-threshold-reached yes|no<br>
    if set to 'yes' reset the counter to 0 when the threshold is reached (defaults to 'no').
    </li>

    <a name="internal-pullup"/>
    <li>internal-pullup on|off<br>
    enables/disables the internal pullup resistor of the Firmata pin (defaults to 'off'). Requires hardware
    and firmware support.
    </li>

    <a name="IODev"/>
    <li><a href="#IODev">IODev</a><br>
    Specify which <a href="#FRM">FRM</a> to use. Only required if there is more than one FRM-device defined.
    </li>

    <li><a href="#attributes">global attributes</a></li>

    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul><br>

  <a name="FRM_INnotes"/>
  <b>Notes</b><br>
  <ul>
      <li>attribute <i>stateFormat</i><br>
      In most cases it is a good idea to assign "reading" to the attribute <i>stateFormat</i>. This will show the state
      of the pin in the web interface.
      </li>
      <li>attribute <i>count-mode</i><br>
      The count-mode does not depended on hardware or firmware of the Firmata device because it is implemented in FHEM. The counter will not be updated while the Firmata device is not connected to FHEM. Any changes of the pin state during this time will be lost.
      </li>
  </ul>
</ul><br>

=end html

=begin html_DE

<a name="FRM_IN"/>
<h3>FRM_IN</h3>
<ul>
  Die Modulbeschreibung von FRM_IN gibt es nur auf <a href="commandref.html#FRM_IN">Englisch</a>. <br>
</ul> <br>

=end html_DE

=cut
