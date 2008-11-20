#!/usr/bin/perl -w
#
# Author: Morgan Jones (morgan@morganjones.org)
# Id:     $Id: ldap2zimbra.pl 83 2008-05-15 14:28:32Z morgan $
#


##################################################################
#### Site-specific settings
#
# The Zimbra SOAP libraries.  Download and uncompress the Zimbra
# source code to get them.
use lib "/usr/local/zcs-5.0.2_GA_1975-src/ZimbraServer/src/perl/soap";
# these accounts will never be added, removed or modified
#   It's a perl regex
my $zimbra_special = 
    '^admin|wiki|spam\.[a-z]+|ham\.[a-z]+|'. # Zimbra supplied
               # accounts. This will cause you trouble if you have users that 
               # start with ham or spam  For instance: ham.let--unlikely 
               # perhaps.
    'ser|'.
#    'mlehmann|gab|morgan|cferet|'.  
               # Steve, Matt, Gary, Feret and I
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
sub parse_and_return_list($);

my $opts;
getopts('z:p:l:b:D:w:m:a:d', \%$opts);

################
# Zimbra SOAP
## Any of your stores
my $zimbra_svr =    $opts->{z} || "dmail01.domain.org";
## admin user pass
my $zimbra_pass =   $opts->{p} || "pass";
## domain within which you want to create the alias
my $domain =        $opts->{m} || "dev.domain.org";
my $alias_name =    $opts->{a} || "all-34Thg90";

################
# Zimbra LDAP
my $z_ldap_host =   $opts->{l} || "dmldap01.domain.org";
my $z_ldap_base =   $opts->{b} || "dc=domain,dc=org";
my $z_ldap_binddn = $opts->{D} || "cn=config";
my $z_ldap_pass =   $opts->{w} || "pass";

# If we get an account.TOO_MANY_SEARCH_RESULTS Fault we recurse and
# search for a subset.  If the recursion somehow goes awry or there
# are juts too many entries we need to have a limit of some sort.
my $max_recurse = 5;

my $ldap = Net::LDAP->new($z_ldap_host) or die "$@";
$ldap->bind(dn=>$z_ldap_binddn, password=>$z_ldap_pass);


# url for zimbra store.
my $url = "https://" . $zimbra_svr . ":7071/service/admin/soap/";

my $ACCTNS = "urn:zimbraAdmin";
my $MAILNS = "urn:zimbraAdmin";
my $SOAP = $Soap::Soap12;

print "\nstarting at ", `date`;
### keep track of accounts in ldap and added.
### search out every account in ldap.

# authenticate to Zimbra admin url
my $d = new XmlDoc;
$d->start('AuthRequest', $ACCTNS);
$d->add('name', undef, undef, "admin");
$d->add('password', undef, undef, $zimbra_pass);
$d->end();

# get back an authResponse, authToken, sessionId & context.
my $authResponse = $SOAP->invoke($url, $d->root());
my $authToken = $authResponse->find_child('authToken')->content;
my $sessionId = $authResponse->find_child('sessionId')->content;
my $context = $SOAP->zimbraContext($authToken, $sessionId);




print "Building user list..\n";

my $d2 = new XmlDoc;

$d2->start('SearchDirectoryRequest', $MAILNS,
	  {'sortBy' => "uid",
	   'attrs'  => "uid",
	   'types'  => "accounts"}
    ); 
$d2->add('query', $MAILNS, { "types" => "accounts" });
$d2->end();

#     # TODO: skip special users?
#     if ($usr =~ /$zimbra_special/) {
# 	print "skipping special user $usr\n"
# 	    if (exists $opts->{d});
# 	next;
#     }

my $r = $SOAP->invoke($url, $d2->root(), $context);

my @l;
if ($r->name eq "Fault") {

    my $rsn = get_fault_reason($r);

    # break down the search by alpha/numeric if reason is 
    #    account.TOO_MANY_SEARCH_RESULTS
    if (defined $rsn && $rsn eq "account.TOO_MANY_SEARCH_RESULTS") {
	if (exists $opts->{d}) {
	    print "\tfault due to $rsn\n";
	    print "\trecursing deeper to return fewer results.\n";
	}

	@l = get_list_in_range(undef, "a", "z");
    } else {
        print "unhandled reason: $rsn, exiting.\n";
        exit;
    }
} else {
    if ($r->name ne "account") {
	print "skipping delete, unknown record type returned: ", $r->name, "\n";
	return;
    }

    print "returned ", $r->num_children, " children\n";

    @l = parse_and_return_list($r);
}



# search out the zimbraId
my $fil = "(&(objectclass=zimbraDistributionList)(uid=$alias_name))";
print "searching ldap for dist list with $fil\n";

my $sr = $ldap->search(base=>$z_ldap_base, filter=>$fil);
$sr->code && die $sr->error;

my @mbrs;
my $d_z_id;
for my $l_dist ($sr->entries) {
    $d_z_id = $l_dist->get_value("zimbraId");

}

if (defined $d_z_id) {

    # list exists, delete it
    print "deleting list $alias_name at ", `date`;

    my $d5 = new XmlDoc;

    $d5->start('DeleteDistributionListRequest', $MAILNS);
    $d5->add('id', $MAILNS, undef, $d_z_id);
    $d5->end();

    my $r = $SOAP->invoke($url, $d5->root(), $context);

    if ($r->name eq "Fault") {
	print "result: ", $r->name, "\n";
	print Dumper ($r);
	print "Error deleting $alias_name\@, exiting.\n";
	exit;
    }


}


