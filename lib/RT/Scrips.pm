# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2011 Best Practical Solutions, LLC
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

=head1 NAME

  RT::Scrips - a collection of RT Scrip objects

=head1 SYNOPSIS

  use RT::Scrips;

=head1 DESCRIPTION


=head1 METHODS



=cut


package RT::Scrips;

use strict;
use warnings;

use RT::Scrip;
use RT::ObjectScrips;

use base 'RT::SearchBuilder';

sub Table { 'Scrips'}


=head2 LimitToQueue

Takes a queue id (numerical) as its only argument. Makes sure that 
Scopes it pulls out apply to this queue (or another that you've selected with
another call to this method

=cut

sub LimitToQueue  {
    my $self = shift;
    my %args = @_%2? (Queue => @_) : @_;
    return unless defined $args{'Queue'};

    my $alias = RT::ObjectScrips->new( $self->CurrentUser )
        ->JoinTargetToThis( $self, %args );
    $self->Limit(
        ALIAS => $alias,
        FIELD => 'ObjectId',
        VALUE => int $args{'Queue'},
    );
}


=head2 LimitToGlobal

Makes sure that 
Scopes it pulls out apply to all queues (or another that you've selected with
another call to this method or LimitToQueue

=cut


sub LimitToGlobal  {
    my $self = shift;
    return $self->LimitToQueue(0, @_);
}

sub LimitToAdded {
    my $self = shift;
    return RT::ObjectScrips->new( $self->CurrentUser )
        ->LimitTargetToApplied( $self => @_ );
}

sub LimitToNotAdded {
    my $self = shift;
    return RT::ObjectScrips->new( $self->CurrentUser )
        ->LimitTargetToNotApplied( $self => @_ );
}

sub ApplySortOrder {
    my $self = shift;
    my $order = shift || 'ASC';
    $self->OrderByCols( {
        ALIAS => RT::ObjectScrips->new( $self->CurrentUser )
            ->JoinTargetToThis( $self => @_ )
        ,
        FIELD => 'SortOrder',
        ORDER => $order,
    } );
}

# {{{ sub Next 

=head2 Next

Returns the next scrip that this user can see.

=cut
  
sub Next {
    my $self = shift;
    
    
    my $Scrip = $self->SUPER::Next();
    if ((defined($Scrip)) and (ref($Scrip))) {

	if ($Scrip->CurrentUserHasRight('ShowScrips')) {
	    return($Scrip);
	}
	
	#If the user doesn't have the right to show this scrip
	else {	
	    return($self->Next());
	}
    }
    #if there never was any scrip
    else {
	return(undef);
    }	
    
}

=head2 Apply

Run through the relevant scrips.  Scrips will run in order based on 
description.  (Most common use case is to prepend a number to the description,
forcing the scrips to run in ascending alphanumerical order.)

=cut

sub Apply {
    my $self = shift;

    my %args = ( TicketObj      => undef,
                 Ticket         => undef,
                 Transaction    => undef,
                 TransactionObj => undef,
                 Stage          => undef,
                 Type           => undef,
                 @_ );

    $self->Prepare(%args);
    $self->Commit();

}

=head2 Commit

Commit all of this object's prepared scrips

=cut

sub Commit {
    my $self = shift;

    # RT::Scrips->_SetupSourceObjects will clobber
    # the CurrentUser, but we need to keep this ticket
    # so that the _TransactionBatch cache is maintained
    # and doesn't run twice.  sigh.
    $self->_StashCurrentUser( TicketObj => $self->{TicketObj} ) if $self->{TicketObj};

    #We're really going to need a non-acled ticket for the scrips to work
    $self->_SetupSourceObjects( TicketObj      => $self->{'TicketObj'},
                                TransactionObj => $self->{'TransactionObj'} );
    
    foreach my $scrip (@{$self->Prepared}) {
        $RT::Logger->debug(
            "Committing scrip #". $scrip->id
            ." on txn #". $self->{'TransactionObj'}->id
            ." of ticket #". $self->{'TicketObj'}->id
        );

        $scrip->Commit( TicketObj      => $self->{'TicketObj'},
                        TransactionObj => $self->{'TransactionObj'} );
    }

    # Apply the bandaid.
    $self->_RestoreCurrentUser( TicketObj => $self->{TicketObj} ) if $self->{TicketObj};
}


=head2 Prepare

Only prepare the scrips, returning an array of the scrips we're interested in
in order of preparation, not execution

=cut

sub Prepare { 
    my $self = shift;
    my %args = ( TicketObj      => undef,
                 Ticket         => undef,
                 Transaction    => undef,
                 TransactionObj => undef,
                 Stage          => undef,
                 Type           => undef,
                 @_ );

    # RT::Scrips->_SetupSourceObjects will clobber
    # the CurrentUser, but we need to keep this ticket
    # so that the _TransactionBatch cache is maintained
    # and doesn't run twice.  sigh.
    $self->_StashCurrentUser( TicketObj => $args{TicketObj} ) if $args{TicketObj};

    #We're really going to need a non-acled ticket for the scrips to work
    $self->_SetupSourceObjects( TicketObj      => $args{'TicketObj'},
                                Ticket         => $args{'Ticket'},
                                TransactionObj => $args{'TransactionObj'},
                                Transaction    => $args{'Transaction'} );


    $self->_FindScrips( Stage => $args{'Stage'}, Type => $args{'Type'} );


    #Iterate through each script and check it's applicability.
    while ( my $scrip = $self->Next() ) {

          unless ( $scrip->IsApplicable(
                                     TicketObj      => $self->{'TicketObj'},
                                     TransactionObj => $self->{'TransactionObj'}
                   ) ) {
                   $RT::Logger->debug("Skipping Scrip #".$scrip->Id." because it isn't applicable");
                   next;
               }

        #If it's applicable, prepare and commit it
          unless ( $scrip->Prepare( TicketObj      => $self->{'TicketObj'},
                                    TransactionObj => $self->{'TransactionObj'}
                   ) ) {
                   $RT::Logger->debug("Skipping Scrip #".$scrip->Id." because it didn't Prepare");
                   next;
               }
        push @{$self->{'prepared_scrips'}}, $scrip;

    }

    # Apply the bandaid.
    $self->_RestoreCurrentUser( TicketObj => $args{TicketObj} ) if $args{TicketObj};


    return (@{$self->Prepared});

};

=head2 Prepared

Returns an arrayref of the scrips this object has prepared


=cut

sub Prepared {
    my $self = shift;
    return ($self->{'prepared_scrips'} || []);
}

=head2 _StashCurrentUser TicketObj => RT::Ticket

Saves aside the current user of the original ticket that was passed to these scrips.
This is used to make sure that we don't accidentally leak the RT_System current user
back to the calling code.

=cut

sub _StashCurrentUser {
    my $self = shift;
    my %args = @_;

    $self->{_TicketCurrentUser} = $args{TicketObj}->CurrentUser;
}

=head2 _RestoreCurrentUser TicketObj => RT::Ticket

Uses the current user saved by _StashCurrentUser to reset a Ticket object
back to the caller's current user and avoid leaking an RT_System ticket to
calling code.

=cut

sub _RestoreCurrentUser {
    my $self = shift;
    my %args = @_;
    unless ( $self->{_TicketCurrentUser} ) {
        RT->Logger->debug("Called _RestoreCurrentUser without a stashed current user object");
        return;
    }
    $args{TicketObj}->CurrentUser($self->{_TicketCurrentUser});

}

=head2  _SetupSourceObjects { TicketObj , Ticket, Transaction, TransactionObj }

Setup a ticket and transaction for this Scrip collection to work with as it runs through the 
relevant scrips.  (Also to figure out which scrips apply)

Returns: nothing

=cut


sub _SetupSourceObjects {

    my $self = shift;
    my %args = ( 
            TicketObj => undef,
            Ticket => undef,
            Transaction => undef,
            TransactionObj => undef,
            @_ );


    if ( $self->{'TicketObj'} = $args{'TicketObj'} ) {
        # This clobbers the passed in TicketObj by turning it into one
        # whose current user is RT_System.  Anywhere in the Web UI
        # currently calling into this is thus susceptable to a privilege
        # leak; the only current call site is ->Apply, which bandaids
        # over the top of this by re-asserting the CurrentUser
        # afterwards.
        $self->{'TicketObj'}->CurrentUser( $self->CurrentUser );
    }
    else {
        $self->{'TicketObj'} = RT::Ticket->new( $self->CurrentUser );
        $self->{'TicketObj'}->Load( $args{'Ticket'} )
          || $RT::Logger->err("$self couldn't load ticket $args{'Ticket'}");
    }

    if ( ( $self->{'TransactionObj'} = $args{'TransactionObj'} ) ) {
        $self->{'TransactionObj'}->CurrentUser( $self->CurrentUser );
    }
    else {
        $self->{'TransactionObj'} = RT::Transaction->new( $self->CurrentUser );
        $self->{'TransactionObj'}->Load( $args{'Transaction'} )
          || $RT::Logger->err( "$self couldn't load transaction $args{'Transaction'}");
    }
} 



=head2 _FindScrips

Find only the apropriate scrips for whatever we're doing now.  Order them 
by their description.  (Most common use case is to prepend a number to the
description, forcing the scrips to display and run in ascending alphanumerical 
order.)

=cut

sub _FindScrips {
    my $self = shift;
    my %args = (
                 Stage => undef,
                 Type => undef,
                 @_ );


    $self->LimitToQueue( $self->{'TicketObj'}->QueueObj->Id )
      ;    #Limit it to  $Ticket->QueueObj->Id
    $self->LimitToGlobal();
      # or to "global"

    $self->Limit( FIELD => "Stage", VALUE => $args{'Stage'} );

    my $ConditionsAlias = $self->NewAlias('ScripConditions');

    $self->Join(
        ALIAS1 => 'main',
        FIELD1 => 'ScripCondition',
        ALIAS2 => $ConditionsAlias,
        FIELD2 => 'id'
    );

    #We only want things where the scrip applies to this sort of transaction
    # TransactionBatch stage can define list of transaction
    foreach( split /\s*,\s*/, ($args{'Type'} || '') ) {
	$self->Limit(
	    ALIAS           => $ConditionsAlias,
	    FIELD           => 'ApplicableTransTypes',
	    OPERATOR        => 'LIKE',
	    VALUE           => $_,
	    ENTRYAGGREGATOR => 'OR',
	)
    }

    # Or where the scrip applies to any transaction
    $self->Limit(
        ALIAS           => $ConditionsAlias,
        FIELD           => 'ApplicableTransTypes',
        OPERATOR        => 'LIKE',
        VALUE           => "Any",
        ENTRYAGGREGATOR => 'OR',
    );

    $self->ApplySortOrder;

    # we call Count below, but later we always do search
    # so just do search and get count from results
    $self->_DoSearch if $self->{'must_redo_search'};

    $RT::Logger->debug(
        "Found ". $self->Count ." scrips for $args{'Stage'} stage"
        ." with applicable type(s) $args{'Type'}"
        ." for txn #".$self->{TransactionObj}->Id
        ." on ticket #".$self->{TicketObj}->Id
    );
}




=head2 NewItem

Returns an empty new RT::Scrip item

=cut

sub NewItem {
    my $self = shift;
    return(RT::Scrip->new($self->CurrentUser));
}
RT::Base->_ImportOverlays();

1;
