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
               # start with ham or spam  For instance: ham.let.  Unlikely 
               # perhaps.
    'ser|'.
#    'mlehmann|gab|morgan|cferet|'.  
               # Steve, Matt, Gary, Feret and I
    'sjones|aharris|'.        # Gary's test users
    'hammy|spammy$';          # Spam training users 

# hostname for zimbra store.  It can be any of your stores.
# it can be overridden on the command line.
my $default_zimbra_svr = "dmail01.domain.org";
# zimbra admin password
my $default_zimbra_pass  = "pass";

my $default_alias_name = "all-34Thg90";

# default domain, used every time a user is created and in some cases
# modified.  Can be overridden on the command line.
my $default_domain       = "dev.domain.org";

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

my $zimbra_svr = "dmail01.domain.org";
my $zimbra_pass = "pass";
my $max_recurse = 5;



################
# Zimbra LDAP
my $z_ldap_host = "dmldap01.domain.org";
my $z_ldap_base = "dc=domain,dc=org";
my $z_ldap_binddn = "cn=config";
my $z_ldap_pass = "pass";

my $ldap = Net::LDAP->new($z_ldap_host) or die "$@";
$ldap->bind(dn=>$z_ldap_binddn, password=>$z_ldap_pass);



#my $opts;
#getopts('hl:D:w:b:em:ndz:s:p:', \%$opts);

# url for zimbra store.  It can be any of your stores
# my $url = "https://dmail01.domain.org:7071/service/admin/soap/";
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

my $d2 = new XmlDoc;

$d2->start('SearchDirectoryRequest', $MAILNS,
	  {'sortBy' => "uid",
	   'attrs'  => "uid",
	   'types'  => "accounts"}
    ); 
$d2->add('query', $MAILNS, { "types" => "accounts" });
$d2->end();


#     # skip special users?
#     if ($usr =~ /$zimbra_special/) {
# 	print "skipping special user $usr\n"
# 	    if (exists $opts->{d});
# 	next;
#     }


my $r = $SOAP->invoke($url, $d2->root(), $context);

my @l;
if ($r->name eq "Fault") {
    # break down the search by alpha/numeric
    print "\tFault! ..recursing deeper to return fewer results.\n";
    @l = get_list_in_range(undef, "a", "z");
 } else {
    if ($r->name ne "account") {
	print "skipping delete, unknown record type returned: ", $r->name, "\n";
	return;
    }

    print "returned ", $r->num_children, " children\n";

    @l = parse_and_return_list($r);
}






# search out the zimbraId

my $fil = "(&(objectclass=zimbraDistributionList)(uid=$default_alias_name))";
print "searching ldap for dist list with $fil\n";

my $sr = $ldap->search(base=>$z_ldap_base, filter=>$fil);
$sr->code && die $sr->error;

my @mbrs;
my $d_z_id;
for my $l_dist ($sr->entries) {
    $d_z_id = $l_dist->get_value("zimbraId");

#print "list: $list\n";
#print "members: " , join ' ', @mbrs , "\n";
}

if (defined $d_z_id) {
    # list exists, delete it

    print "deleting list $default_alias_name with id $d_z_id\n";

    my $d5 = new XmlDoc;

    $d5->start('DeleteDistributionListRequest', $MAILNS);
    $d5->add('id', $MAILNS, undef, $d_z_id);
    $d5->end();

    my $r = $SOAP->invoke($url, $d5->root(), $context);
}










my $d3 = new XmlDoc;
$d3->start('CreateDistributionListRequest', $MAILNS);
$d3->add('name', $MAILNS, undef, "$default_alias_name\@". $default_domain);
$d3->add('a', $MAILNS, {"n" => "zimbraMailStatus"}, "disabled");
$d3->add('a', $MAILNS, {"n" => "zimbraHideInGal"}, "TRUE");
$d3->end;

my $r3 = $SOAP->invoke($url, $d3->root(), $context);
# TODO: error checking!



print "add result: ", $r3->name, "\n";
if ($r3->name eq "Fault") {
    print Dumper ($r3);
    print "Error adding $default_alias_name\@, skipping.\n";
    exit;
}

my $z_id;
for my $child (@{$r3->children()}) {
    for my $attr (@{$child->children}) {
	$z_id = $attr->content()
	    if ((values %{$attr->attrs()})[0] eq "zimbraId");
    }
}

my $d4 = new XmlDoc;

$d4->start ('AddDistributionListMemberRequest', $MAILNS);
$d4->add ('id', $MAILNS, undef, $z_id);
for (@l) {
    next if ($_ =~ /archive$/);
    $_ .= "\@" . $default_domain
        if ($_ !~ /\@/);
     print "adding $_\n";
    $d4->add ('dlm', $MAILNS, undef, $_);
 }
$d4->end;

my $r4 = $SOAP->invoke($url, $d4->root(), $context);







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

	print "searching $fil\n";
	my $d = new XmlDoc;
	$d->start('SearchDirectoryRequest', $MAILNS);
	$d->add('query', $MAILNS, undef, $fil);
	$d->end;
	
	my $r = $SOAP->invoke($url, $d->root(), $context);
# debugging:
# 	if ($r->name eq "Fault" || !defined $prfx || 
#	    scalar (split //, $prfx) < 6 ) {
 	if ($r->name eq "Fault") {
# 	    # TODO: limit recursion depth
	    print "\tFault! ..recursing deeper to return fewer results.\n";
	    my $prfx2pass = $l;
	    $prfx2pass = $prfx . $prfx2pass if defined $prfx;

	    increment_del_recurse();
	    if (get_del_recurse() > $max_recurse) {
		print "\tmax recursion ($max_recurse) hit, backing off..\n";
		decrement_del_recurse();
		return 1; #return failure so caller knows to return
			  #and not keep trying to recurse to this
			  #level

	    }
 	    # my @my_l = get_list_in_range ($prfx2pass, $beg, $end);
	    # decrement_del_recurse();
	    # return @my_l if (@my_l);  # should cause us to drop back one level
			      # in recursion
 	    push @l, get_list_in_range ($prfx2pass, $beg, $end);
	    decrement_del_recurse();
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

