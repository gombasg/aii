#${PMpre} NCM::Component::pxelinux${PMpost}

use Sys::Hostname;
use CAF::FileWriter;
use CAF::Object qw(SUCCESS CHANGED);
use NCM::Component::ks qw (ksuserhooks);
use LC::Fatal qw (symlink);
use File::stat;
use File::Basename qw(dirname);
use Time::localtime;
use Readonly;

use parent qw (NCM::Component CAF::Path);

use constant PXEROOT => "/system/aii/nbp/pxelinux";
use constant HOSTNAME => "/system/network/hostname";
use constant DOMAINNAME => "/system/network/domainname";
use constant INTERFACES => "/system/network/interfaces";

# Kickstart constants (trying to use same name as in ks.pm from aii-ks)
use constant KS => "/system/aii/osinstall/ks";

# Lowest supported version is EL 5.0
use constant ANACONDA_VERSION_EL_5_0 => version->new("11.1");
use constant ANACONDA_VERSION_EL_6_0 => version->new("13.21");
use constant ANACONDA_VERSION_EL_7_0 => version->new("19.31");
use constant ANACONDA_VERSION_LOWEST => ANACONDA_VERSION_EL_5_0;

# Import PXE-related constants shared with other modules
use NCM::Component::PXELINUX::constants qw(:all);

# Support PXE variants and their parameters (currently PXELINUX and Grub2)
# 'name' is a descriptive name for information/debugging messages
Readonly my %GRUB2_VARIANT_PARAMS => (name => 'Grub2',
                                      nbpdir_opt => NBPDIR_GRUB2,
                                      kernel_root_path => GRUB2_EFI_KERNEL_ROOT,
                                      format_method => \&write_grub2_config);
Readonly my %PXELINUX_VARIANT_PARAMS => (name => 'PXELINUX',
                                         nbpdir_opt => NBPDIR_PXELINUX,
                                         kernel_root_path => '',
                                         format_method => \&write_pxelinux_config);
# Element in @VARIANT_PARAMS must be in the same order as enum PXE_VARIANT_xxx
Readonly my @VARIANT_PARAMS => (\%PXELINUX_VARIANT_PARAMS, \%GRUB2_VARIANT_PARAMS);

our $EC = LC::Exception::Context->new->will_store_all;
our $this_app = $main::this_app;


# Check if a configuration option exists
sub option_exists
{
    my ($option) = @_;
    return $this_app->{CONFIG}->_exists($option);
}

# Return the value of a variant attribute.
# Attribute can be any valid key in one of the xxx_VARIANT_PARAMS
sub variant_attribute
{
    my ($attribute, $variant) = @_;
    return $VARIANT_PARAMS[$variant]->{$attribute};
}

# Return a configuration option value for a given variant.
# First argument is a variant attribute that will be interpreted
# as a configuration option.
sub variant_option
{
    my ($attribute, $variant) = @_;
    return $this_app->option (variant_attribute($attribute, $variant));
}

# Test if a variant is enabled
# A variant is enabled if the configuration option defined in its 'nbpdir' 
# attribute is defined and is not 'none'
sub variant_enabled
{
    my ($variant) = @_;
    my $nbpdir = variant_attribute('nbpdir_opt', $variant);
    $this_app->debug(2, "Using option '$nbpdir' to check if variant ", variant_attribute('name',$variant), " is enabled");
    my $enabled = option_exists($nbpdir) &&
                  ($this_app->option($nbpdir) ne NBPDIR_VARIANT_DISABLED);
    return $enabled;
}


# Return the fqdn of the node
sub get_fqdn
{
    my $cfg = shift;
    my $h = $cfg->getElement (HOSTNAME)->getValue;
    my $d = $cfg->getElement (DOMAINNAME)->getValue;
    return "$h.$d";
}

# return the anaconda version instance as specified in the kickstart (if at all)
sub get_anaconda_version
{
    my $kst = shift;
    my $version = ANACONDA_VERSION_LOWEST;
    if ($kst->{version}) {
        $version = version->new($kst->{version});
        if ($version < ANACONDA_VERSION_LOWEST) {
            # TODO is this ok, or should we stop?
            $this_app->error("Version $version < lowest supported ".ANACONDA_VERSION_LOWEST.", continuing with lowest");
            $version = ANACONDA_VERSION_LOWEST;
        }
    };
    return $version;
}

