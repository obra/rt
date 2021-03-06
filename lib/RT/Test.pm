# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2012 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

package RT::Test;

use strict;
use warnings;


use base 'Test::More';

use Socket;
use File::Temp qw(tempfile);
use File::Path qw(mkpath);
use File::Spec;

our @EXPORT = qw(is_empty diag parse_mail works fails);

my %tmp = (
    directory => undef,
    config    => {
        RT => undef,
        apache => undef,
    },
    mailbox   => undef,
);

my %rttest_opt;

=head1 NAME

RT::Test - RT Testing

=head1 NOTES

=head2 COVERAGE

To run the rt test suite with coverage support, install L<Devel::Cover> and run:

    make test RT_DBA_USER=.. RT_DBA_PASSWORD=.. HARNESS_PERL_SWITCHES=-MDevel::Cover
    cover -ignore_re '^var/mason_data/' -ignore_re '^t/'

The coverage tests have DevelMode turned off, and have
C<named_component_subs> enabled for L<HTML::Mason> to avoid an optimizer
problem in Perl that hides the top-level optree from L<Devel::Cover>.

=cut

our $port;
our @SERVERS;

sub import {
    my $class = shift;
    my %args = %rttest_opt = @_;

    # Spit out a plan (if we got one) *before* we load modules
    if ( $args{'tests'} ) {
        $class->builder->plan( tests => $args{'tests'} )
          unless $args{'tests'} eq 'no_declare';
    }
    elsif ( exists $args{'tests'} ) {
        # do nothing if they say "tests => undef" - let them make the plan
    }
    elsif ( $args{'skip_all'} ) {
        $class->builder->plan(skip_all => $args{'skip_all'});
    }
    else {
        $class->builder->no_plan unless $class->builder->has_plan;
    }

    push @{ $args{'plugins'} ||= [] }, @{ $args{'requires'} }
        if $args{'requires'};
    push @{ $args{'plugins'} ||= [] }, $args{'testing'}
        if $args{'testing'};

    $class->bootstrap_tempdir;

    $class->bootstrap_port;

    $class->bootstrap_plugins_paths( %args );

    $class->bootstrap_config( %args );

    use RT;
    RT::LoadConfig;

    if (RT->Config->Get('DevelMode')) { require Module::Refresh; }

    $class->bootstrap_db( %args );

    RT::InitPluginPaths();

    __reconnect_rt()
        unless $args{nodb};

    RT::InitClasses();
    RT::InitLogging();

    RT->Plugins;

    RT::I18N->Init();
    RT->Config->PostLoadCheck;

    $class->set_config_wrapper;

    my $screen_logger = $RT::Logger->remove( 'screen' );
    require Log::Dispatch::Perl;
    $RT::Logger->add( Log::Dispatch::Perl->new
                      ( name      => 'rttest',
                        min_level => $screen_logger->min_level,
                        action => { error     => 'warn',
                                    critical  => 'warn' } ) );

    # XXX: this should really be totally isolated environment so we
    # can parallelize and be sane
    mkpath [ $RT::MasonSessionDir ]
        if RT->Config->Get('DatabaseType');

    my $level = 1;
    while ( my ($package) = caller($level-1) ) {
        last unless $package =~ /Test/;
        $level++;
    }

    Test::More->export_to_level($level);

    # blow away their diag so we can redefine it without warning
    # better than "no warnings 'redefine'" because we might accidentally
    # suppress a mistaken redefinition
    no strict 'refs';
    delete ${ caller($level) . '::' }{diag};
    __PACKAGE__->export_to_level($level);
}

sub is_empty($;$) {
    my ($v, $d) = shift;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    return Test::More::ok(1, $d) unless defined $v;
    return Test::More::ok(1, $d) unless length $v;
    return Test::More::is($v, '', $d);
}

my $created_new_db;    # have we created new db? mainly for parallel testing

sub db_requires_no_dba {
    my $self = shift;
    my $db_type = RT->Config->Get('DatabaseType');
    return 1 if $db_type eq 'SQLite';
}

sub bootstrap_port {
    my $class = shift;

    my %ports;

    # Determine which ports are in use
    use Fcntl qw(:DEFAULT :flock);
    my $portfile = "$tmp{'directory'}/../ports";
    sysopen(PORTS, $portfile, O_RDWR|O_CREAT)
        or die "Can't write to ports file $portfile: $!";
    flock(PORTS, LOCK_EX)
        or die "Can't write-lock ports file $portfile: $!";
    $ports{$_}++ for split ' ', join("",<PORTS>);

    # Pick a random port, checking that the port isn't in our in-use
    # list, and that something isn't already listening there.
    {
        $port = 1024 + int rand(10_000) + $$ % 1024;
        redo if $ports{$port};

        # There is a race condition in here, where some non-RT::Test
        # process claims the port after we check here but before our
        # server binds.  However, since we mostly care about race
        # conditions with ourselves under high concurrency, this is
        # generally good enough.
        my $paddr = sockaddr_in( $port, inet_aton('localhost') );
        socket( SOCK, PF_INET, SOCK_STREAM, getprotobyname('tcp') )
            or die "socket: $!";
        if ( connect( SOCK, $paddr ) ) {
            close(SOCK);
            redo;
        }
        close(SOCK);
    }

    $ports{$port}++;

    # Write back out the in-use ports
    seek(PORTS, 0, 0);
    truncate(PORTS, 0);
    print PORTS "$_\n" for sort {$a <=> $b} keys %ports;
    close(PORTS) or die "Can't close ports file: $!";
}

sub bootstrap_tempdir {
    my $self = shift;
    my ($test_dir, $test_file) = ('t', '');

    if (File::Spec->rel2abs($0) =~ m{(?:^|[\\/])(x?t)[/\\](.*)}) {
        $test_dir  = $1;
        $test_file = "$2-";
        $test_file =~ s{[/\\]}{-}g;
    }

    my $dir_name = File::Spec->rel2abs("$test_dir/tmp");
    mkpath( $dir_name );
    return $tmp{'directory'} = File::Temp->newdir(
        "${test_file}XXXXXXXX",
        DIR => $dir_name
    );
}

