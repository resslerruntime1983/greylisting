

#############################################################################
#
# File: relaydelay.pl
#
# Description:
#   Sendmail::Milter interface for active blocking of spam using the 
#   Greylisting method.  Also incorporates some additional checks and 
#   methods for better blocking spam.
#
# References:
#   For Greylisting info, see http://www.puremagic.com/~eharris/spam/
#   For SMTP info, see RFC821, RFC1891, RFC1893
#
# Notes:
#
# Bugs:
#
#
# *** Copyright 2003 by Evan J. Harris - All Rights Reserved ***
#
#############################################################################

use ExtUtils::testlib;
use Sendmail::Milter;
use Socket;
use Errno qw(ENOENT);

use DBI;
#use Sys::Hostname;

use strict;

###############################################
# Our global settings file
###############################################
my $config_file = "/etc/mail/relaydelay.conf";


#################################################################
# Our global settings that may be overridden from the config file
#################################################################

# Database connection params
my $database_type = 'mysql';
my $database_name = 'relaydelay';
my $database_host = 'localhost';
my $database_port = 3306;
my $database_user = 'db_user';
my $database_pass = 'db_pass';

# This determines how many seconds we will block inbound mail that is
#   from a previously unknown [ip,from,to] triplet.
my $delay_mail_secs = 3600;  # One hour

# This determines how many seconds of life are given to a record that is
#   created from a new mail [ip,from,to] triplet.  Note that the window
#   created by this setting for passing mails is reduced by the amount
#   set for $delay_mail_secs.
# NOTE: See Also: update_record_life and update_record_life_secs.
my $auto_record_life_secs = 4 * 3600;  # 4 hours

# True if we should update the life of a record when passing a mail
#   This should generally be enabled, unless the normal lifetime
#   defined by $auto_record_life_secs is already a large value.
my $update_record_life = 1;

# How much life (in secs) to give to a record we are updating from an
#   allowed (passed) email.  Only useful if update_record_life is
#   enabled.
# The default is 36 days, which should be enough to handle messages that
#   may only be sent once a month, or on things like the first Monday
#   of the month (which sometimes means 5 weeks).  Plus, we add a day
#   for a delivery buffer.
my $update_record_life_secs = 36 * 24 * 3600;

# If you have very large amounts of traffic and want to reduce the number of 
#   queries the db has to handle (and don't need these features), then these
#   wildcard checks can be disabled.  Just set them to 0 if so.
# If both are enabled, relay_ip is considered to take precedence, and is 
#   checked first.  A match there will ignore the rcpt checks.
my $check_wildcard_relay_ip = 1;
my $check_wildcard_rcpt_to = 1;

# Set this to a nonzero value if you want to wait until after the DATA
#   phase before issuing the TEMPFAIL for delayed messages.  If this
#   is undefined or zero, then messages will be failed after the RCPT
#   phase in the smtp session.  Setting this will cause more traffic,
#   which should be unneccessary, but increases the fault tolerance for
#   some braindead mailers that don't check the status codes except at
#   the end of a message transaction.  It does expose a couple of 
#   liabilities, in that the blocking will only occur if the LAST recipient
#   in a multi-recipient message is currently blocked.  If the last
#   recipient is not blocked, the message will go through, even if some
#   recipients are supposed to be blocked.  Generally discouraged.
my $tempfail_messages_after_data_phase = 0;

# Set this to a nonzero value if you wish to do triplet lookups disregarding
#   the last octet of the relay ip.  This helps workaround the case of
#   more than one delivering MTA being used to deliver a particular email.
#   Practically all setups that are that way have the pool of delivering
#   MTA's on the same /24 subnet, so that's what we use.
my $do_relay_lookup_by_subnet = 0;

# Set this to 0 if you wish to disable the automatic maintenance of the
#   relay_ip -> relay_name reference table.  Could save an insert 
#   and an update, depending on circumstances.
my $enable_relay_name_updates = 1;

# Enable this to do some rudimentary syntax checking on the passed mail_from
#   address.  This may exclude some valid addresses, so we leave it as an
#   option that can be disabled.
my $check_envelope_address_format = 1;

# Set this to a postive number to slow down responses to blocked connections
#   by a random number of seconds up to this value (a simple way to tarpit
#   probable spammers connections)
# NOTE: The sendmail settings for this milter must be long enough so this 
#   delay plus the normal processing time doesn't cause a timeout)
# FIXME - NOT YET IMPLEMENTED
my $blocked_response_delay_secs = 30;