# Retuns the IP-based PXE file name, based on the PXE variant
sub hexip_filename
{
    my ($ip, $variant) = @_;

    my $hexip_str = '';
    if ( $ip =~ m/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ ) {
        $hexip_str = sprintf ("%02X%02X%02X%02X", $1, $2, $3, $4);
        if ( $variant eq PXE_VARIANT_GRUB2 ) {
            $hexip_str = "grub.cfg-$hexip_str";
        } elsif ( $variant ne PXE_VARIANT_PXELINUX ) {
            $this_app->error("Internal error: invalid PXE variant ($variant)");
        }
    } else {
        $this_app->error("Invalid IPv4 address ($ip)");
    }

    return $hexip_str;
}

# Returns the absolute path of the PXE config file for the current host, based on the PXE variant
sub filepath
{
    my ($cfg, $variant) = @_;

    my $fqdn = get_fqdn($cfg);
    my $dir = variant_option('nbpdir_opt', $variant);
    $this_app->debug(2, "NBP directory (PXE variant=", variant_attribute('name',$variant), ") = $dir");
    return "$dir/$fqdn.cfg";
}

# Returns the absolute path of the PXE file to link to, based on the PXE variant
sub link_filepath
{
    my ($cfg, $cmd, $variant) = @_;

    my $dir = variant_option('nbpdir_opt', $variant);

    my $cfgpath = PXEROOT . "/" . $cmd;
    if ($cfg->elementExists ($cfgpath)) {
        my $linkname = $cfg->getElement ($cfgpath)->getValue;
        return "$dir/$linkname";
    } elsif ($cmd eq RESCUE) {
        # Backwards compatibility: use the option set on the command line
        # if the profile does not define a rescue image
        my $path = $this_app->option (RESCUEBOOT);
        unless ($path =~ m{^([-.\w]+)$}) {
            $this_app->error ("Unexpected RESCUE configuration file");
        }
        return "$dir/$1";
    } else {
        my $fqdn = get_fqdn($cfg);
        $this_app->debug(2, "No $cmd defined for $fqdn");
    }
    return undef;
}


# Configure the ksdevice with a static IP
# (EL7+ only)
sub pxe_ks_static_network
{
    my ($config, $dev) = @_;

    my $fqdn = get_fqdn($config);

    my $bootdev = $dev;

    my $net = $config->getElement("/system/network/interfaces/$dev")->getTree;

    # check for bridge: if $dev is a bridge interface,
    # continue with network settings on the bridge device
    if ($net->{bridge}) {
        my $brdev = $net->{bridge};
        $this_app->debug (2, "Device $dev is a bridge interface for bridge $brdev.");
        # continue with network settings for the bridge device
        $net = $config->getElement("/system/network/interfaces/$brdev")->getTree;
        # warning: $dev is changed here to the bridge device to create correct log
        # messages in remainder of this method. as there is not bridge device
        # in anaconda phase, the new value of $dev is not an actual network device!
        $dev = $brdev;
    }

    unless ($net->{ip}) {
            $this_app->error ("Static boot protocol specified ",
                              "but no IP given to the interface $dev");
            return;
    }

    # can't set MTU with static ip via PXE

    my $gw;
    if ($net->{gateway}) {
        $gw = $net->{gateway};
    } elsif ($config->elementExists ("/system/network/default_gateway")) {
        $gw = $config->getElement ("/system/network/default_gateway")->getValue;
    } else {
        # This is a recipe for disaster
        # No best guess here
        $this_app->error ("No gateway defined for dev $dev and ",
                          " using static network description.");
        return;
    };

    return "$net->{ip}::$gw:$net->{netmask}:$fqdn:$bootdev:none";
}