# print "creating list $alias_name with id $d_z_id at ", `date`;
print "creating list $alias_name at ", `date`;

my $d3 = new XmlDoc;
$d3->start('CreateDistributionListRequest', $MAILNS);
$d3->add('name', $MAILNS, undef, "$alias_name\@". $domain);
$d3->add('a', $MAILNS, {"n" => "zimbraMailStatus"}, "disabled");
$d3->add('a', $MAILNS, {"n" => "zimbraHideInGal"}, "TRUE");
$d3->end;

my $r3 = $SOAP->invoke($url, $d3->root(), $context);

if ($r3->name eq "Fault") {
    print "result: ", $r3->name, "\n";
    print Dumper ($r3);
    print "Error adding $alias_name\@, skipping.\n";
    exit;
}

my $z_id;
for my $child (@{$r3->children()}) {
    for my $attr (@{$child->children}) {
	$z_id = $attr->content()
	    if ((values %{$attr->attrs()})[0] eq "zimbraId");
    }
}

print "adding members to $alias_name at ", `date`;

my $d4 = new XmlDoc;

$d4->start ('AddDistributionListMemberRequest', $MAILNS);
$d4->add ('id', $MAILNS, undef, $z_id);

my $member_count = 0;
for (@l) {
    next if ($_ =~ /archive$/);
    $_ .= "\@" . $domain
        if ($_ !~ /\@/);
    print "adding $_\n"
	if (exists $opts->{d});
        
    $d4->add ('dlm', $MAILNS, undef, $_);
    $member_count++;
 }
$d4->end;

my $r4 = $SOAP->invoke($url, $d4->root(), $context);

if ($r4->name eq "Fault") {
    print "result: ", $r4->name, "\n";
    print Dumper ($r4);
    print "Error adding distribution list members.  This probably means the alias is empty\n";
    exit;
}

print "finished adding $member_count members to $alias_name at ", `date`;


#######
sub parse_and_return_list($) {

    my $r = shift;

    my @l;

    for my $child (@{$r->children()}) {
	my ($mail, $z_id);

	for my $attr (@{$child->children}) {
  	    if ((values %{$attr->attrs()})[0] eq "mail") {
  		$mail = $attr->content();
 	    }
  	    if ((values %{$attr->attrs()})[0] eq "zimbraId") {
  		$z_id = $attr->content();
  	    }
 	}
	push @l, $mail;
    }

    return @l
}


#######
# a, b, c, d, .. z
# a, aa, ab, ac .. az, ba, bb .. zz
# a, aa, aaa, aab, aac ... zzz
sub get_list_in_range($$$) {
    my ($prfx, $beg, $end) = @_;

#     print "deleting ";
#     print "${beg}..${end} ";
#     print "w/ prfx $prfx " if (defined $prfx);
#     print "\n";

    my @l;

    for my $l (${beg}..${end}) {
	my $fil = 'uid=';
	$fil .= $prfx if (defined $prfx);
	$fil .= "${l}\*";

	print "searching $fil\n"
	    if ( exists $opts->{d});

	my $d = new XmlDoc;
	$d->start('SearchDirectoryRequest', $MAILNS);
	$d->add('query', $MAILNS, undef, $fil);
	$d->end;
	
	my $r = $SOAP->invoke($url, $d->root(), $context);
# debugging:
# 	if ($r->name eq "Fault" || !defined $prfx || 
#	    scalar (split //, $prfx) < 6 ) {
 	if ($r->name eq "Fault") {
	   
	    my $rsn = get_fault_reason ($r);

	    # break down the search by alpha/numeric if reason is 
	    #    account.TOO_MANY_SEARCH_RESULTS
	    if (defined $rsn && $rsn eq "account.TOO_MANY_SEARCH_RESULTS") {
		if (exists $opts->{d}) {
		    print "\tfault due to $rsn\n";
		    print "\trecursing deeper to return fewer results.\n";
		}
		
		my $prfx2pass = $l;
		$prfx2pass = $prfx . $prfx2pass if defined $prfx;
		
		increment_del_recurse();
		if (get_del_recurse() > $max_recurse) {
		    print "\tmax recursion ($max_recurse) hit, backing off.. \n";
		    print "\tThis may mean a truncated user list.\n";
		    decrement_del_recurse();
		    return 1; # return failure so caller knows to return
		              # and not keep trying to recurse to this
		              # level

		}

		push @l, get_list_in_range ($prfx2pass, $beg, $end);
		decrement_del_recurse();

		# my @my_l = get_list_in_range ($prfx2pass, $beg, $end);
		# decrement_del_recurse();
		# return @my_l if (@my_l);  # should cause us to drop back one level
			      # in recursion

	    } else {
		print "unhandled reason: $rsn, exiting.\n";
		exit;
	    }

 	} else {
	    push @l, parse_and_return_list($r);
        }
    }

    return @l;
}


# static variable to limit recursion depth
BEGIN {
    my $del_recurse_counter = 0;

    sub increment_del_recurse() {
	$del_recurse_counter++;
    }

    sub decrement_del_recurse() {
	$del_recurse_counter--;
    }
    
    sub get_del_recurse() {
	return $del_recurse_counter;
    }
}



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

    return "<no reason found..>";
}
