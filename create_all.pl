#!/usr/bin/perl -w
#
# Author: Morgan Jones (morgan@morganjones.org)
# Id:     $Id$
#


##################################################################
#### Site-specific settings
#
# The Zimbra SOAP libraries.  Download and uncompress the Zimbra
# source code to get them.
#use lib "/usr/local/zcs-5.0.2_GA_1975-src/ZimbraServer/src/perl/soap";
use lib "/usr/local/zcs-6.0.7_GA_2483-src/ZimbraServer/src/perl/soap";
# these accounts will never be added, removed or modified
#   It's a perl regex
my $zimbra_special = 
    '^admin|wiki|spam\.[a-z]+|ham\.[a-z]+|'. # Zimbra supplied
               # accounts. This will cause you trouble if you have users that 
               # start with ham or spam  For instance: ham.let--unlikely 
               # perhaps.
    'ser|'.
    'sjones|aharris|'.        # Gary's test users
    'hammy|spammy$';          # Spam training users 


use strict;
use Getopt::Std;
use Net::LDAP;
use Data::Dumper;
use XmlElement;
use XmlDoc;
use Soap;
$|=1;

sub print_usage();
sub get_z2l();
sub add_user($);
sub sync_user($$);
sub get_z_user($);
sub fix_case($);
sub build_target_z_value($$);
sub delete_not_in_ldap();
sub get_list_in_range($$$);
#sub parse_and_return_list($);
sub find_and_del_alias($);
sub create_and_populate_alias($@);
sub get_alias_z_id($);
sub rename_alias($$);

my $opts;
getopts('z:p:l:b:D:w:m:a:dnf:c:', \%$opts);

our %config;
our $test;

$opts->{c} || print_usage();
require $opts->{c};

my $zimbra_svr =  $config{zimbra_svr};
my $zimbra_pass = $config{zimbra_pass};
my $domain =      $config{domain};
my $alias_name =  $config{alias_name};

my $alias_name_tmp = $alias_name . "_tmp";

my $ldap_host =   $config{ldap_host};
my $ldap_base =   $config{ldap_base};
my $ldap_binddn = $config{ldap_binddn};
my $ldap_pass =   $config{ldap_pass};

exists ($opts->{n}) && print "\n-n used, no changes will be made\n";
exists ($opts->{d}) && print "-d used, debugging will be printed\n";

my $search_fil = $config{search_filter};

my @addresses_to_add = @{$config{addresses_to_add}};

my $ldap = Net::LDAP->new($ldap_host) or die "$@";
$ldap->bind(dn=>$ldap_binddn, password=>$ldap_pass);

# url for zimbra store.
my $url = "https://" . $zimbra_svr . ":7071/service/admin/soap/";

my $ACCTNS = "urn:zimbraAdmin";
my $MAILNS = "urn:zimbraAdmin";
my $SOAP = $Soap::Soap12;

print "\nstarting at ", `date`;

# authenticate to Zimbra admin url
my $d = new XmlDoc;
$d->start('AuthRequest', $ACCTNS);
$d->add('name', undef, undef, "admin");
$d->add('password', undef, undef, $zimbra_pass);
$d->end();

# get back an authResponse, authToken, sessionId & context.
my $authResponse = $SOAP->invoke($url, $d->root());
my $authToken = $authResponse->find_child('authToken')->content;
#my $sessionId = $authResponse->find_child('sessionId')->content;
#my $context = $SOAP->zimbraContext($authToken, $sessionId);
my $context = $SOAP->zimbraContext($authToken, undef);


print "searching $ldap_host...\n";
my $sr = $ldap->search(base => $config{ldap_base}, filter => $config{search_filter}, 
		       attrs => "mail");

$sr->code && die "problem searching ", $config{"ldap_host"};

my $result_ref = $sr->as_struct;

my @l;
for my $dn (sort keys %$result_ref) {
    push @l, $result_ref->{$dn}->{mail}->[0]
}

# search out and delete the tmp alias if it exists.  In most cases it
# won't exist but if, say this script was interrupted it would be out
# there and should be deleted before we attempt to create it.
print "checking for $alias_name_tmp at ", `date`;
find_and_del_alias($alias_name_tmp);

print "creating and populating $alias_name_tmp at ", `date`;
create_and_populate_alias($alias_name_tmp, @l);

print "checking for $alias_name at ", `date`;
find_and_del_alias($alias_name);

print "renaming $alias_name_tmp to $alias_name at ", `date`;
rename_alias($alias_name_tmp, $alias_name);

# print "looking for and deleting $alias_name_tmp\n";
# find_and_del_alias($alias_name_tmp);

print "finished at ", `date`;


sub get_fault_reason {
    my $r = shift;

    # get the reason for the fault
    #my $rsn;
    for my $v (@{$r->children()}) {
        if ($v->name eq "Detail") {
	    for my $v2 (@{@{$v->children()}[0]->children()}) {
		if ($v2->name eq "Code") {
		    return $v2->content;
		}
	    }
	}
    }

    return "<no reason found>";
}



sub find_and_del_alias($) {
    my $alias_name = shift;

    my $d_z_id = get_alias_z_id($alias_name);
    if (defined $d_z_id) {
	# list exists, delete it
	print "\tdeleting list $alias_name\n";

	my $d5 = new XmlDoc;

	$d5->start('DeleteDistributionListRequest', $MAILNS);
	$d5->add('id', $MAILNS, undef, $d_z_id);
	$d5->end();

        if (!exists $opts->{n}) {
            my $r = $SOAP->invoke($url, $d5->root(), $context);

            if ($r->name eq "Fault") {
                print "result: ", $r->name, "\n";
                print Dumper ($r);
                print "Error deleting $alias_name\@, exiting.\n";
                exit;
            }
        }
    }
}