# create the network bonding parameters (if any)
sub pxe_network_bonding {
    my ($config, $tree, $dev) = @_;

    my $dev_exists = $config->elementExists("/system/network/interfaces/$dev");
    my $dev_invalid = $dev =~ m!(?:[0-9a-f]{2}(?::[0-9a-f]{2}){5})|bootif|link!i;
    # should not be disabled, generate detailed logging instead of immediately returning
    my $bonding_disabled = exists($tree->{bonding}) && (! $tree->{bonding});

    my $logerror = "error";
    my $bonding_cfg_msg = "";
    if (! exists($tree->{bonding})) {
        $bonding_cfg_msg = "Bonding config generation not defined, continuing best-effort";
        $logerror = "verbose";
    } elsif ($bonding_disabled) {
        $bonding_cfg_msg = "Bonding config generation explicitly disabled";
        $logerror = "verbose";
        $this_app->$logerror($bonding_cfg_msg);
    }

    if (! $dev_exists) {
        if ($dev_invalid) {
            $this_app->$logerror("Invalid ksdevice $dev for bonding network configuration. $bonding_cfg_msg");
        } else {
            $this_app->$logerror("ksdevice $dev for bonding network configuration has no matching interface. $bonding_cfg_msg");
        }
        return;
    }

    my $net = $config->getElement("/system/network/interfaces/$dev")->getTree;

    # check for bonding
    # if bonding not defined, assume it's allowed
    my $bonddev = $net->{master};

    # check the existence to deal with older profiles
    if ($bonding_disabled) {
        # lets hope you know what you are doing
        $this_app->warn ("$bonding_cfg_msg for dev $dev, with master $bonddev set.") if ($bonddev);
        return;
   } elsif ($bonddev) {
        # this is the dhcp code logic; adding extra error here.
        if (!($net->{bootproto} && $net->{bootproto} eq "none")) {
            $this_app->error("Pretending this a bonded setup with bonddev $bonddev (and ksdevice $dev).",
                             "But bootproto=none is missing, so ncm-network will not treat it as one.");
        }
        $this_app->debug (5, "Ksdevice $dev is a bonding slave, node will boot from bonding device $bonddev");

        # bond network config
        $net = $config->getElement("/system/network/interfaces/$bonddev")->getTree;

        # gather the slaves, the ksdevice is put first
        my @slaves;
        push(@slaves, $dev);
        my $intfs = $config->getElement("/system/network/interfaces")->getTree;
        for my $intf (sort keys %$intfs) {
            push (@slaves, $intf) if ($intfs->{$intf}->{master} &&
                                      $intfs->{$intf}->{master} eq $bonddev &&
                                      !(grep { $_ eq $intf } @slaves));
        };

        my $bondtxt = "bond=$bonddev:". join(',', @slaves);
        # gather the options
        if ($net->{bonding_opts}) {
            my @opts;
            while (my ($k, $v) = each(%{$net->{bonding_opts}})) {
                push(@opts, "$k=$v");
            }
            $bondtxt .= ":". join(',', @opts);
        }

        return ($bonddev, $bondtxt);

    }

}


