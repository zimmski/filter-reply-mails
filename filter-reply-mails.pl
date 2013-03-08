#!/usr/bin/perl

our $VERSION = 1.0;

use Modern::Perl;

use File::Slurp;
use Getopt::Compact;
use IO::File;
use Mail::IMAPClient;
use MIME::Parser;
use String::Util qw/trim/;
use Try::Tiny;

sub options_validate {
	my ($opts) = @_;
	
	for my $i(qw/filter-html filter-text mail-server mail-user mail-pwd folder-tmp folder-dst/) {
		if (not $opts->{$i}) {
			say_error("argument '$i' is needed.");

			return;
		}
	}
	
	for my $i(qw/folder-tmp folder-dst/) {
		if (not -d $opts->{$i} or not -w $opts->{$i}) {
			say_error("folder '" . $opts->{$i} . "' is not writable");
			
			return;
		}
	}
	
	for my $i(qw/filter-html filter-text/) {
		if (not -f $opts->{$i} or not -r $opts->{$i}) {
			say_error("regexes file '" . $opts->{$i} . "' is not readable");
			
			return;
		}
	}
	
	return 1;
}

sub say_error {
	my ($text) = @_;

	say "\x1B[0;31mERROR: $text\x1b[0m\n";
}

my $options = Getopt::Compact->new(
	name => 'Script to filter the text and html parts of mails fetched from an IMAP folder based on given regexes',
	struct => [
		[ 'filter-html', 'Regexes for html parts', '=s' ],
		[ 'filter-text', 'Regexes for text parts', '=s' ],
		[ 'folder-tmp', 'Temporary mail folder', '=s' ],
		[ 'folder-dst', 'Destination mail folder', '=s' ],
		[ 'in-memory', 'Do the MIME work in memory (default is off)' ],
		[ 'mail-do-not-connect', 'Do not open an IMAP connection' ],
		[ 'mail-do-not-delete-mail', 'Do not delete mails after fetching them' ],
		[ 'mail-folder', 'Folder from where mails will be fetched (default is INBOX)', ':s' ],
		[ 'mail-pwd', 'Password of the IMAP user', '=s' ],
		[ 'mail-server', 'Server connection string for the IMAP connection (default port is 993)', '=s' ],
		[ 'mail-ssl', 'Use SSL for the IMAP connection (default is off)' ],
		[ 'mail-tls', 'Use TLS for the IMAP connection (default is off)' ],
		[ 'mail-user', 'User for the IMAP connection', '=s' ],
		[ 'verbose', 'Print what is going on' ],
	]
);

my $opts = $options->opts();

if (not $options->status() or not options_validate($opts)) {
	print $options->usage();

	exit 1;
}

if ($opts->{'folder-tmp'} !~ m/\/$/) {
	$opts->{'folder-tmp'} .= '/';
}
if ($opts->{'folder-dst'} !~ m/\/$/) {
	$opts->{'folder-dst'} .= '/';
}

my $verbose = $opts->{verbose};

