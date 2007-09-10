#!/usr/bin/perl -w
use strict;

use Test::More tests => 80;
use RT::Test;
use RT::ScripAction::SendEmail;

eval 'use GnuPG::Interface; 1' or plan skip_all => 'GnuPG required.';

RT::Test->set_mail_catcher;

RT->Config->set( LogToScreen => 'debug' );
RT->Config->set( LogStackTraces => 'error' );
RT->Config->set( CommentAddress => 'general@example.com');
RT->Config->set( CorrespondAddress => 'general@example.com');
RT->Config->set( DefaultSearchResultFormat => qq{
   '<B><A HREF="__WebPath__/Ticket/Display.html?id=__id__">__id__</a></B>/TITLE:#',
   '<B><A HREF="__WebPath__/Ticket/Display.html?id=__id__">__Subject__</a></B>/TITLE:Subject',
   'OO-__OwnerName__-O',
   'OR-__Requestors__-O',
   'KO-__KeyOwnerName__-K',
   'KR-__KeyRequestors__-K',
   Status});

use File::Spec ();
use Cwd;
my $homedir = File::Spec->catdir( cwd(), qw(lib t data crypt-gnupg) );

use_ok('RT::Crypt::GnuPG');

RT->Config->set( 'GnuPG',
                 Enable => 1,
                 OutgoingMessagesFormat => 'RFC' );

RT->Config->set( 'GnuPGOptions',
                 homedir => $homedir,
                 passphrase => 'recipient',
                 'no-permission-warning' => undef);
RT->Config->set( 'MailPlugins' => 'Auth::MailFrom', 'Auth::GnuPG' );

ok(my $user = RT::Model::User->new($RT::SystemUser));
ok($user->load('root'), "Loaded user 'root'");
$user->set_EmailAddress('recipient@example.com');

my $queue = RT::Test->load_or_create_queue(
    Name              => 'General',
    CorrespondAddress => 'general@example.com',
);
ok $queue && $queue->id, 'loaded or created queue';
my $qid = $queue->id;

RT::Test->set_rights(
    Principal => 'Everyone',
    Right => ['CreateTicket', 'ShowTicket', 'SeeQueue', 'ModifyTicket'],
);

my ($baseurl, $m) = RT::Test->started_ok;
ok $m->login, 'logged in';

$m->get_ok("/Admin/Queues/Modify.html?id=$qid");
$m->form_with_fields('Sign', 'Encrypt');
$m->field(Encrypt => 1);
$m->submit;

unlink "t/mailbox";

$m->goto_create_ticket( $queue );
$m->form_name('TicketCreate');

$m->field('Subject', 'Encryption test');
$m->field('Content', 'Some content');
ok($m->value('Encrypt', 2), "encrypt tick box is checked");
ok(!$m->value('Sign', 2), "sign tick box is unchecked");
$m->submit;
is($m->status, 200, "request successful");

$m->get($baseurl); # ensure that the mail has been processed

my @mail = RT::Test->fetch_caught_mails;
ok(@mail, "got some mail");

$user->set_EmailAddress('general@example.com');
for my $mail (@mail) {
    unlike $mail, qr/Some content/, "outgoing mail was encrypted";

    my ($content_type) = $mail =~ /^(Content-Type: .*)/m;
    my ($mime_version) = $mail =~ /^(MIME-Version: .*)/m;
    my $body = strip_headers($mail);

    $mail = << "MAIL";
Subject: RT mail sent back into RT
From: general\@example.com
To: recipient\@example.com
$mime_version
$content_type

$body
MAIL
 
    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "got id of a newly created ticket - $id");

    my $tick = RT::Model::Ticket->new( $RT::SystemUser );
    $tick->load( $id );
    ok ($tick->id, "loaded ticket #$id");

    is ($tick->Subject,
        "RT mail sent back into RT",
        "Correct subject"
    );

    my $txn = $tick->Transactions->first;
    my ($msg, @attachments) = @{$txn->Attachments->items_array_ref};

    is( $msg->GetHeader('X-RT-Privacy'),
        'PGP',
        "RT's outgoing mail has crypto"
    );
    is( $msg->GetHeader('X-RT-Incoming-Encryption'),
        'Success',
        "RT's outgoing mail looks encrypted"
    );

    like($attachments[0]->Content, qr/Some content/, "RT's mail includes copy of ticket text");
    like($attachments[0]->Content, qr/$RT::rtname/, "RT's mail includes this instance's name");
}

$m->get("$baseurl/Admin/Queues/Modify.html?id=$qid");
$m->form_with_fields('Sign', 'Encrypt');
$m->field(Encrypt => undef);
$m->field(Sign => 1);
$m->submit;

unlink "t/mailbox";

