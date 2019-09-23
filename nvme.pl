#! /usr/bin/perl
# -*- mode: perl; perl-indent-level: 4 -*-

=head1 NAME

nvme - Munin plugin to monitor the use of NVMe devices

=head1 APPLICABLE SYSTEMS

Linux systems with NVMe (Non-Volatile Memory storage attached via PCIe
bus).

=head1 CONFIGURATION

The plugin uses nvme(1) from the nvme-cli project to read status from
the NVMe devices.  This requires root access.

  [nvme]
     user root

The plugin does not support alerting.

=head1 INTERPRETATION

This is a multigraph plugin which makes three graphs.

=head2 nvme_usage

This reports how much of capacity is allocated in each NVMe
"namespace".  The report is in percent.  This number may not have much
relation to actual use, e.g., if deleted data areas have not been
trimmed/discarded.

=head2 nvme_bytes

This reports read and write activity on each NVMe device, in bytes per
second.  Ideally there should be much more read than write.  If they
are symmetrical, you are using your NVMe as a very expensive FIFO, and
if you write more than you read, you should probably look for archival
storage instead.

It is a good idea to compare these numbers to I/O counters from
diskstats.  If they are much higher, look into whether the write
amplification can be due to suboptimal I/O request sizes.

=head2 nvme_writecycles

This graphs is intended to give an indication of how much life there
is left in your NVMe.  It calculates the number of bytes written
during each device's lifetime against the capacity of the device,
thereby getting an average number of write cycle each cell has
experienced.

A prosumer NVMe will handle a few thousand writes to each cell before
the error rate gets out of hand.

=head2 nvme_temperatures

Reports T1 and T2 temperatures of Samsung SSDs

=head1 MAGIC MARKERS

  #%# family=auto
  #%# capabilities=autoconf

=head1 BUGS

None known.

=head1 VERSION

  1.0

=head1 AUTHOR

Kjetil Torgrim Homme <kjetil.homme@redpill-linpro.com>

=head1 LICENSE

GPLv2

=cut

use strict;
use Munin::Plugin;
use IPC::Cmd qw(can_run);

# Check that multigraph is supported
need_multigraph();

# Return undef if no problem, otherwise explanation
sub autoconf_problem {
    return if can_run('nvme');
    if (open(my $mods, '/proc/modules')) {
        while (<$mods>) {
            return "missing nvme(1)" if /^nvme[^a-z]/;
        }
        close($mods);
    }
    return "missing nvme";    # vague message for non-Linux
}

sub run_nvme {
    my (@cmd) = @_;
    my @lines;
    if (can_run('nvme') && open(my $nvme, '-|', 'nvme', @cmd)) {
        @lines = <$nvme>;
        close($nvme);
        warn "nvme: probably needs to run as user root\n" if $? && $> != 0;
    }
    @lines;
}

sub human_to_bytes {
    my ($str) = @_;
    my %units = (
        kB => 1000,
        MB => 1000_000,
        GB => 1000_000_000,
        TB => 1000_000_000_000,
        PB => 1000_000_000_000_000,    # I wish I had need for this
    );
    $str =~ /(\d+(\.\d+)?)\s+(.B)/;
    int($1 * $units{$3});
}

sub nvme_list {
    # Node             SN                   Model                                    Namespace Usage                      Format           FW Rev
    # ---------------- -------------------- ---------------------------------------- --------- -------------------------- ---------------- --------
    # /dev/nvme1n1     S464NB0K601188N      Samsung SSD 970 EVO 2TB                  1         695.50  GB /   2.00  TB    512   B +  0 B   1B2QEXE7
    my %devices;

    my $recognised_output;
    my $lineno = 0;
    for (run_nvme('list')) {
        ++$lineno;
        if (m:^Node\s+SN\s+Model\s+Namespace Usage:) {
            ++$recognised_output;
        } elsif (m:^(/\S+)\s+(\S+)\s+(\S.*\S)\s{3,}(\d+)\s+(\S+\s+.B)\s+/\s+(\S+\s+.B):) {
            $devices{$2} = {
                device    => $1,
                sn        => $2,
                model     => $3,
                namespace => $4,
                usage     => human_to_bytes($5),
                capacity  => human_to_bytes($6),
            };
        } elsif ($lineno > 2) {
            # could not parse device information
            $recognised_output = 0;
        }
    }
    if ($lineno && !$recognised_output) {
        warn "Could not recognise output from 'nvme list', please report\n";
    }
    \%devices;
}