# create a list with all append options for kickstart installations
sub pxe_ks_append
{
    my $cfg = shift;

    my $t = $cfg->getElement (PXEROOT)->getTree;

    my $kst = {}; # empty hashref in case no kickstart is defined
    $kst = $cfg->getElement (KS)->getTree if $cfg->elementExists(KS);

    my $version = get_anaconda_version($kst);

    my $keyprefix = "";
    my $ksdevicename = "ksdevice";
    if($version >= ANACONDA_VERSION_EL_7_0) {
        $keyprefix="inst.";

        if($t->{ksdevice} =~ m/^(bootif|link)$/ &&
            ! $cfg->elementExists("/system/network/interfaces/$t->{ksdevice}")) {
            $this_app->warn("Using deprecated legacy behaviour. Please look into the configuration.");
        } else {
            $ksdevicename = "bootdev";
        }
    }

    my $ksloc = $t->{kslocation};
    my $server = hostname();
    $ksloc =~ s{LOCALHOST}{$server};

    my @append;
    push(@append,
         "ramdisk=32768",
         "initrd=$t->{initrd}",
         "${keyprefix}ks=$ksloc",
         );

    my $ksdev = $t->{ksdevice};
    if ($version >= ANACONDA_VERSION_EL_6_0) {
        # bond support in pxelinunx config
        # (i.e using what device will the ks file be retrieved).
        my ($bonddev, $bondingtxt) = pxe_network_bonding($cfg, $kst, $ksdev);
        if ($bonddev) {
            $ksdev = $bonddev;
            push (@append, $bondingtxt);
        }
    }

    push(@append, "$ksdevicename=$ksdev");

    if ($t->{updates}) {
        push(@append,"${keyprefix}updates=$t->{updates}");
    };

    if ($kst->{logging} && $kst->{logging}->{host}) {
        push(@append, "${keyprefix}syslog=$kst->{logging}->{host}:$kst->{logging}->{port}");
        push(@append, "${keyprefix}loglevel=$kst->{logging}->{level}") if $kst->{logging}->{level};
    }

    if ($version >= ANACONDA_VERSION_EL_7_0) {
        if ($kst->{enable_sshd}) {
            push(@append, "${keyprefix}sshd");
        };

        if ($kst->{cmdline}) {
            push(@append, "${keyprefix}cmdline");
        };

        if ($t->{setifnames}) {
            # set all interfaces names to the configured macaddress
            my $nics = $cfg->getElement ("/hardware/cards/nic")->getTree;
            foreach my $nic (keys %$nics) {
                push (@append, "ifname=$nic:".$nics->{$nic}->{hwaddr}) if ($nics->{$nic}->{hwaddr});
            }
        }

        if($kst->{bootproto} eq 'static') {
            if ($ksdev =~ m/^((?:(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2})|bootif|link)$/i) {
                $this_app->error("Invalid ksdevice $ksdev for static ks configuration.");
            } else {
                my $static = pxe_ks_static_network($cfg, $ksdev);
                push(@append,"ip=$static") if ($static);
            }
        } elsif ($kst->{bootproto} =~ m/^(dhcp6?|auto6|ibft)$/) {
            push(@append,"ip=$kst->{bootproto}");
        }

        my $nms = $cfg->getElement("/system/network/nameserver")->getTree;
        foreach my $ns (@$nms) {
            push(@append,"nameserver=$ns");
        }
    }

    my $custom_append = $t->{append};
    if ($custom_append) {
	    $custom_append =~ s/LOCALHOST/$server/g;
	    push @append, $custom_append;
    }
    
    return @append;    
}

# create a list with all append options
sub pxe_append
{
    my $cfg = shift;

    if ($cfg->elementExists(KS)) {
        return pxe_ks_append($cfg);
    } else {
        $this_app->error("Unclear how to create the append options. Not using any options.");
        return;
    }
}

# Write the PXELINUX configuration file.
sub write_pxelinux_config
{
    my $cfg = shift;
    my $pxe_config = $cfg->getElement (PXEROOT)->getTree;
    my $fh = CAF::FileWriter->open (filepath ($cfg, PXE_VARIANT_PXELINUX),
                    log => $this_app, mode => 0644);

    my $appendtxt = '';
    my @appendoptions = pxe_append($cfg);
    $appendtxt = join(" ", "append", @appendoptions) if @appendoptions;

    my $entry_label = "Install $pxe_config->{label}";
    print $fh <<EOF;
# File generated by pxelinux AII plug-in.
# Do not edit.
default $entry_label
    label $entry_label
    kernel $pxe_config->{kernel}
    $appendtxt
EOF

    # TODO is ksdevice still mandatory? if not, fix schema (code is already ok)
    # ksdecvice=bootif is an anaconda-ism, but can serve general purpose
    $fh->print ("    ipappend 2\n") if ($pxe_config->{ksdevice} && $pxe_config->{ksdevice} eq 'bootif');
    $fh->close();
}


# Write the Grub2 configuration file.
# Return 1 if the file was written successfully, 0 otherwise.
# TODO: handle append options?
sub write_grub2_config
{
    my $cfg = shift;
    my $pxe_config = $cfg->getElement (PXEROOT)->getTree;

    my $linux_cmd = $this_app->option(GRUB2_EFI_LINUX_CMD);
    unless ( $linux_cmd ) {
        $this_app->error("AII option ".GRUB2_EFI_LINUX_CMD." undefined");
        return 0;
    };
    my $initrd_cmd = $this_app->option(GRUB2_EFI_INITRD_CMD);
    unless ( $initrd_cmd ) {
        $this_app->error("AII option ".GRUB2_EFI_INITRD_CMD." undefined");
        return 0;
    };
    my $kernel_root = '';
    if ( option_exists(GRUB2_EFI_KERNEL_ROOT) ) {
        $kernel_root = $this_app->option(GRUB2_EFI_KERNEL_ROOT);
    }
    my $kernel_path = "$kernel_root/$pxe_config->{kernel}";
    my $initrd_path = "$kernel_root/$pxe_config->{initrd}";

    my $fh = CAF::FileWriter->open (filepath ($cfg, PXE_VARIANT_GRUB2),
                                    log => $this_app, mode => 0644);
    print $fh <<EOF;
# File generated by pxelinux AII plug-in.
# Do not edit.
set default=0
set timeout=2
menuentry "Install $pxe_config->{label}" {
    set root=(pxe)
    $linux_cmd $kernel_path ks=$pxe_config->{kslocation} ksdevice=$pxe_config->{ksdevice}
    $initrd_cmd $initrd_path
    }
}
EOF

    # TODO: add specific processing of ksdevice=bootif as for PXELINUX?
    $fh->close();

    return 1;
}