$m->goto_create_ticket( $queue );
$m->form_name('TicketCreate');
$m->field('Subject', 'Signing test');
$m->field('Content', 'Some other content');
ok(!$m->value('Encrypt', 2), "encrypt tick box is unchecked");
ok($m->value('Sign', 2), "sign tick box is checked");
$m->submit;
is($m->status, 200, "request successful");

$m->get($baseurl); # ensure that the mail has been processed

@mail = RT::Test->fetch_caught_mails;
ok(@mail, "got some mail");
for my $mail (@mail) {
    like $mail, qr/Some other content/, "outgoing mail was not encrypted";
    like $mail, qr/-----BEGIN PGP SIGNATURE-----[\s\S]+-----END PGP SIGNATURE-----/, "data has some kind of signature";

    my ($content_type) = $mail =~ /^(Content-Type: .*)/m;
    my ($mime_version) = $mail =~ /^(MIME-Version: .*)/m;
    my $body = strip_headers($mail);

    $mail = << "MAIL";
Subject: More RT mail sent back into RT
From: general\@example.com
To: recipient\@example.com
$mime_version
$content_type

$body
MAIL
 
    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "got id of a newly created ticket - $id");

    my $tick = RT::Model::Ticket->new( $RT::SystemUser );
    $tick->load( $id );
    ok ($tick->id, "loaded ticket #$id");

    is ($tick->Subject,
        "More RT mail sent back into RT",
        "Correct subject"
    );

    my $txn = $tick->Transactions->first;
    my ($msg, @attachments) = @{$txn->Attachments->items_array_ref};

    is( $msg->GetHeader('X-RT-Privacy'),
        'PGP',
        "RT's outgoing mail has crypto"
    );
    is( $msg->GetHeader('X-RT-Incoming-Encryption'),
        'Not encrypted',
        "RT's outgoing mail looks unencrypted"
    );
    is( $msg->GetHeader('X-RT-Incoming-Signature'),
        'general <general@example.com>',
        "RT's outgoing mail looks signed"
    );

    like($attachments[0]->Content, qr/Some other content/, "RT's mail includes copy of ticket text");
    like($attachments[0]->Content, qr/$RT::rtname/, "RT's mail includes this instance's name");
}

$m->get("$baseurl/Admin/Queues/Modify.html?id=$qid");
$m->form_with_fields('Sign', 'Encrypt');
$m->field(Encrypt => 1);
$m->field(Sign => 1);
$m->submit;

unlink "t/mailbox";

$m->goto_create_ticket( $queue );
$m->form_name('TicketCreate');
$m->field('Subject', 'Crypt+Sign test');
$m->field('Content', 'Some final? content');
ok($m->value('Encrypt', 2), "encrypt tick box is checked");
ok($m->value('Sign', 2), "sign tick box is checked");
$m->submit;
is($m->status, 200, "request successful");

$m->get($baseurl); # ensure that the mail has been processed

@mail = RT::Test->fetch_caught_mails;
ok(@mail, "got some mail");
for my $mail (@mail) {
    unlike $mail, qr/Some other content/, "outgoing mail was encrypted";

    my ($content_type) = $mail =~ /^(Content-Type: .*)/m;
    my ($mime_version) = $mail =~ /^(MIME-Version: .*)/m;
    my $body = strip_headers($mail);

    $mail = << "MAIL";
Subject: Final RT mail sent back into RT
From: general\@example.com
To: recipient\@example.com
$mime_version
$content_type

$body
MAIL
 
    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "got id of a newly created ticket - $id");

    my $tick = RT::Model::Ticket->new( $RT::SystemUser );
    $tick->load( $id );
    ok ($tick->id, "loaded ticket #$id");

    is ($tick->Subject,
        "Final RT mail sent back into RT",
        "Correct subject"
    );

    my $txn = $tick->Transactions->first;
    my ($msg, @attachments) = @{$txn->Attachments->items_array_ref};

    is( $msg->GetHeader('X-RT-Privacy'),
        'PGP',
        "RT's outgoing mail has crypto"
    );
    is( $msg->GetHeader('X-RT-Incoming-Encryption'),
        'Success',
        "RT's outgoing mail looks encrypted"
    );
    is( $msg->GetHeader('X-RT-Incoming-Signature'),
        'general <general@example.com>',
        "RT's outgoing mail looks signed"
    );

    like($attachments[0]->Content, qr/Some final\? content/, "RT's mail includes copy of ticket text");
    like($attachments[0]->Content, qr/$RT::rtname/, "RT's mail includes this instance's name");
}

unlink "t/mailbox";

$m->goto_create_ticket( $queue );
$m->form_name('TicketCreate');
$m->field('Subject', 'Test crypt-off on encrypted queue');
$m->field('Content', 'Thought you had me figured out didya');
$m->field(Encrypt => undef, 2); # turn off encryption
ok(!$m->value('Encrypt', 2), "encrypt tick box is now unchecked");
ok($m->value('Sign', 2), "sign tick box is still checked");
$m->submit;
is($m->status, 200, "request successful");