sub bootstrap_config {
    my $self = shift;
    my %args = @_;

    $tmp{'config'}{'RT'} = File::Spec->catfile(
        "$tmp{'directory'}", 'RT_SiteConfig.pm'
    );
    open( my $config, '>', $tmp{'config'}{'RT'} )
        or die "Couldn't open $tmp{'config'}{'RT'}: $!";

    my $dbname = $ENV{RT_TEST_PARALLEL}? "rt4test_$port" : "rt4test";
    print $config qq{
Set( \$WebDomain, "localhost");
Set( \$WebPort,   $port);
Set( \$WebPath,   "");
Set( \@LexiconLanguages, qw(en zh_TW fr ja));
Set( \$RTAddressRegexp , qr/^bad_re_that_doesnt_match\$/i);
};
    if ( $ENV{'RT_TEST_DB_SID'} ) { # oracle case
        print $config "Set( \$DatabaseName , '$ENV{'RT_TEST_DB_SID'}' );\n";
        print $config "Set( \$DatabaseUser , '$dbname');\n";
    } else {
        print $config "Set( \$DatabaseName , '$dbname');\n";
        print $config "Set( \$DatabaseUser , 'u${dbname}');\n";
    }

    if ( $args{'plugins'} ) {
        print $config "Set( \@Plugins, qw(". join( ' ', @{ $args{'plugins'} } ) .") );\n";
    }

    if ( $INC{'Devel/Cover.pm'} ) {
        print $config "Set( \$DevelMode, 0 );\n";
    }
    elsif ( $ENV{RT_TEST_DEVEL} ) {
        print $config "Set( \$DevelMode, 1 );\n";
    }
    else {
        print $config "Set( \$DevelMode, 0 );\n";
    }

    $self->bootstrap_logging( $config );

    # set mail catcher
    my $mail_catcher = $tmp{'mailbox'} = File::Spec->catfile(
        $tmp{'directory'}->dirname, 'mailbox.eml'
    );
    print $config <<END;
Set( \$MailCommand, sub {
    my \$MIME = shift;

    open( my \$handle, '>>', '$mail_catcher' )
        or die "Unable to open '$mail_catcher' for appending: \$!";

    \$MIME->print(\$handle);
    print \$handle "%% split me! %%\n";
    close \$handle;
} );
END

    $self->bootstrap_more_config($config, \%args);

    print $config $args{'config'} if $args{'config'};

    print $config "\n1;\n";
    $ENV{'RT_SITE_CONFIG'} = $tmp{'config'}{'RT'};
    close $config;

    return $config;
}

sub bootstrap_more_config { }

sub bootstrap_logging {
    my $self = shift;
    my $config = shift;

    # prepare file for logging
    $tmp{'log'}{'RT'} = File::Spec->catfile(
        "$tmp{'directory'}", 'rt.debug.log'
    );
    open( my $fh, '>', $tmp{'log'}{'RT'} )
        or die "Couldn't open $tmp{'config'}{'RT'}: $!";
    # make world writable so apache under different user
    # can write into it
    chmod 0666, $tmp{'log'}{'RT'};

    print $config <<END;
Set( \$LogToSyslog , undef);
Set( \$LogToScreen , "warning");
Set( \$LogToFile, 'debug' );
Set( \$LogDir, q{$tmp{'directory'}} );
Set( \$LogToFileNamed, 'rt.debug.log' );
END
}