# Creates a symbolic link for PXE. This means creating a symlink named
# after the node's IP in hexadecimal to a PXE file.
# Returns 1 on succes, 0 otherwise.
sub pxelink
{
    my ($cfg, $cmd, $variant) = @_;

    my $interfaces = $cfg->getElement (INTERFACES)->getTree;
    my $path;
    if (!$cmd) {
        $path = $this_app->option (LOCALBOOT);
        $this_app->debug (5, "Configuring on $path");
    } elsif ($cmd eq BOOT) {
        $path = $this_app->option (LOCALBOOT);
        unless ($path =~ m{^([-.\w]+)$}) {
            $this_app->error ("Unexpected BOOT configuration file");
            return 0;
        }
        $path = $1;
        $this_app->debug (5, "Local booting from $path");
    } elsif ($cmd eq RESCUE || $cmd eq LIVECD || $cmd eq FIRMWARE) {
        $path = link_filepath($cfg, $cmd, $variant);
        if (! $self->file_exists($path) ) {
            my $fqdn = get_fqdn($cfg);
            $this_app->error("Missing $cmd config file for $fqdn: $path");
            return 0;
        }
        $this_app->debug (5, "Using $cmd from: $path");
    } elsif ($cmd eq INSTALL) {
        $path = filepath ($cfg, $variant);
        $this_app->debug (5, "Installing on $path");
    } else {
        $this_app->debug (5, "Unknown command");
        return 0;
    }
    # Set the same settings for every network interface that has a
    # defined IP address.
    foreach my $st (values (%$interfaces)) {
        next unless $st->{ip};
        my $dir = variant_option('nbpdir_opt', $variant);
        my $lnname = "$dir/".hexip_filename ($st->{ip}, $variant);
        if ($cmd || ! -l $lnname) {
            if ($CAF::Object::NoAction) {
                $this_app->info ("Would symlink $path to $lnname");
            } else {
                unlink ($lnname);
                # This must be stripped to work with chroot'ed environments.
                $path =~ s{$dir/?}{};
                symlink ($path, $lnname);
            }
        }
    }

    return 1;
}


# Wrapper function to call ksuserhooks() from aii-ks module.
# The only role of this function is to ensure that ksuserhooks()
# is always called the same way (in particular for NoAction
# handling). Be sure to use it!
sub exec_userhooks {
    my ($cfg, $hook_path) = @_;

    ksuserhooks ($cfg, $hook_path) unless $CAF::Object::NoAction;
}


# Prints the status of the node.
# Display information for both PXELINUX and Grub2 variant.