$m->get($baseurl); # ensure that the mail has been processed

@mail = RT::Test->fetch_caught_mails;
ok(@mail, "got some mail");
for my $mail (@mail) {
    like $mail, qr/Thought you had me figured out didya/, "outgoing mail was unencrypted";

    my ($content_type) = $mail =~ /^(Content-Type: .*)/m;
    my ($mime_version) = $mail =~ /^(MIME-Version: .*)/m;
    my $body = strip_headers($mail);

    $mail = << "MAIL";
Subject: Post-final! RT mail sent back into RT
From: general\@example.com
To: recipient\@example.com
$mime_version
$content_type

$body
MAIL
 
    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "got id of a newly created ticket - $id");

    my $tick = RT::Model::Ticket->new( $RT::SystemUser );
    $tick->load( $id );
    ok ($tick->id, "loaded ticket #$id");

    is ($tick->Subject,
        "Post-final! RT mail sent back into RT",
        "Correct subject"
    );

    my $txn = $tick->Transactions->first;
    my ($msg, @attachments) = @{$txn->Attachments->items_array_ref};

    is( $msg->GetHeader('X-RT-Privacy'),
        'PGP',
        "RT's outgoing mail has crypto"
    );
    is( $msg->GetHeader('X-RT-Incoming-Encryption'),
        'Not encrypted',
        "RT's outgoing mail looks unencrypted"
    );
    is( $msg->GetHeader('X-RT-Incoming-Signature'),
        'general <general@example.com>',
        "RT's outgoing mail looks signed"
    );

    like($attachments[0]->Content, qr/Thought you had me figured out didya/, "RT's mail includes copy of ticket text");
    like($attachments[0]->Content, qr/$RT::rtname/, "RT's mail includes this instance's name");
}

sub strip_headers
{
    my $mail = shift;
    $mail =~ s/.*?\n\n//s;
    return $mail;
}

# now test the OwnerNameKey and RequestorsKey fields

my $nokey = RT::Test->load_or_create_user(Name => 'nokey', EmailAddress => 'nokey@example.com');
$nokey->PrincipalObj->GrantRight(Right => 'CreateTicket');
$nokey->PrincipalObj->GrantRight(Right => 'OwnTicket');

my $tick = RT::Model::Ticket->new( $RT::SystemUser );
$tick->create(Subject => 'owner lacks pubkey', Queue => 'general',
              Owner => $nokey);
ok(my $id = $tick->id, 'created ticket for owner-without-pubkey');

$tick = RT::Model::Ticket->new( $RT::SystemUser );
$tick->create(Subject => 'owner has pubkey', Queue => 'general',
              Owner => 'root');
ok($id = $tick->id, 'created ticket for owner-with-pubkey');

my $mail = << "MAIL";
Subject: Nokey requestor
From: nokey\@example.com
To: general\@example.com

hello
MAIL
 
((my $status), $id) = RT::Test->send_via_mailgate($mail);
is ($status >> 8, 0, "The mail gateway exited normally");
ok ($id, "got id of a newly created ticket - $id");

$tick = RT::Model::Ticket->new( $RT::SystemUser );
$tick->load( $id );
ok ($tick->id, "loaded ticket #$id");

is ($tick->Subject,
    "Nokey requestor",
    "Correct subject"
);

# test that the new fields work
$m->get("$baseurl/Search/Simple.html?q=General");
my $content = $m->content;
$content =~ s/&#40;/(/g;
$content =~ s/&#41;/)/g;

like($content, qr/OO-Nobody-O/, "original OwnerName untouched");
like($content, qr/OO-nokey-O/, "original OwnerName untouched");
like($content, qr/OO-root-O/, "original OwnerName untouched");

like($content, qr/OR-recipient\@example.com-O/, "original Requestors untouched");
like($content, qr/OR-nokey\@example.com-O/, "original Requestors untouched");

like($content, qr/KO-root-K/, "KeyOwnerName does not issue no-pubkey warning for recipient");
like($content, qr/KO-nokey \(no pubkey!\)-K/, "KeyOwnerName issues no-pubkey warning for root");
like($content, qr/KO-Nobody \(no pubkey!\)-K/, "KeyOwnerName issues no-pubkey warning for nobody");

like($content, qr/KR-recipient\@example.com-K/, "KeyRequestors does not issue no-pubkey warning for recipient\@example.com");
like($content, qr/KR-general\@example.com-K/, "KeyRequestors does not issue no-pubkey warning for general\@example.com");
like($content, qr/KR-nokey\@example.com \(no pubkey!\)-K/, "KeyRequestors DOES issue no-pubkey warning for nokey\@example.com");

