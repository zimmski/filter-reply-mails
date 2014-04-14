#!/usr/bin/perl

our $VERSION = 1.2.1;

use utf8;

binmode STDOUT, ':utf8';

use Modern::Perl;

use Encode;
use File::Slurp;
use Getopt::Compact;
use IO::File;
use IO::Socket::SSL qw/SSL_VERIFY_NONE/;
use Mail::IMAPClient;
use MIME::Parser;
use Mojo::DOM;
use String::Util qw/trim/;
use Try::Tiny;

my $options = Getopt::Compact->new(
	name => 'Script to filter the text and html parts of mails fetched from an IMAP folder based on given regexes',
	struct => [
		[ 'do-not-remove-files', 'Do not remove mail files' ],
		[ 'filter-dom', 'CSS selectors for html parts', ':s' ],
		[ 'filter-html', 'Regexes for html parts', ':s' ],
		[ 'filter-text', 'Regexes for text parts', ':s' ],
		[ 'folder-tmp', 'Temporary mail folder', '=s' ],
		[ 'folder-dst', 'Destination mail folder', '=s' ],
		[ 'in-memory', 'Do the MIME work in memory (default is off)' ],
		[ 'file', 'Parse MIME file and print the result to STDOUT', ':s' ],
		[ 'mail-do-not-connect', 'Do not open an IMAP connection' ],
		[ 'mail-do-not-delete-mail', 'Do not delete mails after fetching them' ],
		[ 'mail-do-not-verify-certificate', 'Do not verify the SSL certificate of the IMAP connection' ],
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

my $verbose = $opts->{verbose};

sub options_validate {
	my ($opts) = @_;

	if (not $opts->{file}) {
		for my $i(qw/folder-tmp folder-dst/) {
			if (not $opts->{$i}) {
				say_error("argument '$i' is needed.");

				return;
			}
		}
	}

	for my $i(qw/folder-tmp folder-dst/) {
		if ($opts->{$i} and (not -d $opts->{$i} or not -w $opts->{$i})) {
			say_error("folder '" . $opts->{$i} . "' is not writable");

			return;
		}
	}

	for my $i(qw/filter-html filter-text/) {
		if ($opts->{$i} and (not -f $opts->{$i} or not -r $opts->{$i})) {
			say_error("regexes file '" . $opts->{$i} . "' is not readable");

			return;
		}
	}

	return 1;
}

sub say_error {
	my ($text) = @_;

	print STDERR "\x1B[0;31mERROR: $text\x1b[0m\n";
}

sub say_verbose {
	my ($text) = @_;

	if ($verbose) {
		print STDERR "\x1B[0;36mVERBOSE: $text\x1b[0m\n";
	}
}

my $path = '';
my @files;

if ($opts->{file}) {
	push(@files, $opts->{file});
}
else {
	if ($opts->{'folder-tmp'} !~ m/\/$/) {
		$opts->{'folder-tmp'} .= '/';
	}
	if ($opts->{'folder-dst'} !~ m/\/$/) {
		$opts->{'folder-dst'} .= '/';
	}

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
			$imap_arguments{Ssl} = ($opts->{'mail-do-not-verify-certificate'}) ? [
				verify_hostname => 0,
				SSL_verify_mode => SSL_VERIFY_NONE,
			] : 1;
		}
		if ($opts->{'mail-tls'}) {
			$imap_arguments{Starttls} = ($opts->{'mail-do-not-verify-certificate'}) ? [
				verify_hostname => 0,
				SSL_verify_mode => SSL_VERIFY_NONE,
			] : 1;
		}

		say_verbose(sprintf('Connect to IMAP server with %s:%s@%s', $opts->{'mail-user'}, $opts->{'mail-pwd'}, $opts->{'mail-server'}));

		my $imap = Mail::IMAPClient->new(%imap_arguments)
			or die "IMAP connection error: $@";

		$opts->{'mail-folder'} ||= 'INBOX';

		say_verbose('Open IMAP folder ' . $opts->{'mail-folder'});

		$imap->select($opts->{'mail-folder'})
			or die "IMAP select error: $@";

		my @msgs = $imap->search('ALL');

		if (not @msgs and $@) {
			die "IMAP search error: $@";
		}

		foreach my $msg (@msgs) {
			my $file = $opts->{'folder-tmp'} . $msg . '.msg';

			say_verbose(sprintf('Fetch mail %s to %s', $msg, $file));

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

		say_verbose('Close IMAP folder ' . $opts->{'mail-folder'});

		$imap->close($opts->{'mail-folder'})
			or die "IMAP close error: $@";

		say_verbose('Disconnect from IMAP');

		$imap->logout()
			or die "IMAP logout error: $@";
	}


	opendir(DIR, $opts->{'folder-tmp'})
		or die $!;

	$path = $opts->{'folder-tmp'} . ($opts->{'folder-tmp'} =~ m/\/$/sg ? '' : '/');
	@files = readdir(DIR);

	closedir(DIR);
}

say_verbose('Filter mails');

my @dom_html = ($opts->{'filter-dom'}) ? map { trim($_) } read_file($opts->{'filter-dom'}) : ();
my @regex_html = ($opts->{'filter-html'}) ? map { trim($_) } read_file($opts->{'filter-html'}) : ();
my @regex_text = ($opts->{'filter-text'}) ? map { trim($_) } read_file($opts->{'filter-text'}) : ();

my $parser = MIME::Parser->new();

if ($opts->{'in-memory'}) {
	# disable temporary files and cache all data in memory
	$parser->tmp_to_core(1);
	$parser->output_to_core(1);
}

for my $file(@files) {
	if ($file =~ m/^\./ or $file !~ m/\.msg$/) {
		say_verbose("ignore $file because of wrong extension");

		next;
	}

	try {
		say_verbose('Open mail ' . $path . $file);

		my $m = $parser->parse_open($path . $file);

		my @parts = ($m);
		my %parts_remove;

		while (my $p = pop(@parts)) {
			# ignore attachments right away
			if ($p->head->count('Content-Disposition')) {
				next;
			}

			if ($p->parts) {
				push(@parts, $p->parts);
			}
			else {
				if ($p->mime_type eq 'text/plain' and @regex_text) {
					my $t = $p->bodyhandle->as_string;

					for my $r(@regex_text) {
						if (not $r) {
							next;
						}

						$t =~ s/${r}//sg;
					}

					$p->bodyhandle(MIME::Body::InCore->new($t));
				}
				elsif ($p->mime_type eq 'text/html') {
					my $t = $p->bodyhandle->as_string;

					$t =~ s/&nbsp;/ /sg;

					if (@dom_html) {
						my $encoding = $p->head->mime_attr('content-type.charset');
						$encoding ||= 'UTF-8';

						my $dom = Mojo::DOM->new(charset => $encoding)->parse($t);

						for my $selector (@dom_html) {
							$dom->find($selector)->each(sub {
								my $i = shift;
								my $html = $i->to_string();

								while ($html =~ m/src="cid:([^"]+)"/sg) {
									$parts_remove{'<' . $1 . '>'} = 1;

									say_verbose("\tFound attachment $1 to remove");
								}

								$i->remove;
							});
						}

						$t = $dom->to_string();

						if ($encoding) {
							$t = Encode::encode($encoding, $t);
							Encode::from_to($t, $encoding, 'UTF-8');
							$t = Encode::decode('UTF-8', $t);
						}
					}

					if (@regex_html) {
						for my $r(@regex_html) {
							if (not $r) {
								next;
							}

							$t =~ s/${r}//sg;

							if ($1) {
								my $remove = $1;

								while ($remove =~ m/src="cid:([^"]+)"/sg) {
									$parts_remove{'<' . $1 . '>'} = 1;

									say_verbose("\tFound attachment $1 to remove");
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

		if ($opts->{file}) {
			$m->print(\*STDOUT);
		}
		else {
			say_verbose("\tMove mail to " . $opts->{'folder-dst'} . $file);

			$m->print(IO::File->new($opts->{'folder-dst'} . $file, 'w'));
		}
	}
	catch {
		die $_;
	}
	finally {
		$parser->filer->purge;

		if (! $opts->{'do-not-remove-files'}) {
			say_verbose("\tClean up $path$file");

			unlink($path . $file);
		}
	};
}

say_verbose('All done, will exit now');
