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
sub parse_and_return_list($);
sub find_and_del_alias($);
sub create_and_populate_alias($@);
sub get_alias_z_id($);
sub rename_alias($$);

my $opts;
getopts('z:p:l:b:D:w:m:a:dn', \%$opts);

################
# Zimbra SOAP
## Any of your stores
my $zimbra_svr =    $opts->{z} || "dmail01.domain.org";
## admin user pass
my $zimbra_pass =   $opts->{p} || "pass";
## domain within which you want to create the alias
my $domain =        $opts->{m} || "dev.domain.org";
my $alias_name =    $opts->{a} || "all-34Thg90";

my $alias_name_tmp = $alias_name . "_tmp";

################
# Zimbra LDAP
my $z_ldap_host =   $opts->{l} || "dmldap01.domain.org";
my $z_ldap_base =   $opts->{b} || "dc=dev,dc=domain,dc=org";
my $z_ldap_binddn = $opts->{D} || "uid=zimbra,cn=admins,cn=zimbra";
my $z_ldap_pass =   $opts->{w} || "pass";

exists ($opts->{n}) && print "\n-n used, no changes will be made\n";
exists ($opts->{d}) && print "-d used, debugging will be printed\n";

my $omit_cos_id;
# if this is defined create_all will omit users in this cos.
# prod
$omit_cos_id = "f1b022c3-82a0-44c5-97e6-406c66e9af66";
# dev
# $omit_cos_id = "28a287bd-199b-4ff0-82cf-ca0578756035"; 
#
# my $search_fil = "(!(zimbracosid=$omit_cos_id))";

#$search_fil = "(&(!(zimbracosid=$omit_cos_id))(zimbraaccountstatus=active))";
my $search_fil = "(zimbraaccountstatus=active)";

$search_fil = "(&(!(zimbracosid=$omit_cos_id))$search_fil)"
    if (defined ($omit_cos_id));



# If we get an account.TOO_MANY_SEARCH_RESULTS Fault we recurse and
# search for a subset.  If the recursion somehow goes awry or there
# are just too many entries we need to have a limit of some sort.
my $max_recurse = 15;

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
#$d->add('name', undef, undef, "admin"."@".$domain);
$d->add('name', undef, undef, "admin");
$d->add('password', undef, undef, $zimbra_pass);
$d->end();

# get back an authResponse, authToken, sessionId & context.
my $authResponse = $SOAP->invoke($url, $d->root());
my $authToken = $authResponse->find_child('authToken')->content;
#my $sessionId = $authResponse->find_child('sessionId')->content;
#my $context = $SOAP->zimbraContext($authToken, $sessionId);
my $context = $SOAP->zimbraContext($authToken, undef);






# Get list of users from Zimbra
print "Building user list..\n";

my $d2 = new XmlDoc;

$d2->start('SearchDirectoryRequest', $MAILNS,
	  {'sortBy' => "uid",
	   'types'  => "accounts"}
    ); 

if (defined $search_fil) {
    $d2->add('query', $MAILNS, { "types" => "accounts" }, $search_fil);
} else {
    $d2->add('query', $MAILNS, { "types" => "accounts" });
}

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
    @l = parse_and_return_list($r);
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



#######
sub parse_and_return_list($) {
    my $r = shift;
    my @l;

    for my $child (@{$r->children()}) {
	for my $attr (@{$child->children}) {
            if ((values %{$attr->attrs()})[0] =~ /^zimbramaildeliveryaddress$/i) {  
                my $c = $attr->content();
                if ($c =~ /^_/) {
                    print "\tskipping special address ", $c, "\n";
                    next;
                }
                push @l, $c;
            }
 	}
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

    for my $l (${beg}..${end}, "_", "-") {
	my $fil = '(uid=';
	$fil .= $prfx if (defined $prfx);
	# $fil .= "${l}\*";
	$fil .= "${l}\*)";

	$fil = "(&(" . $fil . $search_fil . "))"
	    if (defined ($search_fil));

	print "searching $fil\n"
	    if ( exists $opts->{d});

	my $d = new XmlDoc;
	$d->start('SearchDirectoryRequest', $MAILNS);
	$d->add('query', $MAILNS, { "types" => "accounts" }, $fil);
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
    }# else {
#	print "\talias $alias_name not found..\n";
#    }
}


sub get_alias_z_id($) {
    my $alias_name = shift;

    # return undef if the alias doesn't exist
    my $d_z_id = undef;

    # search out the zimbraId of the production alias
    my $fil = "(&(objectclass=zimbraDistributionList)(uid=$alias_name))";
    print "searching ldap for dist list with $fil\n"
	if (exists $opts->{d});

    my $sr = $ldap->search(base=>$z_ldap_base, filter=>$fil);
    $sr->code && die $sr->error;

    my @mbrs;

    for my $l_dist ($sr->entries) {
	$d_z_id = $l_dist->get_value("zimbraId");
    }

    return $d_z_id;
}










sub create_and_populate_alias($@) {
    my $alias_name = shift;
    my @l = @_;

    # print "creating list $alias_name with id $d_z_id at ", `date`;
    # print "creating list $alias_name at ", `date`;

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

        # print "adding members to $alias_name at ", `date`;
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