sub set_config_wrapper {
    my $self = shift;

    my $old_sub = \&RT::Config::Set;
    no warnings 'redefine';
    *RT::Config::Set = sub {
        # Determine if the caller is either from a test script, or
        # from helper functions called by test script to alter
        # configuration that should be written.  This is necessary
        # because some extensions (RTIR, for example) temporarily swap
        # configuration values out and back in Mason during requests.
        my @caller = caller(1); # preserve list context
        @caller = caller(0) unless @caller;

        if ( ($caller[1]||'') =~ /\.t$/) {
            my ($self, $name) = @_;
            my $type = $RT::Config::META{$name}->{'Type'} || 'SCALAR';
            my %sigils = (
                HASH   => '%',
                ARRAY  => '@',
                SCALAR => '$',
            );
            my $sigil = $sigils{$type} || $sigils{'SCALAR'};
            open( my $fh, '>>', $tmp{'config'}{'RT'} )
                or die "Couldn't open config file: $!";
            require Data::Dumper;
            local $Data::Dumper::Terse = 1;
            my $dump = Data::Dumper::Dumper([@_[2 .. $#_]]);
            $dump =~ s/;\s+$//;
            print $fh
                "\nSet(${sigil}${name}, \@{". $dump ."});\n1;\n";
            close $fh;

            if ( @SERVERS ) {
                warn "you're changing config option in a test file"
                    ." when server is active";
            }
        }
        return $old_sub->(@_);
    };
}

sub bootstrap_db {
    my $self = shift;
    my %args = @_;

    unless (defined $ENV{'RT_DBA_USER'} && defined $ENV{'RT_DBA_PASSWORD'}) {
        Test::More::BAIL_OUT(
            "RT_DBA_USER and RT_DBA_PASSWORD environment variables need"
            ." to be set in order to run 'make test'"
        ) unless $self->db_requires_no_dba;
    }

    require RT::Handle;
    if (my $forceopt = $ENV{RT_TEST_FORCE_OPT}) {
        Test::More::diag "forcing $forceopt";
        $args{$forceopt}=1;
    }

    # Short-circuit the rest of ourselves if we don't want a db
    if ($args{nodb}) {
        __drop_database();
        return;
    }

    my $db_type = RT->Config->Get('DatabaseType');
    __create_database();
    __reconnect_rt('as dba');
    $RT::Handle->InsertSchema;
    $RT::Handle->InsertACL unless $db_type eq 'Oracle';

    RT->InitLogging;
    __reconnect_rt();

    $RT::Handle->InsertInitialData
        unless $args{noinitialdata};

    $RT::Handle->InsertData( $RT::EtcPath . "/initialdata" )
        unless $args{noinitialdata} or $args{nodata};

    $self->bootstrap_plugins_db( %args );
}

sub bootstrap_plugins_paths {
    my $self = shift;
    my %args = @_;

    return unless $args{'plugins'};
    my @plugins = @{ $args{'plugins'} };

    my $cwd;
    if ( $args{'testing'} ) {
        require Cwd;
        $cwd = Cwd::getcwd();
    }

    require RT::Plugin;
    my $old_func = \&RT::Plugin::_BasePath;
    no warnings 'redefine';
    *RT::Plugin::_BasePath = sub {
        my $name = $_[0]->{'name'};

        return $cwd if $args{'testing'} && $name eq $args{'testing'};

        if ( grep $name eq $_, @plugins ) {
            my $variants = join "(?:|::|-|_)", map "\Q$_\E", split /::/, $name;
            my ($path) = map $ENV{$_}, grep /^CHIMPS_(?:$variants).*_ROOT$/i, keys %ENV;
            return $path if $path;
        }
        return $old_func->(@_);
    };
}

sub bootstrap_plugins_db {
    my $self = shift;
    my %args = @_;

    return unless $args{'plugins'};

    require File::Spec;

    my @plugins = @{ $args{'plugins'} };
    foreach my $name ( @plugins ) {
        my $plugin = RT::Plugin->new( name => $name );
        Test::More::diag( "Initializing DB for the $name plugin" )
            if $ENV{'TEST_VERBOSE'};

        my $etc_path = $plugin->Path('etc');
        Test::More::diag( "etc path of the plugin is '$etc_path'" )
            if $ENV{'TEST_VERBOSE'};

        unless ( -e $etc_path ) {
            # We can't tell if the plugin has no data, or we screwed up the etc/ path
            Test::More::ok(1, "There is no etc dir: no schema" );
            Test::More::ok(1, "There is no etc dir: no ACLs" );
            Test::More::ok(1, "There is no etc dir: no data" );
            next;
        }

        __reconnect_rt('as dba');

        { # schema
            my ($ret, $msg) = $RT::Handle->InsertSchema( undef, $etc_path );
            Test::More::ok($ret || $msg =~ /^Couldn't find schema/, "Created schema: ".($msg||''));
        }

        { # ACLs
            my ($ret, $msg) = $RT::Handle->InsertACL( undef, $etc_path );
            Test::More::ok($ret || $msg =~ /^Couldn't find ACLs/, "Created ACL: ".($msg||''));
        }

        # data
        my $data_file = File::Spec->catfile( $etc_path, 'initialdata' );
        if ( -e $data_file ) {
            __reconnect_rt();
            my ($ret, $msg) = $RT::Handle->InsertData( $data_file );;
            Test::More::ok($ret, "Inserted data".($msg||''));
        } else {
            Test::More::ok(1, "There is no data file" );
        }
    }
    __reconnect_rt();
}

sub _get_dbh {
    my ($dsn, $user, $pass) = @_;
    if ( $dsn =~ /Oracle/i ) {
        $ENV{'NLS_LANG'} = "AMERICAN_AMERICA.AL32UTF8";
        $ENV{'NLS_NCHAR'} = "AL32UTF8";
    }
    my $dbh = DBI->connect(
        $dsn, $user, $pass,
        { RaiseError => 0, PrintError => 1 },
    );
    unless ( $dbh ) {
        my $msg = "Failed to connect to $dsn as user '$user': ". $DBI::errstr;
        print STDERR $msg; exit -1;
    }
    return $dbh;
}

sub __create_database {
    # bootstrap with dba cred
    my $dbh = _get_dbh(
        RT::Handle->SystemDSN,
        $ENV{RT_DBA_USER}, $ENV{RT_DBA_PASSWORD}
    );

    unless ( $ENV{RT_TEST_PARALLEL} ) {
        # already dropped db in parallel tests, need to do so for other cases.
        __drop_database( $dbh );

    }
    RT::Handle->CreateDatabase( $dbh );
    $dbh->disconnect;
    $created_new_db++;
}

sub __drop_database {
    my $dbh = shift;

    # Pg doesn't like if you issue a DROP DATABASE while still connected
    # it's still may fail if web-server is out there and holding a connection
    __disconnect_rt();

    my $my_dbh = $dbh? 0 : 1;
    $dbh ||= _get_dbh(
        RT::Handle->SystemDSN,
        $ENV{RT_DBA_USER}, $ENV{RT_DBA_PASSWORD}
    );

    # We ignore errors intentionally by not checking the return value of
    # DropDatabase below, so let's also suppress DBI's printing of errors when
    # we overzealously drop.
    local $dbh->{PrintError} = 0;
    local $dbh->{PrintWarn} = 0;

    RT::Handle->DropDatabase( $dbh );
    $dbh->disconnect if $my_dbh;
}

sub __reconnect_rt {
    my $as_dba = shift;
    __disconnect_rt();

    # look at %DBIHandle and $PrevHandle in DBIx::SB::Handle for explanation
    $RT::Handle = RT::Handle->new;
    $RT::Handle->dbh( undef );
    $RT::Handle->Connect(
        $as_dba
        ? (User => $ENV{RT_DBA_USER}, Password => $ENV{RT_DBA_PASSWORD})
        : ()
    );
    $RT::Handle->PrintError;
    $RT::Handle->dbh->{PrintError} = 1;
    return $RT::Handle->dbh;
}

sub __disconnect_rt {
    # look at %DBIHandle and $PrevHandle in DBIx::SB::Handle for explanation
    $RT::Handle->dbh->disconnect if $RT::Handle and $RT::Handle->dbh;

    %DBIx::SearchBuilder::Handle::DBIHandle = ();
    $DBIx::SearchBuilder::Handle::PrevHandle = undef;

    $RT::Handle = undef;

    delete $RT::System->{attributes};

    DBIx::SearchBuilder::Record::Cachable->FlushCache
          if DBIx::SearchBuilder::Record::Cachable->can("FlushCache");
}


=head1 UTILITIES

=head2 load_or_create_user

=cut

sub load_or_create_user {
    my $self = shift;
    my %args = ( Privileged => 1, Disabled => 0, @_ );
    
    my $MemberOf = delete $args{'MemberOf'};
    $MemberOf = [ $MemberOf ] if defined $MemberOf && !ref $MemberOf;
    $MemberOf ||= [];

    my $obj = RT::User->new( RT->SystemUser );
    if ( $args{'Name'} ) {
        $obj->LoadByCols( Name => $args{'Name'} );
    } elsif ( $args{'EmailAddress'} ) {
        $obj->LoadByCols( EmailAddress => $args{'EmailAddress'} );
    } else {
        die "Name or EmailAddress is required";
    }
    if ( $obj->id ) {
        # cool
        $obj->SetPrivileged( $args{'Privileged'} || 0 )
            if ($args{'Privileged'}||0) != ($obj->Privileged||0);
        $obj->SetDisabled( $args{'Disabled'} || 0 )
            if ($args{'Disabled'}||0) != ($obj->Disabled||0);
    } else {
        my ($val, $msg) = $obj->Create( %args );
        die "$msg" unless $val;
    }

    # clean group membership
    {
        require RT::GroupMembers;
        my $gms = RT::GroupMembers->new( RT->SystemUser );
        my $groups_alias = $gms->Join(
            FIELD1 => 'GroupId', TABLE2 => 'Groups', FIELD2 => 'id',
        );
        $gms->Limit( ALIAS => $groups_alias, FIELD => 'Domain', VALUE => 'UserDefined' );
        $gms->Limit( FIELD => 'MemberId', VALUE => $obj->id );
        while ( my $group_member_record = $gms->Next ) {
            $group_member_record->Delete;
        }
    }

    # add new user to groups
    foreach ( @$MemberOf ) {
        my $group = RT::Group->new( RT::SystemUser() );
        $group->LoadUserDefinedGroup( $_ );
        die "couldn't load group '$_'" unless $group->id;
        $group->AddMember( $obj->id );
    }

    return $obj;
}

=head2 load_or_create_queue

=cut

sub load_or_create_queue {
    my $self = shift;
    my %args = ( Disabled => 0, @_ );
    my $obj = RT::Queue->new( RT->SystemUser );
    if ( $args{'Name'} ) {
        $obj->LoadByCols( Name => $args{'Name'} );
    } else {
        die "Name is required";
    }
    unless ( $obj->id ) {
        my ($val, $msg) = $obj->Create( %args );
        die "$msg" unless $val;
    } else {
        my @fields = qw(CorrespondAddress CommentAddress);
        foreach my $field ( @fields ) {
            next unless exists $args{ $field };
            next if $args{ $field } eq ($obj->$field || '');
            
            no warnings 'uninitialized';
            my $method = 'Set'. $field;
            my ($val, $msg) = $obj->$method( $args{ $field } );
            die "$msg" unless $val;
        }
    }

    return $obj;
}

sub delete_queue_watchers {
    my $self = shift;
    my @queues = @_;

    foreach my $q ( @queues ) {
        foreach my $t (qw(Cc AdminCc) ) {
            $q->DeleteWatcher( Type => $t, PrincipalId => $_->MemberId )
                foreach @{ $q->$t()->MembersObj->ItemsArrayRef };
        }
    }
}

sub create_tickets {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $self = shift;
    my $defaults = shift;
    my @data = @_;
    @data = sort { rand(100) <=> rand(100) } @data
        if delete $defaults->{'RandomOrder'};

    $defaults->{'Queue'} ||= 'General';

    my @res = ();
    while ( @data ) {
        my %args = %{ shift @data };
        $args{$_} = $res[ $args{$_} ]->id foreach
            grep $args{ $_ }, keys %RT::Ticket::LINKTYPEMAP;
        push @res, $self->create_ticket( %$defaults, %args );
    }
    return @res;
}

sub create_ticket {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $self = shift;
    my %args = @_;

    if ($args{Queue} && $args{Queue} =~ /\D/) {
        my $queue = RT::Queue->new(RT->SystemUser);
        if (my $id = $queue->Load($args{Queue}) ) {
            $args{Queue} = $id;
        } else {
            die ("Error: Invalid queue $args{Queue}");
        }
    }

    if ( my $content = delete $args{'Content'} ) {
        $args{'MIMEObj'} = MIME::Entity->build(
            From    => $args{'Requestor'},
            Subject => $args{'Subject'},
            Data    => $content,
        );
    }

    my $ticket = RT::Ticket->new( RT->SystemUser );
    my ( $id, undef, $msg ) = $ticket->Create( %args );
    Test::More::ok( $id, "ticket created" )
        or Test::More::diag("error: $msg");

    # hackish, but simpler
    if ( $args{'LastUpdatedBy'} ) {
        $ticket->__Set( Field => 'LastUpdatedBy', Value => $args{'LastUpdatedBy'} );
    }


    for my $field ( keys %args ) {
        #TODO check links and watchers

        if ( $field =~ /CustomField-(\d+)/ ) {
            my $cf = $1;
            my $got = join ',', sort map $_->Content,
                @{ $ticket->CustomFieldValues($cf)->ItemsArrayRef };
            my $expected = ref $args{$field}
                ? join( ',', sort @{ $args{$field} } )
                : $args{$field};
            Test::More::is( $got, $expected, 'correct CF values' );
        }
        else {
            next if ref $args{$field};
            next unless $ticket->can($field) or $ticket->_Accessible($field,"read");
            next if ref $ticket->$field();
            Test::More::is( $ticket->$field(), $args{$field}, "$field is correct" );
        }
    }

    return $ticket;
}

sub delete_tickets {
    my $self = shift;
    my $query = shift;
    my $tickets = RT::Tickets->new( RT->SystemUser );
    if ( $query ) {
        $tickets->FromSQL( $query );
    }
    else {
        $tickets->UnLimit;
    }
    while ( my $ticket = $tickets->Next ) {
        $ticket->Delete;
    }
}

=head2 load_or_create_custom_field

=cut

sub load_or_create_custom_field {
    my $self = shift;
    my %args = ( Disabled => 0, @_ );
    my $obj = RT::CustomField->new( RT->SystemUser );
    if ( $args{'Name'} ) {
        $obj->LoadByName( Name => $args{'Name'}, Queue => $args{'Queue'} );
    } else {
        die "Name is required";
    }
    unless ( $obj->id ) {
        my ($val, $msg) = $obj->Create( %args );
        die "$msg" unless $val;
    }

    return $obj;
}

sub last_ticket {
    my $self = shift;
    my $current = shift;
    $current = $current ? RT::CurrentUser->new($current) : RT->SystemUser;
    my $tickets = RT::Tickets->new( $current );
    $tickets->OrderBy( FIELD => 'id', ORDER => 'DESC' );
    $tickets->Limit( FIELD => 'id', OPERATOR => '>', VALUE => '0' );
    $tickets->RowsPerPage( 1 );
    return $tickets->First;
}

sub store_rights {
    my $self = shift;

    require RT::ACE;
    # fake construction
    RT::ACE->new( RT->SystemUser );
    my @fields = keys %{ RT::ACE->_ClassAccessible };

    require RT::ACL;
    my $acl = RT::ACL->new( RT->SystemUser );
    $acl->Limit( FIELD => 'RightName', OPERATOR => '!=', VALUE => 'SuperUser' );

    my @res;
    while ( my $ace = $acl->Next ) {
        my $obj = $ace->PrincipalObj->Object;
        if ( $obj->isa('RT::Group') && $obj->Type eq 'UserEquiv' && $obj->Instance == RT->Nobody->id ) {
            next;
        }

        my %tmp = ();
        foreach my $field( @fields ) {
            $tmp{ $field } = $ace->__Value( $field );
        }
        push @res, \%tmp;
    }
    return @res;
}

sub restore_rights {
    my $self = shift;
    my @entries = @_;
    foreach my $entry ( @entries ) {
        my $ace = RT::ACE->new( RT->SystemUser );
        my ($status, $msg) = $ace->RT::Record::Create( %$entry );
        unless ( $status ) {
            Test::More::diag "couldn't create a record: $msg";
        }
    }
}

sub set_rights {
    my $self = shift;

    require RT::ACL;
    my $acl = RT::ACL->new( RT->SystemUser );
    $acl->Limit( FIELD => 'RightName', OPERATOR => '!=', VALUE => 'SuperUser' );
    while ( my $ace = $acl->Next ) {
        my $obj = $ace->PrincipalObj->Object;
        if ( $obj->isa('RT::Group') && $obj->Type eq 'UserEquiv' && $obj->Instance == RT->Nobody->id ) {
            next;
        }
        $ace->Delete;
    }
    return $self->add_rights( @_ );
}

sub add_rights {
    my $self = shift;
    my @list = ref $_[0]? @_: @_? { @_ }: ();

    require RT::ACL;
    foreach my $e (@list) {
        my $principal = delete $e->{'Principal'};
        unless ( ref $principal ) {
            if ( $principal =~ /^(everyone|(?:un)?privileged)$/i ) {
                $principal = RT::Group->new( RT->SystemUser );
                $principal->LoadSystemInternalGroup($1);
            } elsif ( $principal =~ /^(Owner|Requestor|(?:Admin)?Cc)$/i ) {
                $principal = RT::Group->new( RT->SystemUser );
                $principal->LoadByCols(
                    Domain => (ref($e->{'Object'})||'RT::System').'-Role',
                    Type => $1,
                    ref($e->{'Object'})? (Instance => $e->{'Object'}->id): (),
                );
            } else {
                die "principal is not an object, but also is not name of a system group";
            }
        }
        unless ( $principal->isa('RT::Principal') ) {
            if ( $principal->can('PrincipalObj') ) {
                $principal = $principal->PrincipalObj;
            }
        }
        my @rights = ref $e->{'Right'}? @{ $e->{'Right'} }: ($e->{'Right'});
        foreach my $right ( @rights ) {
            my ($status, $msg) = $principal->GrantRight( %$e, Right => $right );
            $RT::Logger->debug($msg);
        }
    }
    return 1;
}

sub run_mailgate {
    my $self = shift;

    require RT::Test::Web;
    my %args = (
        url     => RT::Test::Web->rt_base_url,
        message => '',
        action  => 'correspond',
        queue   => 'General',
        debug   => 1,
        command => $RT::BinPath .'/rt-mailgate',
        @_
    );
    my $message = delete $args{'message'};

    $args{after_open} = sub {
        my $child_in = shift;
        if ( UNIVERSAL::isa($message, 'MIME::Entity') ) {
            $message->print( $child_in );
        } else {
            print $child_in $message;
        }
    };

    $self->run_and_capture(%args);
}

sub run_and_capture {
    my $self = shift;
    my %args = @_;

    my $after_open = delete $args{after_open};

    my $cmd = delete $args{'command'};
    die "Couldn't find command ($cmd)" unless -f $cmd;

    $cmd .= ' --debug' if delete $args{'debug'};

    while( my ($k,$v) = each %args ) {
        next unless $v;
        $cmd .= " --$k '$v'";
    }
    $cmd .= ' 2>&1';

    DBIx::SearchBuilder::Record::Cachable->FlushCache;

    require IPC::Open2;
    my ($child_out, $child_in);
    my $pid = IPC::Open2::open2($child_out, $child_in, $cmd);

    $after_open->($child_in, $child_out) if $after_open;

    close $child_in;

    my $result = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;
    return ($?, $result);
}

sub send_via_mailgate_and_http {
    my $self = shift;
    my $message = shift;
    my %args = (@_);

    my ($status, $gate_result) = $self->run_mailgate(
        message => $message, %args
    );

    my $id;
    unless ( $status >> 8 ) {
        ($id) = ($gate_result =~ /Ticket:\s*(\d+)/i);
        unless ( $id ) {
            Test::More::diag "Couldn't find ticket id in text:\n$gate_result"
                if $ENV{'TEST_VERBOSE'};
        }
    } else {
        Test::More::diag "Mailgate output:\n$gate_result"
            if $ENV{'TEST_VERBOSE'};
    }
    return ($status, $id);
}


sub send_via_mailgate {
    my $self    = shift;
    my $message = shift;
    my %args = ( action => 'correspond',
                 queue  => 'General',
                 @_
               );

    if ( UNIVERSAL::isa( $message, 'MIME::Entity' ) ) {
        $message = $message->as_string;
    }

    my ( $status, $error_message, $ticket )
        = RT::Interface::Email::Gateway( {%args, message => $message} );
    return ( $status, $ticket ? $ticket->id : 0 );

}


sub open_mailgate_ok {
    my $class   = shift;
    my $baseurl = shift;
    my $queue   = shift || 'general';
    my $action  = shift || 'correspond';
    Test::More::ok(open(my $mail, '|-', "$RT::BinPath/rt-mailgate --url $baseurl --queue $queue --action $action"), "Opened the mailgate - $!");
    return $mail;
}


sub close_mailgate_ok {
    my $class = shift;
    my $mail  = shift;
    close $mail;
    Test::More::is ($? >> 8, 0, "The mail gateway exited normally. yay");
}

sub mailsent_ok {
    my $class = shift;
    my $expected  = shift;

    my $mailsent = scalar grep /\S/, split /%% split me! %%\n/,
        RT::Test->file_content(
            $tmp{'mailbox'},
            'unlink' => 0,
            noexist => 1
        );

    Test::More::is(
        $mailsent, $expected,
        "The number of mail sent ($expected) matches. yay"
    );
}

sub fetch_caught_mails {
    my $self = shift;
    return grep /\S/, split /%% split me! %%\n/,
        RT::Test->file_content(
            $tmp{'mailbox'},
            'unlink' => 1,
            noexist => 1
        );
}

sub clean_caught_mails {
    unlink $tmp{'mailbox'};
}

=head2 get_relocatable_dir

Takes a path relative to the location of the test file that is being
run and returns a path that takes the invocation path into account.

e.g. RT::Test::get_relocatable_dir(File::Spec->updir(), 'data', 'emails')

=cut

sub get_relocatable_dir {
    (my $volume, my $directories, my $file) = File::Spec->splitpath($0);
    if (File::Spec->file_name_is_absolute($directories)) {
        return File::Spec->catdir($directories, @_);
    } else {
        return File::Spec->catdir(File::Spec->curdir(), $directories, @_);
    }
}

=head2 get_relocatable_file

Same as get_relocatable_dir, but takes a file and a path instead
of just a path.

e.g. RT::Test::get_relocatable_file('test-email',
        (File::Spec->updir(), 'data', 'emails'))

=cut

sub get_relocatable_file {
    my $file = shift;
    return File::Spec->catfile(get_relocatable_dir(@_), $file);
}

sub get_abs_relocatable_dir {
    (my $volume, my $directories, my $file) = File::Spec->splitpath($0);
    if (File::Spec->file_name_is_absolute($directories)) {
        return File::Spec->catdir($directories, @_);
    } else {
        return File::Spec->catdir(Cwd->getcwd(), $directories, @_);
    }
}

sub gnupg_homedir {
    my $self = shift;
    File::Temp->newdir(
        DIR => $tmp{directory},
        CLEANUP => 0,
    );
}

sub import_gnupg_key {
    my $self = shift;
    my $key  = shift;
    my $type = shift || 'secret';

    $key =~ s/\@/-at-/g;
    $key .= ".$type.key";

    require RT::Crypt::GnuPG;

    # simple strategy find data/gnupg/keys, from the dir where test file lives
    # to updirs, try 3 times in total
    my $path = File::Spec->catfile( 'data', 'gnupg', 'keys' );
    my $abs_path;
    for my $up ( 0 .. 2 ) {
        my $p = get_relocatable_dir($path);
        if ( -e $p ) {
            $abs_path = $p;
            last;
        }
        else {
            $path = File::Spec->catfile( File::Spec->updir(), $path );
        }
    }

    die "can't find the dir where gnupg keys are stored"
      unless $abs_path;

    return RT::Crypt::GnuPG::ImportKey(
        RT::Test->file_content( [ $abs_path, $key ] ) );
}


sub lsign_gnupg_key {
    my $self = shift;
    my $key = shift;

    require RT::Crypt::GnuPG; require GnuPG::Interface;
    my $gnupg = GnuPG::Interface->new();
    my %opt = RT->Config->Get('GnuPGOptions');
    $gnupg->options->hash_init(
        RT::Crypt::GnuPG::_PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    my %handle; 
    my $handles = GnuPG::Handles->new(
        stdin   => ($handle{'input'}   = IO::Handle->new()),
        stdout  => ($handle{'output'}  = IO::Handle->new()),
        stderr  => ($handle{'error'}   = IO::Handle->new()),
        logger  => ($handle{'logger'}  = IO::Handle->new()),
        status  => ($handle{'status'}  = IO::Handle->new()),
        command => ($handle{'command'} = IO::Handle->new()),
    );

    eval {
        local $SIG{'CHLD'} = 'DEFAULT';
        local @ENV{'LANG', 'LC_ALL'} = ('C', 'C');
        my $pid = $gnupg->wrap_call(
            handles => $handles,
            commands => ['--lsign-key'],
            command_args => [$key],
        );
        close $handle{'input'};
        while ( my $str = readline $handle{'status'} ) {
            if ( $str =~ /^\[GNUPG:\]\s*GET_BOOL sign_uid\..*/ ) {
                print { $handle{'command'} } "y\n";
            }
        }
        waitpid $pid, 0;
    };
    my $err = $@;
    close $handle{'output'};

    my %res;
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $err || $res{'exit_code'} ) {
        $res{'message'} = $err? $err : "gpg exitted with error code ". ($res{'exit_code'} >> 8);
    }
    return %res;
}

sub trust_gnupg_key {
    my $self = shift;
    my $key = shift;

    require RT::Crypt::GnuPG; require GnuPG::Interface;
    my $gnupg = GnuPG::Interface->new();
    my %opt = RT->Config->Get('GnuPGOptions');
    $gnupg->options->hash_init(
        RT::Crypt::GnuPG::_PrepareGnuPGOptions( %opt ),
        meta_interactive => 0,
    );

    my %handle; 
    my $handles = GnuPG::Handles->new(
        stdin   => ($handle{'input'}   = IO::Handle->new()),
        stdout  => ($handle{'output'}  = IO::Handle->new()),
        stderr  => ($handle{'error'}   = IO::Handle->new()),
        logger  => ($handle{'logger'}  = IO::Handle->new()),
        status  => ($handle{'status'}  = IO::Handle->new()),
        command => ($handle{'command'} = IO::Handle->new()),
    );

    eval {
        local $SIG{'CHLD'} = 'DEFAULT';
        local @ENV{'LANG', 'LC_ALL'} = ('C', 'C');
        my $pid = $gnupg->wrap_call(
            handles => $handles,
            commands => ['--edit-key'],
            command_args => [$key],
        );
        close $handle{'input'};

        my $done = 0;
        while ( my $str = readline $handle{'status'} ) {
            if ( $str =~ /^\[GNUPG:\]\s*\QGET_LINE keyedit.prompt/ ) {
                if ( $done ) {
                    print { $handle{'command'} } "quit\n";
                } else {
                    print { $handle{'command'} } "trust\n";
                }
            } elsif ( $str =~ /^\[GNUPG:\]\s*\QGET_LINE edit_ownertrust.value/ ) {
                print { $handle{'command'} } "5\n";
            } elsif ( $str =~ /^\[GNUPG:\]\s*\QGET_BOOL edit_ownertrust.set_ultimate.okay/ ) {
                print { $handle{'command'} } "y\n";
                $done = 1;
            }
        }
        waitpid $pid, 0;
    };
    my $err = $@;
    close $handle{'output'};

    my %res;
    $res{'exit_code'} = $?;
    foreach ( qw(error logger status) ) {
        $res{$_} = do { local $/; readline $handle{$_} };
        delete $res{$_} unless $res{$_} && $res{$_} =~ /\S/s;
        close $handle{$_};
    }
    $RT::Logger->debug( $res{'status'} ) if $res{'status'};
    $RT::Logger->warning( $res{'error'} ) if $res{'error'};
    $RT::Logger->error( $res{'logger'} ) if $res{'logger'} && $?;
    if ( $err || $res{'exit_code'} ) {
        $res{'message'} = $err? $err : "gpg exitted with error code ". ($res{'exit_code'} >> 8);
    }
    return %res;
}

sub started_ok {
    my $self = shift;

    require RT::Test::Web;

    if ($rttest_opt{nodb} and not $rttest_opt{server_ok}) {
        die "You are trying to use a test web server without a database. "
           ."You may want noinitialdata => 1 instead. "
           ."Pass server_ok => 1 if you know what you're doing.";
    }


    $ENV{'RT_TEST_WEB_HANDLER'} = undef
        if $rttest_opt{actual_server} && ($ENV{'RT_TEST_WEB_HANDLER'}||'') eq 'inline';
    $ENV{'RT_TEST_WEB_HANDLER'} ||= 'plack';
    my $which = $ENV{'RT_TEST_WEB_HANDLER'};
    my ($server, $variant) = split /\+/, $which, 2;

    my $function = 'start_'. $server .'_server';
    unless ( $self->can($function) ) {
        die "Don't know how to start server '$server'";
    }
    return $self->$function( variant => $variant, @_ );
}

sub test_app {
    my $self = shift;
    my %server_opt = @_;

    my $app;

    my $warnings = "";
    open( my $warn_fh, ">", \$warnings );
    local *STDERR = $warn_fh;

    if ($server_opt{variant} and $server_opt{variant} eq 'rt-server') {
        $app = do {
            my $file = "$RT::SbinPath/rt-server";
            my $psgi = do $file;
            unless ($psgi) {
                die "Couldn't parse $file: $@" if $@;
                die "Couldn't do $file: $!"    unless defined $psgi;
                die "Couldn't run $file"       unless $psgi;
            }
            $psgi;
        };
    } else {
        require RT::Interface::Web::Handler;
        $app = RT::Interface::Web::Handler->PSGIApp;
    }

    require Plack::Middleware::Test::StashWarnings;
    my $stashwarnings = Plack::Middleware::Test::StashWarnings->new;
    $app = $stashwarnings->wrap($app);

    if ($server_opt{basic_auth}) {
        require Plack::Middleware::Auth::Basic;
        $app = Plack::Middleware::Auth::Basic->wrap(
            $app,
            authenticator => sub {
                my ($username, $password) = @_;
                return $username eq 'root' && $password eq 'password';
            }
        );
    }

    close $warn_fh;
    $stashwarnings->add_warning( $warnings ) if $warnings;

    return $app;
}

sub start_plack_server {
    my $self = shift;

    require Plack::Loader;
    my $plack_server = Plack::Loader->load
        ('Standalone',
         port => $port,
         server_ready => sub {
             kill 'USR1' => getppid();
         });

    # We are expecting a USR1 from the child process after it's ready
    # to listen.  We set this up _before_ we fork to avoid race
    # conditions.
    my $handled;
    local $SIG{USR1} = sub { $handled = 1};

    __disconnect_rt();
    my $pid = fork();
    die "failed to fork" unless defined $pid;

    if ($pid) {
        sleep 15 unless $handled;
        Test::More::diag "did not get expected USR1 for test server readiness"
            unless $handled;
        push @SERVERS, $pid;
        my $Tester = Test::Builder->new;
        $Tester->ok(1, "started plack server ok");

        __reconnect_rt()
            unless $rttest_opt{nodb};
        return ("http://localhost:$port", RT::Test::Web->new);
    }

    require POSIX;
    if ( $^O !~ /MSWin32/ ) {
        POSIX::setsid()
            or die "Can't start a new session: $!";
    }

    # stick this in a scope so that when $app is garbage collected,
    # StashWarnings can complain about unhandled warnings
    do {
        $plack_server->run($self->test_app(@_));
    };

    exit;
}

our $TEST_APP;
sub start_inline_server {
    my $self = shift;

    require Test::WWW::Mechanize::PSGI;
    unshift @RT::Test::Web::ISA, 'Test::WWW::Mechanize::PSGI';

    # Clear out squished CSS and JS cache, since it's retained across
    # servers, since it's in-process
    RT::Interface::Web->ClearSquished;

    Test::More::ok(1, "psgi test server ok");
    $TEST_APP = $self->test_app(@_);
    return ("http://localhost:$port", RT::Test::Web->new);
}

sub start_apache_server {
    my $self = shift;
    my %server_opt = @_;
    $server_opt{variant} ||= 'mod_perl';
    $ENV{RT_TEST_WEB_HANDLER} = "apache+$server_opt{variant}";

    require RT::Test::Apache;
    my $pid = RT::Test::Apache->start_server(
        %server_opt,
        port => $port,
        tmp => \%tmp
    );
    push @SERVERS, $pid;

    my $url = RT->Config->Get('WebURL');
    $url =~ s!/$!!;
    return ($url, RT::Test::Web->new);
}

sub stop_server {
    my $self = shift;
    my $in_end = shift;
    return unless @SERVERS;

    my $sig = 'TERM';
    $sig = 'INT' if $ENV{'RT_TEST_WEB_HANDLER'} eq "plack";
    kill $sig, @SERVERS;
    foreach my $pid (@SERVERS) {
        if ($ENV{RT_TEST_WEB_HANDLER} =~ /^apache/) {
            sleep 1 while kill 0, $pid;
        } else {
            waitpid $pid, 0;
        }
    }

    @SERVERS = ();
}

sub temp_directory {
    return $tmp{'directory'};
}

sub file_content {
    my $self = shift;
    my $path = shift;
    my %args = @_;

    $path = File::Spec->catfile( @$path ) if ref $path eq 'ARRAY';

    Test::More::diag "reading content of '$path'" if $ENV{'TEST_VERBOSE'};

    open( my $fh, "<:raw", $path )
        or do {
            warn "couldn't open file '$path': $!" unless $args{noexist};
            return ''
        };
    my $content = do { local $/; <$fh> };
    close $fh;

    unlink $path if $args{'unlink'};

    return $content;
}

sub find_executable {
    my $self = shift;
    my $name = shift;

    require File::Spec;
    foreach my $dir ( split /:/, $ENV{'PATH'} ) {
        my $fpath = File::Spec->catpath(
            (File::Spec->splitpath( $dir, 'no file' ))[0..1], $name
        );
        next unless -e $fpath && -r _ && -x _;
        return $fpath;
    }
    return undef;
}

sub diag {
    return unless $ENV{RT_TEST_VERBOSE} || $ENV{TEST_VERBOSE};
    goto \&Test::More::diag;
}

sub parse_mail {
    my $mail = shift;
    require RT::EmailParser;
    my $parser = RT::EmailParser->new;
    $parser->ParseMIMEEntityFromScalar( $mail );
    return $parser->Entity;
}

sub works {
    Test::More::ok($_[0], $_[1] || 'This works');
}

sub fails {
    Test::More::ok(!$_[0], $_[1] || 'This should fail');
}

END {
    my $Test = RT::Test->builder;
    return if $Test->{Original_Pid} != $$;


    # we are in END block and should protect our exit code
    # so calls below may call system or kill that clobbers $?
    local $?;

    RT::Test->stop_server(1);

    # not success
    if ( !$Test->is_passing ) {
        $tmp{'directory'}->unlink_on_destroy(0);

        Test::More::diag(
            "Some tests failed or we bailed out, tmp directory"
            ." '$tmp{directory}' is not cleaned"
        );
    }

    if ( $ENV{RT_TEST_PARALLEL} && $created_new_db ) {
        __drop_database();
    }

    # Drop our port from t/tmp/ports; do this after dropping the
    # database, as our port lock is also a lock on the database name.
    if ($port) {
        my %ports;
        my $portfile = "$tmp{'directory'}/../ports";
        sysopen(PORTS, $portfile, O_RDWR|O_CREAT)
            or die "Can't write to ports file $portfile: $!";
        flock(PORTS, LOCK_EX)
            or die "Can't write-lock ports file $portfile: $!";
        $ports{$_}++ for split ' ', join("",<PORTS>);
        delete $ports{$port};
        seek(PORTS, 0, 0);
        truncate(PORTS, 0);
        print PORTS "$_\n" for sort {$a <=> $b} keys %ports;
        close(PORTS) or die "Can't close ports file: $!";
    }
}

{ 
    # ease the used only once warning
    no warnings;
    no strict 'refs';
    %{'RT::I18N::en_us::Lexicon'};
    %{'Win32::Locale::Lexicon'};
}

1;