if (not $opts->{'mail-do-not-connect'}) {
	if ($opts->{'mail-server'} !~ m/:\d+$/) {
		$opts->{'mail-server'} .= ':993';
	}

	my %imap_arguments = (
		Server => $opts->{'mail-server'},
		User => $opts->{'mail-user'},
		Password => $opts->{'mail-pwd'},
	);

	if ($opts->{'mail-ssl'}) {
		$imap_arguments{Ssl} = 1;
	}
	if ($opts->{'mail-tls'}) {
		$imap_arguments{Starttls} = 1;
	}

	if ($verbose) {
		say sprintf('Connect to IMAP server with %s:%s@%s', $opts->{'mail-user'}, $opts->{'mail-pwd'}, $opts->{'mail-server'});
	}

	my $imap = Mail::IMAPClient->new(%imap_arguments)
		or die "IMAP connection error: $@";

	$opts->{'mail-folder'} ||= 'INBOX';

	if ($verbose) {
		say 'Open IMAP folder ' . $opts->{'mail-folder'};
	}

	$imap->select($opts->{'mail-folder'})
		or die "IMAP select error: $@";

	my @msgs = $imap->search('ALL');

	if (not @msgs and $@) {
		die "IMAP search error: $@";
	}

	foreach my $msg (@msgs) {
		my $file = $opts->{'folder-tmp'} . $msg . '.msg';

		if ($verbose) {
			say sprintf('Fetch mail %s to %s', $msg, $file);
		}

		$imap->message_to_file($file, $msg)
			or die "IMAP message_to_file error: $@";
		
		if (not $opts->{'mail-do-not-delete-mail'}) {
			if ($verbose) {
				say 'Delete mail ' . $msg;
			}
		
			$imap->delete_message($msg)
				or die "IMAP delete_message error: $@";
		}
	}

	if ($verbose) {
		say 'Close IMAP folder ' . $opts->{'mail-folder'};
	}

	$imap->close($opts->{'mail-folder'})
		or die "IMAP close error: $@";

	if ($verbose) {
		say 'Disconnect from IMAP';
	}

	$imap->logout()
		or die "IMAP logout error: $@";
}

if ($verbose) {
	say 'Filter mails';
}

opendir(DIR, $opts->{'folder-tmp'})
	or die $!;

my @regex_html = map { trim($_) } read_file($opts->{'filter-html'});
my @regex_text = map { trim($_) } read_file($opts->{'filter-text'});
	
my $parser = MIME::Parser->new();

if ($opts->{'in-memory'}) {
	# disable temporary files and cache all data in memory
	$parser->tmp_to_core(1);
	$parser->output_to_core(1);
}

while (my $file = readdir(DIR)) {
	if ($file =~ m/^\./ or $file !~ m/\.msg$/) {
		next;
	}

	try {
		if ($verbose) {
			say 'Open mail ' . $opts->{'folder-tmp'} . $file;
		}

		my $m = $parser->parse_open($opts->{'folder-tmp'} . $file);
		
		my @parts = ($m);
		my %parts_remove;
		
		while (my $p = pop(@parts)) {
			# ignore attachments right away
			if ($p->head->count('Content-Disposition')) {
				return;
			}
			
			if ($p->parts) {
				push(@parts, $p->parts);
			}
			else {
				if ($p->mime_type eq 'text/plain' and @regex_text) {
					my $t = $p->bodyhandle->as_string;

					for my $r(@regex_text) {
						if (not $r) {
							return;
						}

						$t =~ s/${r}//sg;
					}

					$p->bodyhandle(MIME::Body::InCore->new($t));
				}
				elsif ($p->mime_type eq 'text/html' and @regex_html) {
					my $t = $p->bodyhandle->as_string;

					for my $r(@regex_html) {
						if (not $r) {
							return;
						}

						$t =~ s/${r}//sg;
						
						if ($1) {
							my $remove = $1;
							
							while ($remove =~ m/src="cid:([^"]+)"/sg) {
								$parts_remove{'<' . $1 . '>'} = 1;

								if ($verbose) {
									say "\tFound attachment $1 to remove";
								}
							}
						}
					}

					$p->bodyhandle(MIME::Body::InCore->new($t));
				}
			}
		}
		
		@parts = ($m);

		while (my $p = pop(@parts)) {
			if ($p->parts) {
				my @keep = grep { not $_->head or not $_->head->count('Content-ID') or not exists $parts_remove{trim($_->head->get('Content-ID'))} } $p->parts;
				
				$p->parts(\@keep);

				if (@keep) {
					push(@parts, $p->parts);
				}
			}
		}

		if ($verbose) {
			say "\tMove mail to " . $opts->{'folder-dst'} . $file;
		}

		$m->print(IO::File->new($opts->{'folder-dst'} . $file, 'w'));
	}
	catch {
		die $_;
	}
	finally {
		if ($verbose) {
			say "\tClean up $file";
		}

		$parser->filer->purge;
		unlink($opts->{'folder-tmp'} . $file);
	};
}

closedir(DIR);

if ($verbose) {
	say 'All done, will exit now';
}