sub Status
{
    my ($self, $cfg) = @_;

    my $interfaces = $cfg->getElement (INTERFACES)->getTree;

    foreach my $variant (PXE_VARIANT_PXELINUX, PXE_VARIANT_GRUB2) {
        my $dir = variant_option('nbpdir_opt', $variant);
        my $boot = $this_app->option (LOCALBOOT);
        my $fqdn = get_fqdn($cfg);
        my $rescue = link_filepath($cfg, RESCUE, $variant);
        my $firmware = link_filepath($cfg, FIRMWARE, $variant);
        my $livecd = link_filepath($cfg, LIVECD, $variant);
        foreach my $interface (sort(values(%$interfaces))) {
            next unless $interface->{ip};
            my $ln = hexip_filename ($interface->{ip}, $variant);
            my $since = "unknown";
            my $st;
            if (-l "$dir/$ln") {
                $since = ctime(lstat("$dir/$ln")->ctime());
                my $name = readlink ("$dir/$ln");
                my $name_path = "$dir/$name";
                if (! -e $name_path) {
                    $st = "broken";
                } elsif ($name =~ m{^(?:.*/)?$fqdn\.cfg$}) {
                    $st = "install";
                } elsif ($name =~ m{^$boot$}) {
                    $st = "boot";
                } elsif ($firmware && ($name_path =~ m{$firmware})) {
                    $st = "firmware";
                } elsif ($livecd && ($name_path =~ m{$livecd})) {
                    $st = "livecd";
                } elsif ($rescue && ($name_path =~ m{$rescue})) {
                    $st = "rescue";
                } else {
                    $st = "unknown";
                }
            } else {
                $st = "undefined";
            }
            $self->info(ref($self), "status for $fqdn: $interface->{ip} $st since: $since (PXE variant=",
                                    variant_attribute('name', $variant), ")");
        }
    }
    
    exec_userhooks ($cfg, STATUS_HOOK_PATH);
    
    return 1;
}

# Removes PXE files and symlinks for the node. To be called by --remove.
# This must be done for PXELINUX and Grub2 variants.
sub Unconfigure
{
    my ($self, $cfg) = @_;

    if ($CAF::Object::NoAction) {
        $self->info ("Would remove " . ref ($self));
        return 1;
    }

    my $interfaces = $cfg->getElement (INTERFACES)->getTree;

    foreach my $variant (PXE_VARIANT_PXELINUX, PXE_VARIANT_GRUB2) {
        my $pxe_config_file = filepath ($cfg, $variant);
        # Remove the PXEe config file for the current host
        $this_app->debug(1, "Removing PXE config file $pxe_config_file (PXE variant=",
                            variant_attribute('name', $variant), ")");
        my $unlink_status = $self->cleanup($pxe_config_file);
        if ( ! defined($unlink_status) ) {
            $this_app->error("Failed to delete $pxe_config_file (error=$self->{fail})");
        } elsif ( $unlink_status == SUCCESS ) {
            $this_app->debug(1, "PXE config file $pxe_config_file not found");
        } else {
            $this_app->debug(1, "PXE config file $pxe_config_file successfully removed");
        };
        # Remove the symlink for every interface with an IP address
        while (my ($interface, $params) = each %$interfaces) {
            if ( defined($params->{ip}) ) {
                my $pxe_symlink =  dirname($pxe_config_file) . "/" . hexip_filename ($params->{ip}, $variant);
                $this_app->debug(1, "Removing symlink $pxe_symlink for interface $interface (PXE variant=",
                                    variant_attribute('name', $variant), ")");
                my $unlink_status = $self->cleanup($pxe_symlink);
                if ( ! defined($unlink_status) ) {
                    $this_app->error("Failed to delete $pxe_symlink (error=$self->{fail})");
                } elsif ( $unlink_status == SUCCESS ) {
                    $this_app->debug(1, "PXE link $pxe_symlink not found");
                } else {
                    $this_app->debug(1, "PXE link $pxe_symlink successfully removed");
                };
            };
        };
        exec_userhooks ($cfg, REMOVE_HOOK_PATH);
    }

    return 1;        
}


no strict 'refs';
foreach my $operation (qw(configure boot rescue livecd firmware install)) {
    my $name = ucfirst($operation);
    my $cmd = uc($operation);

    *{$name} = sub {
        my ($self, $cfg) = @_;

       foreach my $variant (PXE_VARIANT_PXELINUX, PXE_VARIANT_GRUB2) {
            if ( variant_enabled($variant) ) {
                $self->verbose("Executing action '$operation' for variant ", variant_attribute('name', $variant));
                variant_attribute('format_method', $variant)->($cfg) if ($operation eq 'configure');

                unless ( pxelink ($cfg, &$cmd(), $variant) ) {
                    my $fqdn = get_fqdn($cfg);
                    $self->error ("Failed to change the status of $fqdn to $operation");
                    return 0;
                }
            } else {
                $self->debug(1, "Variant ", variant_attribute('name',$variant), "disabled: action '$operation' not executed");
            }
        }
        exec_userhooks ($cfg, HOOK_PATH.$operation);
        return 1;
    };
};
use strict 'refs';

1;