sub smart_log {
    my ($dev) = @_;
    my %info;
    for (run_nvme('smart-log', $dev)) {
        next if /^Smart Log/;
        if (/(.*?)\s+:\s+(.*)/) {
            my ($var, $value) = ($1, $2);
            $var =~ s/\s/_/g;
            if ($value =~ /^\d+(,\d\d\d)+$/) {
                $value =~ s/,//g;
            }
            $info{lc $var} = $value;
        }
    }
    return \%info;
}

use Data::Dumper;

my $mode = ($ARGV[0] or "print");

my $problem = autoconf_problem();
my $list    = nvme_list();

if ($mode eq 'autoconf') {
    if (keys %{$list}) {
        print "yes\n";
    } else {
        printf("no (%s)\n", $problem || "no devices to monitor");
    }
    exit 0;
}

my @sn = sort keys %{$list};

if ($mode eq 'config') {
    my $sn_list = join(' ', @sn);

    print <<'EOF';
multigraph nvme_usage
graph_title NVME Namespace Usage
graph_order $sn_list
graph_vlabel Percent used
graph_scale no
graph_category disk
graph_info How much space is used
EOF
    for (@sn) {
        print <<"EOF";
$_.label $list->{$_}->{device} used
$_.type GAUGE
$_.max 100
$_.min 0
EOF
    }
    print <<'EOF';
multigraph nvme_bytes
graph_title NVME Bytes Read / Written
graph_order $sn_list
graph_vlabel bytes read (-) / written (+) per ${graph_period}'
graph_category disk
graph_info How much data is read and written
graph_period second
EOF
    for (@sn) {
        print <<"EOF";
${_}_r.label $list->{$_}->{device}
${_}_r.type DERIVE
${_}_r.min 0
${_}_r.graph no
${_}_w.label $list->{$_}->{device}
${_}_w.type DERIVE
${_}_w.min 0
${_}_w.negative ${_}_r
EOF
    }
    print <<'EOF';
multigraph nvme_writecycles
graph_title NVME Write Cycles
graph_order $sn_list
graph_vlabel Cycles
graph_args --logarithmic
graph_category disk
graph_info How much data has been written in lifetime divided by capacity
EOF
    for (@sn) {
        print <<"EOF";
$_.label $list->{$_}->{device} write cycles
$_.type GAUGE
$_.min 0
EOF
    }
 print <<'EOF';
multigraph nvme_temperatures
graph_title NVME Temps T1 / T2
graph_order $sn_list
graph_vlabel Temperature T1 (-) / T2 (+)'
graph_category disk
graph_info What are the disk temperatures

EOF
    for (@sn) {
        print <<"EOF";
${_}_r.label $list->{$_}->{device}
${_}_r.type GAUGE
${_}_r.min 0
${_}_r.graph no
${_}_w.label $list->{$_}->{device}
${_}_w.type GAUGE
${_}_w.min 0
${_}_w.negative ${_}_r
EOF
    }    
} else {
    for (@sn) {
        $list->{$_}->{smart} = smart_log($list->{$_}->{device});
    }
    print "multigraph nvme_usage\n";
    for (@sn) {
        my $info = $list->{$_};
        my $used = 100 * $info->{usage} / $info->{capacity};
        print "$_.value $used\n";
    }
    print "multigraph nvme_bytes\n";
    for (@sn) {
        my $info   = $list->{$_};
        my $rbytes = $info->{smart}->{data_units_read};
        my $wbytes = $info->{smart}->{data_units_written};
        print "${_}_r.value $rbytes\n";
        print "${_}_w.value $wbytes\n";
    }
     print "multigraph nvme_temperatures\n";
    for (@sn) {
        my $info   = $list->{$_};
        my $t1 = $info->{smart}->{temperature_sensor_1};
        my $t2 = $info->{smart}->{temperature_sensor_2};
        $t1 =~ s/C$//;
        $t2 =~ s/C$//;
        $t1 =~ s/^\s+|\s+$//g;
        $t2=~ s/^\s+|\s+$//g;
        print "${_}_r.value $t1\n";
        print "${_}_w.value $t2\n";
    }
    print "multigraph nvme_writecycles\n";
    for (@sn) {
        my $info = $list->{$_};

        # The unit size reported is 1000 blocks.
        my $cycles = $info->{smart}->{data_units_read} * 512_000 / $info->{capacity};
        print "$_.value $cycles\n";
    }
}