# Set this to true if you wish to disable checking and just pass
#   mail when the db connection fails.  Otherwise, we will reject
#   all the mail with a tempfail if we are unable to check the 
#   status for it in the db.
# If you are pretty good about keeping your system well maintained, then it is
#   recommended to leave this disabled.  But if it's possible that the db may go
#   down without anyone noticing for a significant amount of time, then this
#   should probably be enabled.
my $pass_mail_when_db_unavail = 0;

#############################################################
# End of options for use in external config file
#############################################################


# Global vars that should not be in the external config file
my $global_dbh;
my $config_loaded;
my $verbose = 1;



# Possible dynamic blocking at firewall level
#iptables -A dynamic_smtp_blocks -s $relay_ip -j DROP
# And empty the list
#iptables -F dynamic_smtp_blocks

#######################################################################
# Database functions
#######################################################################

sub db_connect($) {
  my $verbose = shift;

  return $global_dbh if (defined $global_dbh);
  #my $driver = 'mysql';
  #my $database = '';
  #my $host = '127.0.0.1';
  #my $host = 'localhost';
  #my $user = '';
  #my $password = '';

  my $dsn = "DBI:$database_type:database=$database_name:host=$database_host:port=$database_port";
  print "DBI Connecting to $dsn\n" if $verbose;

  # Note: We do all manual error checking for db errors
  my $dbh = DBI->connect($dsn, $database_user, $database_pass, 
                         { PrintError => 0, RaiseError => 0 });

  #print "DBI Connect Completed.\n";
  $global_dbh = $dbh;
  return $global_dbh;
}

sub db_disconnect {
  $global_dbh->disconnect() if (defined $global_dbh);
  $global_dbh = undef;
  return 0;
}

#sub DoSingleValueQuery($)
#{ 
#  my $query = shift;
#
#  my $dbh = db_connect(0);
#  die "$DBI::errstr\n" unless($dbh);
#  # execute the query and retrieve the first row, first value 
#  #   NOTE: there is no way to distinquish the row not existing from
#  #     the value of the first item in the results being NULL.
#  #     Use with caution.
#  my $value = $dbh->selectrow_array($query);
#  # return it
#  return $value;
#}
#
#sub DoSingleRowQuery($)
#{
#  my $query = shift;
#
#  my $dbh = db_connect(0);
#  die "$DBI::errstr\n" unless($dbh);
#  # execute the query and retrieve the first row
#  my @arr = $dbh->selectrow_array($query);
#  return @arr;
#}
#
#sub DoStatement($)
#{
#  my $query = shift;
#
#  my $dbh = db_connect(0);
#  die "$DBI::errstr\n" unless($dbh);
#  my $rows_affected = $dbh->do($query);
#  return $rows_affected;
#}

#############################################################################
#
# Milter Callback Functions:
#
#  Each of these callbacks is actually called with a first argument
#  that is blessed into the pseudo-package Sendmail::Milter::Context. You can
#  use them like object methods of package Sendmail::Milter::Context.
#
#  $ctx is a blessed reference of package Sendmail::Milter::Context to something
#  yucky, but the Mail Filter API routines are available as object methods
#  (sans the smfi_ prefix) from this
#############################################################################

# I wasn't going to originally have a envfrom callback, but since the envelope
# sender doesn't seem to be available through other methods, I use this to
# save it so we can get it later.  We also make sure the config file is loaded.