sub get_alias_z_id($) {
    my $alias_name = shift;

    # return undef if the alias doesn't exist
    my $d_z_id = undef;

    my $d6 = new XmlDoc;

    $d6->start('GetDistributionListRequest', $MAILNS);
    $d6->add('dl', $MAILNS, {"by" => "name"}, 
	     $alias_name . "@". $config{domain});
    $d6->end();

    my $r6 = $SOAP->invoke($url, $d6->root(), $context);

    if ($r6->name eq "Fault") {

	my $rsn = get_fault_reason($r6);
	if  (defined $rsn & $rsn eq "account.NO_SUCH_DISTRIBUTION_LIST") {
	    return undef;
	}

	print "result: ", $r6->name, "\n";
	print Dumper ($r6);
	print "Error getting alias ", $config{alias_name} , " zimbraid.\n";
	exit;
    }

    my $dl = $r6->find_child('dl');
    $d_z_id = $dl->{attrs}->{id};

    return $d_z_id;
}


sub create_and_populate_alias($@) {
    my $alias_name = shift;
    my @l = @_;

    my $d3 = new XmlDoc;
    $d3->start('CreateDistributionListRequest', $MAILNS);
    $d3->add('name', $MAILNS, undef, "$alias_name\@". $domain);
    $d3->add('a', $MAILNS, {"n" => "zimbraMailStatus"}, "disabled");
    $d3->add('a', $MAILNS, {"n" => "zimbraHideInGal"}, "TRUE");
    $d3->end;

    my $z_id;
    if (!exists $opts->{n}) {
        my $r3 = $SOAP->invoke($url, $d3->root(), $context);

        if ($r3->name eq "Fault") {
            print "result: ", $r3->name, "\n";
            print Dumper ($r3);
            print "Error adding $alias_name\@, skipping.\n";
            exit;
        }

        for my $child (@{$r3->children()}) {
            for my $attr (@{$child->children}) {
                $z_id = $attr->content()
                    if ((values %{$attr->attrs()})[0] eq "zimbraId");
            }
        }
    }
    
    my $d4 = new XmlDoc;

    if (!exists $opts->{n}) {
        $d4->start ('AddDistributionListMemberRequest', $MAILNS);
        $d4->add ('id', $MAILNS, undef, $z_id);
    }

    my $member_count = 0;
    for (@l) {
        next if ($_ =~ /archive$/);
        $_ .= "\@" . $domain
            if ($_ !~ /\@/);
        print "adding $_\n"
            if (exists $opts->{d});
        $d4->add ('dlm', $MAILNS, undef, $_)
            if (!exists $opts->{n});
        $member_count++;
    }

    if (@addresses_to_add) {
	for (@addresses_to_add) {
	    print "adding $_\n"
	      if (exists $opts->{d});
	    $d4->add ('dlm', $MAILNS, undef, $_)
	      if (!exists $opts->{n});
	    $member_count++;
	}
    }

    if (!exists $opts->{n}) {
        $d4->end;

        my $r4 = $SOAP->invoke($url, $d4->root(), $context);

        if ($r4->name eq "Fault") {
            print "result: ", $r4->name, "\n";
            print Dumper ($r4);
            print "Error adding distribution list members.  This probably means the alias was left empty\n";
            exit;
        }
    }

    print "\tfinished adding $member_count members to $alias_name\n";
}



sub rename_alias($$) {
    my ($my_alias_name_tmp, $my_alias_name) = @_;

    if (!exists $opts->{n}) {
        my $d_z_id = get_alias_z_id($my_alias_name_tmp);
        if (defined $d_z_id) {
            my $my_d = new XmlDoc;
            $my_d->start('RenameDistributionListRequest', $MAILNS);
            $my_d->add('id', $MAILNS, undef, "$d_z_id");
            $my_d->add('newName', $MAILNS, undef, "$my_alias_name\@". $domain);
            $my_d->end;
            
            my $my_r = $SOAP->invoke($url, $my_d->root(), $context);
            
            if ($my_r->name eq "Fault") {
                print "result: ", $my_r->name, "\n";
                print Dumper ($my_r);
                print "Error renaming $my_alias_name_tmp $my_alias_name, skipping.\n";
                exit;
            }
            
        } else {
            print "\talias $alias_name_tmp doesn't exist, skipping.\n";
        }
    }
}



sub print_usage() {
    print "usage: $0 [-n] -c <config file>\n";
}				 



# <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
#     <soap:Header>
#         <context xmlns="urn:zimbra">
#             <userAgent name="ZimbraWebClient - FF2.0 (Linux)"/>
#             <sessionId id="3340"/>
#             <format type="js"/>
#             <authToken>
#                 0_b6983d905b848e6d7547b808809cfb1a611108d3_69643d33363a38323539616631392d313031302d343366392d613338382d6439393038363234393862623b6578703d31333a313232373231363531393132373b61646d696e3d313a313b747970653d363a7a696d6272613b6d61696c686f73743d31363a3137302e3233352e312e3234313a38303b
#             </authToken>
#         </context>
#     </soap:Header>
#     <soap:Body>
#         <RenameDistributionListRequest xmlns="urn:zimbraAdmin">
#             <id>
#                 8b3fe3c8-c9d6-4771-8419-dcf5e071b2ba
#             </id>
#             <newName>
#                 morgantest@dev.domain.org
#             </newName>
#         </RenameDistributionListRequest>
#     </soap:Body>
# </soap:Envelope>