sub envfrom_callback
{
  my $ctx = shift;
  my @args = @_;

  # Make sure we have the config information
  load_config();

  if ($check_envelope_address_format) {
    # Check the envelope sender address, and make sure is well-formed.
    #   If is invalid, then issue a permanent failure telling why.
    # NOTE: Some of these tests may exclude valid addresses, but I've only seen spammers
    #   use the ones specifically disallowed here, and they sure don't look valid.  But,
    #   since the SMTP specs do not strictly define what is allowed in an address, I
    #   had to guess by what "looked" normal, or possible.
    my $tstr = $args[0];
    if ($tstr =~ /\A<(.*)>\Z/) {  # Remove outer angle brackets
      $tstr = $1;
      # Note: angle brackets are not required, as some legitimate things seem to not use them
    }
    # Check for embedded whitespace
    if ($tstr =~ /[\s]/) {
      $ctx->setreply("501", "5.1.7", "Malformed envelope from address: contains whitespace");
      return SMFIS_REJECT;
    }
    # Check for embedded brackets, parens, quotes, slashes, pipes
    if ($tstr =~ /[<>\[\]\{\}\(\)'"`\/\\\|]/) {
      $ctx->setreply("501", "5.1.7", "Malformed envelope from address: invalid punctuation characters");
      return SMFIS_REJECT;
    }
    # Any chars outside of the range of 33 to 126 decimal (we check as every char being within that range)
    #   Note that we do not require any chars to be in the string, this allows the null sender
    if ($tstr !~ /\A[!-~]*\Z/) {
      $ctx->setreply("501", "5.1.7", "Malformed envelope from address: contains invalid characters");
      return SMFIS_REJECT;
    }
    # FIXME there may be others, but can't find docs on what characters are permitted in an address

    # Now validate parts of sender address (but only if it's not the null sender)
    if ($tstr ne "") {
      my ($from_acct, $from_domain) = split("@", $tstr, 2);
      if ($from_acct eq "") {
        $ctx->setreply("501", "5.1.7", "Malformed envelope from address: user part empty");
        return SMFIS_REJECT;
      }
      if ($from_domain eq "") {
        $ctx->setreply("501", "5.1.7", "Malformed envelope from address: domain part empty");
        return SMFIS_REJECT;
      }
      if ($from_domain =~ /@/) {
        $ctx->setreply("501", "5.1.7", "Malformed envelope from address: too many at signs");
        return SMFIS_REJECT;
      }
      # make sure the domain part is well-formed, and contains at least 2 parts
      if ($from_domain !~ /\A[\w\-]+\.([\w\-]+\.)*[0-9a-zA-Z]+\Z/) {
        $ctx->setreply("501", "5.1.7", "Malformed envelope from address: domain part invalid");
        return SMFIS_REJECT;
      }
    }
  }

  # Save our private data (since it isn't available in the same form later)
  #   The format is a comma seperated list of rowids (or zero if none),
  #     followed by the envelope sender followed by the current envelope
  #     recipient (or empty string if none) seperated by nulls
  #   I would have really rather used a hash or other data structure, 
  #     but when I tried it, Sendmail::Milter seemed to choke on it
  #     and would eventually segfault.  So went back to using a scalar.
  my $privdata = "0\x00$args[0]\x00";
  $ctx->setpriv(\$privdata);

  return SMFIS_CONTINUE;
}


# The eom callback is called after a message has been successfully passed.
# It is also the only callback where we can change the headers or body.
# NOTE: It is only called once for a message, even if that message
#   had multiple recipients.  We have to handle updating the row for each
#   recipient here, and it takes a bit of trickery.
# NOTE: We will always get either an abort or an eom callback for any
#   particular message, but never both.

sub eom_callback
{
  my $ctx = shift;

  # Get our status and check to see if we need to do anything else
  my $privdata_ref = $ctx->getpriv();
  # Clear our private data on this context
  $ctx->setpriv(undef);

  print "  IN EOM CALLBACK - PrivData: " . ${$privdata_ref} . "\n" if ($verbose);

  my $dbh = db_connect(0) or goto DB_FAILURE;

  # parse and store the data
  my $rowids;
  my $mail_from;
  my $rcpt_to;

  # save the useful data
  if (${$privdata_ref} =~ /\A([\d,]+)\x00(.*)\x00(.*)\Z/) {
    $rowids = $1;
    $mail_from = $2;
    $rcpt_to = $3;
  }
  
  # If and only if this message is from the null sender, check to see if we should tempfail it
  #   (since we can't delay it after rcpt_to since that breaks exim's recipient callbacks)
  #   (We use a special rowid value of 00 to indicate a needed block)
  if ($rowids eq "00" and ($mail_from eq "<>" or $tempfail_messages_after_data_phase)) {
    # Set the reply code to the normal default, but with a modified text part.
    #   I added the (TEMPFAIL) so it is easy to tell in the syslogs if the failure was due to
    #     the processing of the milter, or if it was due to other causes within sendmail
    #     or from the milter being inaccessible/timing out.
    $ctx->setreply("451", "4.7.1", "Please try again later (TEMPFAIL)");
    
    # Issue a temporary failure for this message.  Connection may or may not continue
    #   with delivering other mails.
    return SMFIS_TEMPFAIL;
  }

  # Only if we have some rowids, do we update the count of passed messages
  if ($rowids > 0) {
    # split up the rowids and update each in turn
    my @rowids = split(",", $rowids);
    foreach my $rowid (@rowids) {
      $dbh->do("UPDATE relaytofrom SET passed_count = passed_count + 1 WHERE id = $rowid") or goto DB_FAILURE;
      print "  * Mail successfully processed.  Incremented passed count on rowid $rowid.\n" if ($verbose);

      # If configured to do so, then update the lifetime (only on AUTO records)
      if ($update_record_life) {
        # This is done here rather than the rcpt callback since we don't know until now that
        #   the delivery is completely successful (not spam blocked or nonexistant user, or 
        #   other failure out of our control)
        $dbh->do("UPDATE relaytofrom SET record_expires = NOW() + INTERVAL $update_record_life_secs SECOND "
          . " WHERE id = $rowid AND origin_type = 'AUTO'") or goto DB_FAILURE;
      }
    }
  }

  # Add a header to the message (if desired)
  #if (not $ctx->addheader("X-RelayDelay", "By kinison")) { print "  * Error adding header!\n"; }

  # And we handled everything successfully, so continue
  return SMFIS_CONTINUE;

  DB_FAILURE:
  # Had a DB error.  Handle as configured.
  print "ERROR: Database Call Failed!\n  $DBI::errstr\n";
  db_disconnect();  # Disconnect, so will get a new connect next mail attempt
  return SMFIS_CONTINUE if ($pass_mail_when_db_unavail);
  return SMFIS_TEMPFAIL;
}


# The abort callback is called even if the message is rejected, even if we
#   are the one that rejected it.  So we ignore it unless we were passing
#   the message and need to increment the aborted count to know something
#   other than this milter caused it to fail.
# However, there is an additional gotcha.  The abort callback may be called
#   before we have a RCPT TO.  In that case, we also ignore it, since we
#   haven't yet done anything in the database regarding the message.
# NOTE: It is only called once for a message, even if that message
#   had multiple recipients.  We have to handle updating the row for each
#   recipient here, and it takes a bit of trickery.
sub abort_callback
{
  my $ctx = shift;

  # Get our status and check to see if we need to do anything else
  my $privdata_ref = $ctx->getpriv();
  # Clear our private data on this context
  $ctx->setpriv(undef);

  print "  IN ABORT CALLBACK - PrivData: " . ${$privdata_ref} . "\n" if ($verbose);

  # parse and store the data
  my $rowids;
  my $mail_from;
  my $rcpt_to;

  # save the useful data
  if (${$privdata_ref} =~ /\A([\d,]+)\x00(.*)\x00(.*)\Z/) {
    $rowids = $1;
    $mail_from = $2;
    $rcpt_to = $3;
  }
  
  # only increment the aborted_count if have some rowids 
  #   (this means we didn't expect/cause an abort, but something else did)
  if ($rowids > 0) {
    # Ok, we need to update the db, so get a handle
    my $dbh = db_connect(0) or goto DB_FAILURE;
  
    # split up the rowids and update each in turn
    my @rowids = split(",", $rowids);
    foreach my $rowid (@rowids) {
      $dbh->do("UPDATE relaytofrom SET aborted_count = aborted_count + 1 WHERE id = $rowid") or goto DB_FAILURE;
      print "  * Mail was aborted.  Incrementing aborted count on rowid $rowid.\n" if ($verbose);

      # Check for the special case of no passed messages, means this is probably a 
      #   spammer, and we should expire the record so they have to go through the
      #   whitelisting process again the next time they try.  BUT ONLY IF THIS
      #   IS AN AUTO RECORD.
      # If we find that it is such a record, update the expire time to now
      my $rows = $dbh->do("UPDATE relaytofrom SET record_expires = NOW() "
        . " WHERE id = $rowid AND origin_type = 'AUTO' AND passed_count = 0") or goto DB_FAILURE;
      if ($rows > 0) {
        print "  * Mail record had no successful deliveries.  Expired record on rowid $rowid.\n" if ($verbose);
      }
    }
  }

  return SMFIS_CONTINUE;

  DB_FAILURE:
  # Had a DB error.  Handle as configured.
  print "ERROR: Database Call Failed!\n  $DBI::errstr\n";
  db_disconnect();  # Disconnect, so will get a new connect next mail attempt
  return SMFIS_CONTINUE if ($pass_mail_when_db_unavail);
  return SMFIS_TEMPFAIL;
}


# Here we perform the bulk of the work, since here we have individual recipient
#   information, and can act on it.

sub envrcpt_callback
{
  my $ctx = shift;
  my @args = @_;

  # Get the time in seconds
  my $timestamp = time();

  # Get the hostname (needs a module that is not necessarily installed)
  #   Not used (since I don't want to depend on it)
  #my $hostname = hostname();

  print "\n" if ($verbose);

  # declare our info vars
  my $rowid;
  my $rowids;
  my $mail_from;

  # Get the stored envelope sender and rowids
  my $privdata_ref = $ctx->getpriv();
  my $rcpt_to = $args[0];

  # save the useful data
  if (${$privdata_ref} =~ /\A([\d,]+)\x00(.*)\x00(.*)\Z/) {
    $rowids = $1;
    $mail_from = $2;
  }
  if (! defined $rowids) {
    print "ERROR: Invalid privdata in envrcpt callback!\n";
  }
  
  print "Stored Sender: $mail_from\n" if ($verbose);
  print "Passed Recipient: $rcpt_to\n" if ($verbose);

  # Get the database handle (after got the privdata)
  my $dbh = db_connect(0) or goto DB_FAILURE;
  
  #print "my_envrcpt:\n";
  #print "   + args: '" . join(', ', @args) . "'\n";
  # other useful, but unneeded values
  #my $tmp = $ctx->getsymval("{j}");  print "localservername = $tmp\n";
  #my $tmp = $ctx->getsymval("{i}");  print "queueid = $tmp\n";
  #my $from_domain = $ctx->getsymval("{mail_host}");  print "from_domain = $tmp\n";
  #my $tmp = $ctx->getsymval("{rcpt_host}");  print "to_domain = $tmp\n";
  
  # Get the remote hostname and ip in the form "[ident@][hostname] [ip]"
  my $tmp = $ctx->getsymval("{_}");  
  my ($relay_ip, $relay_name, $relay_ident, $relay_maybe_forged);
  if ($tmp =~ /\A(\S*@|)(\S*) ?\[(.*)\]( \(may be forged\)|)\Z/) {
    $relay_ident = $1;
    $relay_name = $2;
    $relay_ip = $3;
    $relay_maybe_forged = (length($4) > 0 ? 1 : 0);
  }
  my $relay_name_reversed = reverse($relay_name);
  print "  Relay: $tmp\n" if ($verbose);
  print "  RelayIP: $relay_ip - RelayName: $relay_name - RelayIdent: $relay_ident - PossiblyForged: $relay_maybe_forged\n" if ($verbose);
        
  # Collect the rest of the info for our checks
  my $mail_mailer = $ctx->getsymval("{mail_mailer}");
  my $sender      = $ctx->getsymval("{mail_addr}");
  my $rcpt_mailer = $ctx->getsymval("{rcpt_mailer}");
  my $recipient   = $ctx->getsymval("{rcpt_addr}");
  my $queue_id    = $ctx->getsymval("{i}");

  print "  From: $sender - To: $recipient\n" if ($verbose);
  print "  InMailer: $mail_mailer - OutMailer: $rcpt_mailer - QueueID: $queue_id\n" if ($verbose);

  # Only do our processing if the inbound mailer is an smtp variant.
  #   A lot of spam is sent with the null sender address <>.  Sendmail reports 
  #   that as being from the local mailer, so we have a special case that needs
  #   handling (but only if not also from localhost).
  if (! ($mail_mailer =~ /smtp\Z/i) && ($mail_from ne "<>" || $relay_ip eq "127.0.0.1")) {
    # we aren't using an smtp-like mailer, so bypass checks
    print "  Mail delivery is not using an smtp-like mailer.  Skipping checks.\n" if ($verbose);
    goto PASS_MAIL;
  }

  if ($check_envelope_address_format) {
    # Check the mail recipient, and make sure is well-formed.  Bounce mail telling why if not.
    my $tstr = $rcpt_to;
    if ($tstr =~ /\A<(.*)>\Z/) {  # Remove outer angle brackets if present
      $tstr = $1;
    }
    #goto BOUNCE_MAIL;
  }
        
  # Check for local IP relay whitelisting from the access file
  # FIXME - needs to be implemented
  #

  # Check wildcard black or whitelisting based on ip address or subnet
  #   Do the check in such a way that more exact matches are returned first
  if ($check_wildcard_relay_ip) {
    my $net24 = $relay_ip;  
    $net24 =~ s/\A(.*)\.\d+\Z/$1/;  # strip off the last octet
    my $net16 = $net24;  
    $net16 =~ s/\A(.*)\.\d+\Z/$1/;
    my $net8  = $net16;
    $net8  =~ s/\A(.*)\.\d+\Z/$1/;
    my $query = "SELECT id, block_expires > NOW(), block_expires < NOW() FROM relaytofrom "
      .         "  WHERE record_expires > NOW() "
      .         "    AND mail_from IS NULL "
      .         "    AND rcpt_to   IS NULL "
      .         "    AND (relay_ip = '$relay_ip' "
      .         "      OR relay_ip = '$net24' "
      .         "      OR relay_ip = '$net16' "
      .         "      OR relay_ip = '$net8') "
      .         "  ORDER BY length(relay_ip) DESC";

    my $sth = $dbh->prepare($query) or goto DB_FAILURE;
    $sth->execute() or goto DB_FAILURE;
    ($rowid, my $blacklisted, my $whitelisted) = $sth->fetchrow_array();
    goto DB_FAILURE if ($sth->err);
    $sth->finish();

    if ($rowid > 0) {
      if ($blacklisted) {
        print "  Blacklisted Relay.  Skipping checks and rejecting the mail.\n" if ($verbose);
        goto DELAY_MAIL;
      }
      if ($whitelisted) {
        print "  Whitelisted Relay.  Skipping checks and passing the mail.\n" if ($verbose);
        goto PASS_MAIL;
      }
    }
  }

  # See if this recipient (or domain/subdomain) is wildcard white/blacklisted
  # NOTE: we only check partial domain matches up to 4 levels deep
  # FIXME - domain part not yet implemented
  if ($check_wildcard_rcpt_to) {
    my $query = "SELECT id, block_expires > NOW(), block_expires < NOW() FROM relaytofrom "
      .         "  WHERE record_expires > NOW() "
      .         "    AND relay_ip  IS NULL "
      .         "    AND mail_from IS NULL "
      .         "    AND rcpt_to   = " . $dbh->quote($rcpt_to);
      
    my $sth = $dbh->prepare($query) or goto DB_FAILURE;
    $sth->execute() or goto DB_FAILURE;
    ($rowid, my $blacklisted, my $whitelisted) = $sth->fetchrow_array();
    goto DB_FAILURE if ($sth->err);
    $sth->finish();

    if ($rowid > 0) {
      if ($blacklisted) {
        print "  Blacklisted Recipient.  Skipping checks and rejecting the mail.\n" if ($verbose);
        goto DELAY_MAIL;
      }
      if ($whitelisted) {
        print "  Whitelisted Recipient.  Skipping checks and passing the mail.\n" if ($verbose);
        goto PASS_MAIL;
      }
    }
  }

  # Store and maintain the dns_name of the relay if we have one
  #   Not strictly necessary, but useful for reporting/troubleshooting
  if ($enable_relay_name_updates and length($relay_name_reversed) > 0) {
    my $rows = $dbh->do("INSERT IGNORE INTO dns_name (relay_ip,relay_name) VALUES ('$relay_ip'," 
      . $dbh->quote($relay_name_reversed) . ")");
    goto DB_FAILURE if (!defined($rows));
    if ($rows != 1) {
      # Row already exists, so make sure the name is updated
      my $rows = $dbh->do("UPDATE dns_name SET relay_name = " . $dbh->quote($relay_name_reversed)
        . " WHERE relay_ip = '$relay_ip'");
      goto DB_FAILURE if (!defined($rows));
    }
  }

  # Check to see if we already know this triplet set, and if the initial block is expired
  my $query = "SELECT id, NOW() > block_expires FROM relaytofrom "
    .         "  WHERE record_expires > NOW() "
    .         "    AND mail_from = " . $dbh->quote($mail_from)
    .         "    AND rcpt_to   = " . $dbh->quote($rcpt_to);
  if ($do_relay_lookup_by_subnet) {
    # Remove the last octet for a /24 subnet, and add the .% for use in a like clause
    my $tstr = $relay_ip;
    $tstr =~ s/\A(.*)\.\d+\Z/$1.%/;
    $query .= "    AND relay_ip LIKE " . $dbh->quote($tstr);
  }
  else {
    # Otherwise, use the relay_ip as an exact match
    $query .= "    AND relay_ip  = " . $dbh->quote($relay_ip);
  }

  my $sth = $dbh->prepare($query) or goto DB_FAILURE;
  $sth->execute() or goto DB_FAILURE;
  ($rowid, my $block_expired) = $sth->fetchrow_array();
  goto DB_FAILURE if ($sth->err);
  $sth->finish();

  if ($rowid > 0) {
    if ($block_expired) {
      print "  Email is known and block has expired.  Passing the mail.  rowid: $rowid\n" if ($verbose);
      goto PASS_MAIL;
    }
    else {
      # the email is known, but the block has not expired.  So return a tempfail.
      print "  Email is known but block has not expired.  Issuing a tempfail.  rowid: $rowid\n" if ($verbose);
      goto DELAY_MAIL;
    }
  }
  else {
    # This is a new and unknown triplet, so create a tracking record, but make sure we don't create duplicates
    # FIXME - We use table locking to ensure non-duplicate rows.  Since we can't do it with a unique multi-field key 
    #   on the triplet fields (the key would be too large), it's either this or normalizing the data to have seperate 
    #   tables for each triplet field.  While that would be a good optimization, it would make this too complex for 
    #   an example implementation.
    $dbh->do("LOCK TABLE relaytofrom WRITE") or goto DB_FAILURE;

    # we haven't reset $query, so we can reuse it (since it is almost exactly the same), don't even need to re-prepare it
    $sth->execute() or goto DB_FAILURE;
    ($rowid, my $block_expired) = $sth->fetchrow_array();
    goto DB_FAILURE if ($sth->err);
    $sth->finish();

    if ($rowid > 0) {
      # A record already exists, which is unexpected at this point.  unlock tables and give a temp failure
      $dbh->do("UNLOCK TABLE") or goto DB_FAILURE;
      print "  Error: Row already exists while attempting to insert.  Issuing a tempfail.\n" if ($verbose);
      goto DELAY_MAIL;
    }

    my $sth = $dbh->prepare("INSERT INTO relaytofrom "
      . "        (relay_ip,mail_from,rcpt_to,block_expires,record_expires,origin_type,create_time) "
      . " VALUES (?,?,?,NOW() + INTERVAL $delay_mail_secs SECOND,NOW() + INTERVAL $auto_record_life_secs SECOND, "
      . "   'AUTO', NOW())") or goto DB_FAILURE;
    $sth->execute($relay_ip, $mail_from, $rcpt_to) or goto DB_FAILURE;
    $sth->finish;

    # Get the rowid of the row we just inserted (used later for updating)
    $rowid = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
    
    # And release the table lock
    $dbh->do("UNLOCK TABLE") or goto DB_FAILURE;

    print "  New mail row successfully inserted.  Issuing a tempfail.  rowid: $rowid\n" if ($verbose);
    # and now jump to normal blocking actions
    goto DELAY_MAIL;
  }


  DELAY_MAIL:
  # Increment the blocked count (if rowid is defined)
  if (defined $rowid) {
    $dbh->do("UPDATE relaytofrom SET blocked_count = blocked_count + 1 WHERE id = $rowid") or goto DB_FAILURE;
  }

  # FIXME - And do mail logging
  
  # Special handling for null sender.  Spammers use it a ton, but so do things like exim's callback sender
  #   verification spam checks.  If the sender is the null sender, we don't want to block it now, but will
  #   instead block it at the eom phase.
  if ($mail_from eq "<>" or $tempfail_messages_after_data_phase) {
    print "  Delaying tempfail reject until eom phase.\n" if ($verbose);
  
    # save that this message needs to be blocked later in the transaction (after eom)
    my $privdata = "00\x00$mail_from\x00$rcpt_to";
    # Save the changes to our privdata for the next callback
    $ctx->setpriv(\$privdata);
    
    # and let the message continue processing, since will be blocked at eom if it isn't aborted before that
    return SMFIS_CONTINUE;
  }
  
  # Save our privdata for the next callback (don't add this rowid, since have already handled it)
  $ctx->setpriv($privdata_ref);

  # Set the reply code to a unique message (for debugging) - this dsn is what is normally the default
  $ctx->setreply("451", "4.7.1", "Please try again later (TEMPFAIL)");
  # Instead, we use a better code, 450 and 4.3.2 per RFC 821 and 1893, saying the system 
  #   isn't currently accepting network messages
  # Disabled again.  For some reason, this causes aol to retry deliveries over and over with no delay.
  #   So much for giving a more informative x.x.x code.
  #$ctx->setreply("450", "4.3.2", "Please try again later (TEMPFAIL)");
 
  # Issue a temporary failure for this message.  Connection may or may not continue.
  return SMFIS_TEMPFAIL;


  BOUNCE_MAIL:
  # set privdata so later callbacks won't have problems
  my $privdata = "0";
  $ctx->setpriv(\$privdata);
  # Indicate the message should be aborted (want a custom error code?)
  return SMFIS_REJECT;


  PASS_MAIL:
  # Do database bookkeeping (if rowid is defined)
  if (defined $rowid) {
    # We don't increment the passed count here because the mail may still be rejected
    #   for some reason at the sendmail level.  So we do it in the eom callback instead.

    # Here we do a special update to end the life of this record, if the sender is the null sender
    #   (Spammers send from this a lot, and it should only be used for bounces.  This
    #   Makes sure that only one (or a couple, small race) of these gets by per delay.
    if ($mail_from eq "<>") {
      # Only update the lifetime of records if they are AUTO, wouldn't want to do wildcard records
      $dbh->do("UPDATE relaytofrom SET record_expires = NOW() WHERE id = $rowid AND origin_type = 'AUTO'") or goto DB_FAILURE;
      #print "  Mail is from NULL sender.  Updated it to end its life.\n" if ($verbose);
    }

    # Since we have a rowid, then set the context data to indicate we successfully 
    #   handled this message as a pass, and that we don't expect an abort without 
    #   needing further processing.  We have to keep the rcpt_to on there, since this 
    #   callback may be called several times for a specific message if it has multiple 
    #   recipients, and we need it for logging.
    # The format of the privdata is one or more rowids seperated by commas, followed by 
    #   a null, and the envelope from.
    if ($rowids > 0) {
      $rowids .= ",$rowid";
    }
    else {
      $rowids = $rowid;
    }
  }
  # Save our privdata for the next callback
  my $privdata = "$rowids\x00$mail_from\x00$rcpt_to";
  $ctx->setpriv(\$privdata);

  # FIXME - Need to do mail logging?
 
  # And indicate the message should continue processing.
  return SMFIS_CONTINUE;


  DB_FAILURE:
  # Had a DB error.  Handle as configured.
  print "ERROR: Database Call Failed!\n  $DBI::errstr\n";
  db_disconnect();  # Disconnect, so will get a new connect next mail attempt
  # set privdata so later callbacks won't have problems (or if db comes back while still in this mail session)
  my $privdata = "0\x00$mail_from\x00";
  $ctx->setpriv(\$privdata);
  return SMFIS_CONTINUE if ($pass_mail_when_db_unavail);
  return SMFIS_TEMPFAIL;
}


sub load_config() {

  # make sure the config is only loaded once per instance
  return if ($config_loaded);

  print "Loading Config File: $config_file\n";

  # Read and setup our configuration parameters from the config file
  my($msg);
  my($errn) = stat($config_file) ? 0 : 0+$!;
  if ($errn == ENOENT) { $msg = "does not exist" }
  elsif ($errn)        { $msg = "inaccessible: $!" }
  elsif (! -f _)       { $msg = "not a regular file" }
  elsif (! -r _)       { $msg = "not readable" }
  if (defined $msg) { die "Config file $config_file $msg" }
  eval `cat $config_file`;
  #do $config_file;
  if ($@ ne '') { die "Error in config file $config_file: $@" }

  $config_loaded = 1;
}




my %my_callbacks =
(
#	'connect' =>	\&connect_callback,
#	'helo' =>	\&helo_callback,
	'envfrom' =>	\&envfrom_callback,
	'envrcpt' =>	\&envrcpt_callback,
#	'header' =>	\&header_callback,
#	'eoh' =>	\&eoh_callback,
#	'body' =>	\&body_callback,
	'eom' =>	\&eom_callback,
	'abort' =>	\&abort_callback,
#	'close' =>	\&close_callback,
);

BEGIN:
{
  if (scalar(@ARGV) < 2) {
    print "Usage: perl $0 <name_of_filter> <path_to_sendmail.cf>\n";
    exit;
  }

  my $conn = Sendmail::Milter::auto_getconn($ARGV[0], $ARGV[1]);

  print "Found connection info for '$ARGV[0]': $conn\n";

  if ($conn =~ /^local:(.+)$/) {
    my $unix_socket = $1;

    if (-e $unix_socket) {
      print "Attempting to unlink UNIX socket '$conn' ... ";

      if (unlink($unix_socket) == 0) {
        print "failed.\n";
        exit;
      }
      print "successful.\n";
    }
  }

  if (not Sendmail::Milter::auto_setconn($ARGV[0], $ARGV[1])) {
    print "Failed to detect connection information.\n";
    exit;
  }

  # Make sure there are no errors in the config file before we start
  load_config();

  # Make sure we can connect to the database 
  my $dbh = db_connect(1);
  die "$DBI::errstr\n" unless($dbh);
  # and disconnect again, since the callbacks won't have access to the handle
  db_disconnect();

  #
  #  The flags parameter is optional. SMFI_CURR_ACTS sets all of the
  #  current version's filtering capabilities.
  #

  if (not Sendmail::Milter::register($ARGV[0], \%my_callbacks, SMFI_CURR_ACTS)) {
    print "Failed to register callbacks for $ARGV[0].\n";
    exit;
  }

  print "Starting Sendmail::Milter $Sendmail::Milter::VERSION engine.\n";

  # Parameters to main are max num of interpreters, num requests to service before recycling threads
  #if (Sendmail::Milter::main(10, 30)) {
  if (Sendmail::Milter::main()) {
    print "Successful exit from the Sendmail::Milter engine.\n";
  }
  else {
    print "Unsuccessful exit from the Sendmail::Milter engine.\n";
  }
}


# Make sure when threads are recycled that we release the global db connection
END {
  print "Closing DB connection.\n";
  db_disconnect();
}


